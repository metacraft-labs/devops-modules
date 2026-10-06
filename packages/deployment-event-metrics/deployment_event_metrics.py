#!/usr/bin/env python3
"""Prometheus exporter for Metacraft deployment JSONL and Attic nginx logs."""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import http.server
import json
import os
import pathlib
import socketserver
import sys
import tempfile
import threading
import time
from collections import Counter
from dataclasses import dataclass
from typing import Iterator


DEFAULT_EVENT_DIR = "/var/log/mcl/deployments"
DEFAULT_PORT = 9161
# The exporter re-derives every metric from the full on-disk log history on each
# refresh. To keep that O(1) in the number of concurrent Prometheus scrapes (and
# to decouple exporter cost from the scrape interval), a single cached snapshot
# is served for this many seconds; concurrent scrapes reuse it instead of each
# re-reading the logs. See ``MetricsHandler``.
DEFAULT_REFRESH_SECONDS = 15.0


@dataclass(frozen=True)
class Metric:
    name: str
    labels: tuple[tuple[str, str], ...]
    value: float


def parse_timestamp(value: str | None) -> float | None:
    if not value:
        return None
    try:
        normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
        return dt.datetime.fromisoformat(normalized).timestamp()
    except ValueError:
        return None


def prom_escape_label(value: object) -> str:
    text = "" if value is None else str(value)
    return text.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def prom_value(value: float | int) -> str:
    """Exposition text for a sample value, at FULL precision.

    This used to be `f"{value:g}"`, which keeps 6 significant digits. A Unix
    timestamp has 10, so every `*_timestamp_seconds` gauge was rounded to the
    nearest 10^4 s (~2.8 h): every host's "last successful deploy" read
    1.7912e+09 and the same age. Byte counters past 10^6 lost precision the
    same way. Integral values print as integers; everything else uses
    `repr`, Python's shortest round-tripping form.
    """
    number = float(value)
    if number != number:
        return "NaN"
    if number in (float("inf"), float("-inf")):
        return "+Inf" if number > 0 else "-Inf"
    if number.is_integer() and abs(number) < 2**63:
        return str(int(number))
    return repr(number)


def prom_sample(name: str, labels: dict[str, object], value: float | int) -> str:
    label_text = ",".join(
        f'{key}="{prom_escape_label(labels[key])}"' for key in sorted(labels)
    )
    rendered = prom_value(value)
    return f"{name}{{{label_text}}} {rendered}" if label_text else f"{name} {rendered}"


def metric_key(name: str, labels: dict[str, object]) -> tuple[str, tuple[tuple[str, str], ...]]:
    return name, tuple(sorted((key, "" if value is None else str(value)) for key, value in labels.items()))


def event_log_paths(event_logs: list[str], event_dirs: list[str]) -> list[pathlib.Path]:
    paths = [pathlib.Path(path) for path in event_logs]
    for directory in event_dirs:
        paths.extend(pathlib.Path(p) for p in glob.glob(os.path.join(directory, "*.jsonl")))
    return sorted(set(paths))


def iter_jsonl(path: pathlib.Path, parse_errors: Counter) -> Iterator[dict]:
    """Stream dict records from one JSONL file, counting parse errors.

    Streaming (one line resident at a time) is what keeps the exporter's memory
    bounded by metric cardinality rather than by the — unbounded, ever-growing —
    size of the deployment/nginx log history. Do NOT accumulate the parsed
    records into a list; the caller folds each record into bounded aggregates.
    """
    try:
        if not path.exists():
            return
        with path.open() as handle:
            for line in handle:
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    parse_errors[str(path)] += 1
                    continue
                if isinstance(record, dict):
                    yield record
                else:
                    parse_errors[str(path)] += 1
    except OSError:
        parse_errors[str(path)] += 1


def stream_events(
    event_logs: list[str], event_dirs: list[str], parse_errors: Counter
) -> Iterator[dict]:
    for path in event_log_paths(event_logs, event_dirs):
        yield from iter_jsonl(path, parse_errors)


def event_labels(event: dict) -> dict[str, object]:
    target = event.get("target") if isinstance(event.get("target"), dict) else {}
    backend = event.get("backend") if isinstance(event.get("backend"), dict) else {}
    command = event.get("command") if isinstance(event.get("command"), dict) else {}
    return {
        "target": target.get("name", "unknown"),
        "phase": event.get("phase", "unknown"),
        "status": command.get("status", "unknown"),
        "controller": backend.get("controller", "unknown"),
        "transport": target.get("transport", "unknown"),
        "cache": backend.get("cache", "unknown"),
    }


def event_finished_at(event: dict) -> float | None:
    timestamps = event.get("timestamps") if isinstance(event.get("timestamps"), dict) else {}
    return parse_timestamp(timestamps.get("finishedAt"))


def event_started_at(event: dict) -> float | None:
    timestamps = event.get("timestamps") if isinstance(event.get("timestamps"), dict) else {}
    return parse_timestamp(timestamps.get("startedAt"))


def closure_summary(event: dict) -> dict:
    store_paths = event.get("storePaths") if isinstance(event.get("storePaths"), dict) else {}
    closure = store_paths.get("closure")
    return closure if isinstance(closure, dict) else {}


def deployment_metrics(
    event_logs: list[str],
    event_dirs: list[str],
    expected_targets: list[str],
    now: float,
) -> dict[tuple[str, tuple[tuple[str, str], ...]], Metric]:
    metrics: dict[tuple[str, tuple[tuple[str, str], ...]], Metric] = {}
    parse_errors: Counter = Counter()
    failure_counts: Counter = Counter()
    cache_upload_bytes: Counter = Counter()
    cache_restore_failures: Counter = Counter()
    last_seen: dict[str, float] = {}
    last_successful_complete: dict[str, float] = {}
    last_phase_success: dict[tuple[str, str], float] = {}
    latest_phase_state: dict[
        tuple[str, str, str], tuple[float, str, dict[str, object], float | None]
    ] = {}

    def set_metric(name: str, labels: dict[str, object], value: float | int) -> None:
        key = metric_key(name, labels)
        metrics[key] = Metric(key[0], key[1], float(value))

    # Stream events straight into the bounded aggregates above — never hold the
    # full event history in memory.
    for event in stream_events(event_logs, event_dirs, parse_errors):
        labels = event_labels(event)
        target = str(labels["target"])
        phase = str(labels["phase"])
        status = str(labels["status"])
        started = event_started_at(event)
        finished = event_finished_at(event)
        observed = finished if finished is not None else started

        if observed is not None:
            last_seen[target] = max(last_seen.get(target, 0), observed)
            deployment_id = str(event.get("deploymentId", "unknown"))
            state_key = (deployment_id, target, phase)
            previous = latest_phase_state.get(state_key)
            if previous is None or observed >= previous[0]:
                latest_phase_state[state_key] = (observed, status, labels, started)

        if started is not None and finished is not None:
            set_metric(
                "mcl_deployment_phase_duration_seconds",
                labels,
                max(0, finished - started),
            )

        closure = closure_summary(event)
        if "count" in closure and closure["count"] is not None:
            count_labels = dict(labels)
            count_labels.pop("status", None)
            set_metric("mcl_deployment_closure_paths", count_labels, int(closure["count"]))
        if "totalBytes" in closure and closure["totalBytes"] is not None:
            bytes_labels = dict(labels)
            bytes_labels.pop("status", None)
            set_metric("mcl_deployment_closure_bytes", bytes_labels, int(closure["totalBytes"]))

        if status == "failed":
            error = event.get("error") if isinstance(event.get("error"), dict) else {}
            error_code = error.get("code", "unknown")
            failure_counts[
                (
                    labels["target"],
                    labels["phase"],
                    labels["controller"],
                    labels["transport"],
                    labels["cache"],
                    error_code,
                )
            ] += 1
            if phase == "agent-restore":
                cache_restore_failures[
                    (
                        labels["target"],
                        labels["controller"],
                        labels["transport"],
                        labels["cache"],
                        error_code,
                    )
                ] += 1

        if phase == "cache-push":
            total_bytes = closure.get("totalBytes")
            if total_bytes is not None:
                cache_upload_bytes[
                    (
                        labels["target"],
                        labels["controller"],
                        labels["cache"],
                        status,
                    )
                ] += int(total_bytes)

        if status == "succeeded" and finished is not None:
            last_phase_success[(target, phase)] = max(
                last_phase_success.get((target, phase), 0), finished
            )
            if phase == "complete":
                last_successful_complete[target] = max(
                    last_successful_complete.get(target, 0), finished
                )

    for source, count in parse_errors.items():
        set_metric("mcl_deployment_event_parse_errors_total", {"source": source}, count)

    for _state_key, (_observed, status, labels, started) in latest_phase_state.items():
        if status in {"pending", "running"} and started is not None:
            set_metric(
                "mcl_deployment_in_progress_age_seconds",
                labels,
                max(0, now - started),
            )

    for key, count in failure_counts.items():
        target, phase, controller, transport, cache, error_code = key
        set_metric(
            "mcl_deployment_phase_failures_total",
            {
                "target": target,
                "phase": phase,
                "controller": controller,
                "transport": transport,
                "cache": cache,
                "error_code": error_code,
            },
            count,
        )

    for key, count in cache_restore_failures.items():
        target, controller, transport, cache, error_code = key
        set_metric(
            "mcl_deployment_cache_restore_failures_total",
            {
                "target": target,
                "controller": controller,
                "transport": transport,
                "cache": cache,
                "error_code": error_code,
            },
            count,
        )

    for key, total_bytes in cache_upload_bytes.items():
        target, backend, cache, status = key
        set_metric(
            "mcl_deployment_cache_upload_bytes_total",
            {
                "target": target,
                "backend": backend,
                "cache": cache,
                "status": status,
            },
            total_bytes,
        )

    for target, timestamp in last_successful_complete.items():
        set_metric(
            "mcl_deployment_last_successful_timestamp_seconds",
            {"target": target},
            timestamp,
        )

    for (target, phase), timestamp in last_phase_success.items():
        set_metric(
            "mcl_deployment_last_phase_success_timestamp_seconds",
            {"target": target, "phase": phase},
            timestamp,
        )

    all_expected = sorted(set(expected_targets))
    for target in all_expected:
        set_metric("mcl_deployment_target_expected", {"target": target}, 1)
        set_metric("mcl_deployment_target_seen", {"target": target}, 1 if target in last_seen else 0)
    for target, timestamp in last_seen.items():
        set_metric("mcl_deployment_target_last_seen_timestamp_seconds", {"target": target}, timestamp)

    return metrics


def classify_operation(method: str) -> str:
    upper = method.upper()
    if upper in {"GET", "HEAD"}:
        return "download"
    if upper in {"POST", "PUT", "PATCH"}:
        return "upload"
    return "other"


# The Attic vhost also serves the signed deployment manifests under
# `/mcl-deployments/`, which carry their own location-level ACL and legitimately
# answer 403 to callers outside it. Only a 403 on a CACHE path means a Nix
# client was refused by the cache's network ACL (Attic itself answers a missing
# or bad token with 401), so the two must not share one counter.
DEPLOYMENT_MANIFEST_PREFIX = "/mcl-deployments/"


def classify_path(uri: str) -> str:
    return "deployments" if uri.startswith(DEPLOYMENT_MANIFEST_PREFIX) else "cache"


class NginxCounters:
    """The Attic access-log aggregates, foldable one entry at a time.

    Kept as a class so the same fold serves both a full re-read and the
    incremental mode (`--nginx-state`), where the counters are persisted
    between runs and only new log bytes are folded in.
    """

    def __init__(self) -> None:
        self.parse_errors: Counter = Counter()
        self.requests: Counter = Counter()
        self.bytes: Counter = Counter()
        self.object_failures: Counter = Counter()
        # Zero-seeded so the FIRST cache-path 403 is an increase Prometheus can
        # see (increase() over a series that appears at 1 reports nothing).
        self.forbidden: Counter = Counter({("cache", "GET"): 0, ("cache", "HEAD"): 0})

    FIELDS = ("parse_errors", "requests", "bytes", "object_failures", "forbidden")

    def fold(self, entry: dict) -> None:
        method = str(entry.get("method", "UNKNOWN"))
        status = str(entry.get("status", "000"))
        operation = classify_operation(method)
        self.requests[(operation, method, status)] += 1

        try:
            status_int = int(status)
        except ValueError:
            status_int = 0

        try:
            request_length = int(entry.get("request_length") or 0)
        except (TypeError, ValueError):
            request_length = 0
        try:
            body_bytes_sent = int(entry.get("body_bytes_sent") or 0)
        except (TypeError, ValueError):
            body_bytes_sent = 0

        if operation == "upload":
            self.bytes[(operation, "request", status)] += request_length
        else:
            self.bytes[(operation, "response", status)] += body_bytes_sent

        if operation in {"upload", "download"} and status_int >= 400:
            self.object_failures[(operation, method, status)] += 1

        if status_int == 403:
            self.forbidden[(classify_path(str(entry.get("uri", ""))), method)] += 1

    def fold_line(self, raw: bytes, source: str) -> None:
        if not raw.strip():
            return
        try:
            record = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError):
            self.parse_errors[(source,)] += 1
            return
        if isinstance(record, dict):
            self.fold(record)
        else:
            self.parse_errors[(source,)] += 1

    def to_json(self) -> dict:
        return {
            field: [list(key) + [value] for key, value in getattr(self, field).items()]
            for field in self.FIELDS
        }

    @classmethod
    def from_json(cls, data: dict) -> "NginxCounters":
        counters = cls()
        for field in cls.FIELDS:
            target: Counter = getattr(counters, field)
            for row in data.get(field, []):
                *key, value = row
                target[tuple(str(k) for k in key)] = int(value)
        return counters

    def metrics(self) -> dict[tuple[str, tuple[tuple[str, str], ...]], Metric]:
        metrics: dict[tuple[str, tuple[tuple[str, str], ...]], Metric] = {}

        def set_metric(name: str, labels: dict[str, object], value: float | int) -> None:
            key = metric_key(name, labels)
            metrics[key] = Metric(key[0], key[1], float(value))

        for (source,), count in self.parse_errors.items():
            set_metric("mcl_attic_nginx_log_parse_errors_total", {"source": source}, count)
        for (operation, method, status), count in self.requests.items():
            set_metric(
                "mcl_attic_nginx_requests_total",
                {"operation": operation, "method": method, "status": status},
                count,
            )
        for (operation, direction, status), total_bytes in self.bytes.items():
            set_metric(
                "mcl_attic_nginx_bytes_total",
                {"operation": operation, "direction": direction, "status": status},
                total_bytes,
            )
        for (operation, method, status), count in self.object_failures.items():
            set_metric(
                "mcl_attic_nginx_cache_object_failures_total",
                {"operation": operation, "method": method, "status": status},
                count,
            )
        for (path_class, method), count in self.forbidden.items():
            set_metric(
                "mcl_attic_nginx_forbidden_total",
                {"path_class": path_class, "method": method},
                count,
            )
        return metrics


def _fold_range(counters: NginxCounters, path: pathlib.Path, offset: int, source: str) -> int:
    """Fold complete lines of `path` from byte `offset`; return the new offset.

    A trailing line without its newline is a write in progress: it is left for
    the next run (the offset stops before it), never half-parsed.
    """
    with path.open("rb") as handle:
        handle.seek(offset)
        position = offset
        for raw in handle:
            if not raw.endswith(b"\n"):
                break
            counters.fold_line(raw, source)
            position += len(raw)
    return position


def nginx_metrics_incremental(
    nginx_logs: list[str], state_path: str
) -> dict[tuple[str, tuple[tuple[str, str], ...]], Metric]:
    """Cumulative Attic counters over a ROTATED log, reading only new bytes.

    State file (JSON, written atomically at the end of a successful pass):
      counters  - the cumulative aggregates, so they stay monotonic across
                  rotations (no counter resets, no vanishing label sets);
      files     - per configured path: device, inode and byte offset consumed.

    Rotation handling, per configured path:
      * same inode, size >= offset  -> fold from the offset (the common case);
      * same inode, size <  offset  -> truncated in place (copytruncate): the
                                       unread tail is gone; fold from 0;
      * different inode             -> renamed away (logrotate's default): if
                                       `<path>.1` is the old inode, finish it
                                       from the saved offset first, then fold
                                       the new file from 0.
    A pass that is killed before the state write simply re-reads the same
    bytes next time, so no line is counted twice.
    """
    state: dict = {}
    try:
        with open(state_path) as handle:
            state = json.load(handle)
    except (OSError, json.JSONDecodeError):
        state = {}
    if not isinstance(state, dict) or state.get("version") != 1:
        state = {}
    counters = NginxCounters.from_json(state.get("counters", {}))
    files: dict = state.get("files", {}) if isinstance(state.get("files"), dict) else {}

    for path_text in nginx_logs:
        path = pathlib.Path(path_text)
        try:
            st = path.stat()
        except OSError:
            continue
        saved = files.get(path_text) or {}
        saved_id = (saved.get("dev"), saved.get("ino"))
        offset = int(saved.get("offset", 0))
        try:
            if saved and saved_id != (st.st_dev, st.st_ino):
                rotated = pathlib.Path(path_text + ".1")
                try:
                    rst = rotated.stat()
                    if (rst.st_dev, rst.st_ino) == saved_id and rst.st_size >= offset:
                        _fold_range(counters, rotated, offset, path_text)
                except OSError:
                    pass
                offset = 0
            elif st.st_size < offset:
                offset = 0
            offset = _fold_range(counters, path, offset, path_text)
        except OSError:
            counters.parse_errors[(path_text,)] += 1
            continue
        files[path_text] = {"dev": st.st_dev, "ino": st.st_ino, "offset": offset}

    tmp = f"{state_path}.tmp"
    with open(tmp, "w") as handle:
        json.dump({"version": 1, "counters": counters.to_json(), "files": files}, handle)
    os.replace(tmp, state_path)
    return counters.metrics()


def nginx_metrics(nginx_logs: list[str]) -> dict[tuple[str, tuple[tuple[str, str], ...]], Metric]:
    counters = NginxCounters()
    # Stream the — potentially enormous, one-line-per-cache-request — Attic
    # access logs into bounded Counters; never materialize the entries.
    for path_text in nginx_logs:
        parse_errors: Counter = Counter()
        for entry in iter_jsonl(pathlib.Path(path_text), parse_errors):
            counters.fold(entry)
        for source, count in parse_errors.items():
            counters.parse_errors[(source,)] += count
    return counters.metrics()


HELP_TEXT = {
    "mcl_deployment_phase_duration_seconds": "Duration of the latest observed deployment phase by target.",
    "mcl_deployment_phase_failures_total": "Count of failed deployment phase events observed in JSONL logs.",
    "mcl_deployment_closure_paths": "Latest observed deployment closure path count.",
    "mcl_deployment_closure_bytes": "Latest observed deployment closure byte size.",
    "mcl_deployment_cache_upload_bytes_total": "Total deployment cache upload bytes observed from cache-push events.",
    "mcl_deployment_cache_restore_failures_total": "Count of failed target cache restore events.",
    "mcl_deployment_last_successful_timestamp_seconds": "Unix timestamp for the latest completed successful deployment by target.",
    "mcl_deployment_last_phase_success_timestamp_seconds": "Unix timestamp for the latest successful deployment phase by target.",
    "mcl_deployment_in_progress_age_seconds": "Age of currently running or pending deployment phases.",
    "mcl_deployment_target_expected": "Expected deployment target inventory marker.",
    "mcl_deployment_target_seen": "Whether an expected deployment target has been observed in deployment events.",
    "mcl_deployment_target_last_seen_timestamp_seconds": "Unix timestamp for the latest deployment event observed by target.",
    "mcl_deployment_event_parse_errors_total": "Count of JSONL deployment event parse errors by source.",
    "mcl_attic_nginx_requests_total": "Count of Attic nginx requests by cache operation, method, and status.",
    "mcl_attic_nginx_bytes_total": "Attic nginx byte volume by cache operation, direction, and status.",
    "mcl_attic_nginx_cache_object_failures_total": "Count of failed Attic cache object requests.",
    "mcl_attic_nginx_forbidden_total": "Count of Attic vhost HTTP 403 responses by path class (cache = refused by the cache network ACL; deployments = /mcl-deployments/ manifest ACL) and method.",
    "mcl_attic_nginx_log_parse_errors_total": "Count of Attic nginx access log parse errors by source.",
}


def render_metrics(
    event_logs: list[str],
    event_dirs: list[str],
    nginx_logs: list[str],
    expected_targets: list[str],
    now: float | None = None,
    nginx_state: str | None = None,
) -> str:
    now = dt.datetime.now(dt.timezone.utc).timestamp() if now is None else now
    merged = deployment_metrics(event_logs, event_dirs, expected_targets, now)
    # Only render the Attic families when an access log was asked for.
    # `nginx_metrics` zero-seeds `mcl_attic_nginx_forbidden_total`, so an
    # events-only invocation used to emit that family too. Consumers that
    # render events and the access log in separate passes and concatenate the
    # outputs (infra's two-cadence snapshot) then got a duplicate HELP/TYPE
    # for it, which is an invalid exposition.
    if nginx_logs:
        merged.update(
            nginx_metrics_incremental(nginx_logs, nginx_state)
            if nginx_state
            else nginx_metrics(nginx_logs)
        )

    lines: list[str] = []
    emitted_help: set[str] = set()
    for key in sorted(merged):
        metric = merged[key]
        if metric.name not in emitted_help:
            help_text = HELP_TEXT.get(metric.name, metric.name)
            lines.append(f"# HELP {metric.name} {help_text}")
            lines.append(f"# TYPE {metric.name} gauge" if not metric.name.endswith("_total") else f"# TYPE {metric.name} counter")
            emitted_help.add(metric.name)
        labels = {label: value for label, value in metric.labels}
        lines.append(prom_sample(metric.name, labels, metric.value))
    return "\n".join(lines) + ("\n" if lines else "")


class MetricsHandler(http.server.BaseHTTPRequestHandler):
    event_logs: list[str] = []
    event_dirs: list[str] = []
    nginx_logs: list[str] = []
    expected_targets: list[str] = []
    refresh_seconds: float = DEFAULT_REFRESH_SECONDS

    # A single cached snapshot shared across all handler threads. Rendering the
    # metrics re-reads the whole log history, so we serialize it behind a lock
    # and reuse the result for ``refresh_seconds``. Without this, a slow render
    # (large logs) lets Prometheus scrapes pile up — every concurrent scrape
    # re-reading the logs at once — which is how the exporter ballooned to
    # hundreds of GB of RSS.
    _cache_lock = threading.Lock()
    _cache_text: str | None = None
    _cache_at: float = 0.0

    @classmethod
    def cached_metrics(cls) -> str:
        with cls._cache_lock:
            now = time.monotonic()
            if cls._cache_text is None or (now - cls._cache_at) >= cls.refresh_seconds:
                cls._cache_text = render_metrics(
                    cls.event_logs,
                    cls.event_dirs,
                    cls.nginx_logs,
                    cls.expected_targets,
                )
                cls._cache_at = now
            return cls._cache_text

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        body = self.cached_metrics().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        return


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def serve(args: argparse.Namespace) -> None:
    MetricsHandler.event_logs = args.event_log
    MetricsHandler.event_dirs = args.event_dir
    MetricsHandler.nginx_logs = args.nginx_log
    MetricsHandler.expected_targets = args.expected_target
    MetricsHandler.refresh_seconds = args.refresh_interval

    servers = []
    for bind_address in args.bind_addresses:
        server = ThreadingHTTPServer((bind_address, args.port), MetricsHandler)
        servers.append(server)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

    try:
        threading.Event().wait()
    finally:
        for server in servers:
            server.shutdown()


def self_test() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        event_dir = root / "events"
        event_dir.mkdir()
        event_log = event_dir / "deploy.jsonl"
        event_log.write_text(
            "\n".join(
                [
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "deploymentId": "dep-1",
                            "correlationId": "corr-1",
                            "phase": "cache-push",
                            "target": {
                                "name": "app-server-01",
                                "system": "x86_64-linux",
                                "kind": "server",
                                "transport": "cachix-agent",
                            },
                            "backend": {
                                "cache": "cache",
                                "controller": "attic",
                                "substituters": ["https://cache.example/cache"],
                            },
                            "storePaths": {
                                "system": "/nix/store/root-system",
                                "closure": {
                                    "count": 2,
                                    "totalBytes": 1234,
                                    "rootHashes": ["root"],
                                },
                            },
                            "timestamps": {
                                "startedAt": "2026-05-13T09:00:00Z",
                                "finishedAt": "2026-05-13T09:00:05Z",
                            },
                            "command": {
                                "name": "attic push",
                                "argv": ["attic", "push"],
                                "status": "succeeded",
                                "exitCode": 0,
                            },
                        }
                    ),
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "deploymentId": "dep-2",
                            "correlationId": "corr-2",
                            "phase": "switch",
                            "target": {
                                "name": "app-server-02",
                                "system": "x86_64-linux",
                                "kind": "server",
                                "transport": "direct-ssh",
                            },
                            "backend": {
                                "cache": "cache",
                                "controller": "direct-ssh",
                                "substituters": ["https://cache.example/cache"],
                            },
                            "storePaths": {"system": "/nix/store/root-system"},
                            "timestamps": {
                                "startedAt": "2026-05-13T09:00:10Z"
                            },
                            "command": {
                                "name": "switch",
                                "argv": ["switch"],
                                "status": "running",
                                "exitCode": None,
                            },
                        }
                    ),
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "deploymentId": "dep-3",
                            "correlationId": "corr-3",
                            "phase": "switch",
                            "target": {
                                "name": "app-server-03",
                                "system": "x86_64-linux",
                                "kind": "server",
                                "transport": "direct-ssh",
                            },
                            "backend": {
                                "cache": "cache",
                                "controller": "direct-ssh",
                                "substituters": ["https://cache.example/cache"],
                            },
                            "storePaths": {"system": "/nix/store/root-system"},
                            "timestamps": {
                                "startedAt": "2026-05-13T09:00:10Z"
                            },
                            "command": {
                                "name": "switch",
                                "argv": ["switch"],
                                "status": "running",
                                "exitCode": None,
                            },
                        }
                    ),
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "deploymentId": "dep-3",
                            "correlationId": "corr-3",
                            "phase": "switch",
                            "target": {
                                "name": "app-server-03",
                                "system": "x86_64-linux",
                                "kind": "server",
                                "transport": "direct-ssh",
                            },
                            "backend": {
                                "cache": "cache",
                                "controller": "direct-ssh",
                                "substituters": ["https://cache.example/cache"],
                            },
                            "storePaths": {"system": "/nix/store/root-system"},
                            "timestamps": {
                                "startedAt": "2026-05-13T09:00:10Z",
                                "finishedAt": "2026-05-13T09:00:15Z",
                            },
                            "command": {
                                "name": "switch",
                                "argv": ["switch"],
                                "status": "succeeded",
                                "exitCode": 0,
                            },
                        }
                    ),
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "deploymentId": "dep-1",
                            "correlationId": "corr-1",
                            "phase": "agent-restore",
                            "target": {
                                "name": "app-server-01",
                                "system": "x86_64-linux",
                                "kind": "server",
                                "transport": "cachix-agent",
                            },
                            "backend": {
                                "cache": "cache",
                                "controller": "cachix-deploy",
                                "substituters": ["https://cache.example/cache"],
                            },
                            "storePaths": {"system": "/nix/store/root-system"},
                            "timestamps": {
                                "startedAt": "2026-05-13T09:00:05Z",
                                "finishedAt": "2026-05-13T09:00:08Z",
                            },
                            "command": {
                                "name": "restore",
                                "argv": ["restore"],
                                "status": "failed",
                                "exitCode": 1,
                            },
                            "error": {
                                "code": "cache_restore_failed",
                                "message": "restore failed",
                                "retryable": True,
                            },
                        }
                    ),
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "deploymentId": "dep-1",
                            "correlationId": "corr-1",
                            "phase": "complete",
                            "target": {
                                "name": "app-server-01",
                                "system": "x86_64-linux",
                                "kind": "server",
                                "transport": "direct-ssh",
                            },
                            "backend": {
                                "cache": "cache",
                                "controller": "direct-ssh",
                                "substituters": ["https://cache.example/cache"],
                            },
                            "storePaths": {"system": "/nix/store/root-system"},
                            "timestamps": {
                                "startedAt": "2026-05-13T09:00:08Z",
                                "finishedAt": "2026-05-13T09:00:09Z",
                            },
                            "command": {
                                "name": "complete",
                                "argv": ["complete"],
                                "status": "succeeded",
                                "exitCode": 0,
                            },
                        }
                    ),
                ]
            )
            + "\n"
        )

        nginx_log = root / "attic.access.jsonl"
        nginx_log.write_text(
            "\n".join(
                [
                    json.dumps(
                        {
                            "time": "2026-05-13T09:00:00+00:00",
                            "method": "PUT",
                            "uri": "/cache/nar/abc",
                            "status": "200",
                            "request_length": "4096",
                            "body_bytes_sent": "12",
                        }
                    ),
                    json.dumps(
                        {
                            "time": "2026-05-13T09:00:01+00:00",
                            "method": "GET",
                            "uri": "/cache/nar/missing",
                            "status": "404",
                            "request_length": "200",
                            "body_bytes_sent": "64",
                        }
                    ),
                    json.dumps(
                        {
                            "time": "2026-05-13T09:00:02+00:00",
                            "method": "GET",
                            "uri": "/cache/nix-cache-info",
                            "status": "403",
                            "request_length": "200",
                            "body_bytes_sent": "146",
                        }
                    ),
                    json.dumps(
                        {
                            "time": "2026-05-13T09:00:03+00:00",
                            "method": "GET",
                            "uri": "/mcl-deployments/app-server-01/latest.json",
                            "status": "403",
                            "request_length": "200",
                            "body_bytes_sent": "146",
                        }
                    ),
                ]
            )
            + "\n"
        )

        output = render_metrics(
            [],
            [str(event_dir)],
            [str(nginx_log)],
            [
                "app-server-01",
                "app-server-02",
                "app-server-03",
                "app-server-04",
            ],
            now=parse_timestamp("2026-05-13T09:01:00Z"),
        )
        required = [
            'mcl_deployment_phase_duration_seconds{cache="cache",controller="attic",phase="cache-push",status="succeeded",target="app-server-01",transport="cachix-agent"} 5',
            'mcl_deployment_cache_upload_bytes_total{backend="attic",cache="cache",status="succeeded",target="app-server-01"} 1234',
            'mcl_deployment_cache_restore_failures_total{cache="cache",controller="cachix-deploy",error_code="cache_restore_failed",target="app-server-01",transport="cachix-agent"} 1',
            'mcl_deployment_target_seen{target="app-server-02"} 1',
            'mcl_deployment_target_seen{target="app-server-04"} 0',
            'mcl_deployment_in_progress_age_seconds{cache="cache",controller="direct-ssh",phase="switch",status="running",target="app-server-02",transport="direct-ssh"} 50',
            'mcl_attic_nginx_requests_total{method="PUT",operation="upload",status="200"} 1',
            'mcl_attic_nginx_cache_object_failures_total{method="GET",operation="download",status="404"} 1',
            'mcl_attic_nginx_forbidden_total{method="GET",path_class="cache"} 1',
            'mcl_attic_nginx_forbidden_total{method="GET",path_class="deployments"} 1',
            'mcl_attic_nginx_forbidden_total{method="HEAD",path_class="cache"} 0',
        ]
        missing = [line for line in required if line not in output]
        if missing:
            raise AssertionError("missing metrics:\n" + "\n".join(missing) + "\n\n" + output)
        if 'mcl_deployment_in_progress_age_seconds{cache="cache",controller="direct-ssh",phase="switch",status="running",target="app-server-03",transport="direct-ssh"}' in output:
            raise AssertionError("stale in-progress metric was not cleared:\n" + output)

        # FULL PRECISION. With `:g` this line read 1.77867e+09 — a timestamp
        # rounded to 10^4 s. Pin the exact integer.
        expected_ts = int(parse_timestamp("2026-05-13T09:00:05Z"))
        precise = [
            line
            for line in output.splitlines()
            if line.startswith("mcl_deployment_last_phase_success_timestamp_seconds{")
        ]
        if not precise or any("e+" in line for line in precise):
            raise AssertionError("timestamps lost precision:\n" + "\n".join(precise))
        if not any(line.endswith(f" {expected_ts}") for line in precise):
            raise AssertionError(f"no phase-success timestamp equals {expected_ts}:\n" + "\n".join(precise))
        for value, text in [(1791240000.0, "1791240000"), (0.25, "0.25"), (1791240000.5, "1791240000.5"), (18693830640, "18693830640")]:
            if prom_value(value) != text:
                raise AssertionError(f"prom_value({value!r}) = {prom_value(value)!r}, want {text!r}")

        # AN EVENTS-ONLY RENDER EMITS NO ATTIC FAMILY. Separate event and
        # access-log renders are concatenated downstream; a zero-seeded
        # `mcl_attic_nginx_forbidden_total` in both would duplicate its HELP.
        events_only = render_metrics([], [str(event_dir)], [], ["app-server-01"], now=parse_timestamp("2026-05-13T09:01:00Z"))
        if "mcl_attic_nginx_" in events_only:
            raise AssertionError("events-only render emitted Attic families:\n" + events_only)
        attic_only = render_metrics([], [str(root / "no-events")], [str(nginx_log)], [], now=parse_timestamp("2026-05-13T09:01:00Z"))
        combined = events_only + attic_only
        helps = [line for line in combined.splitlines() if line.startswith("# HELP ")]
        duplicates = sorted({h for h in helps if helps.count(h) > 1})
        if duplicates:
            raise AssertionError("concatenated renders duplicate HELP lines:\n" + "\n".join(duplicates))

        # INCREMENTAL MODE (--nginx-state) over a ROTATED log. The counters must
        # equal a full read of every line ever written, across append, a
        # rename rotation with an unread tail, a copytruncate, and a partial
        # trailing line — and a re-run with no new bytes must not double-count.
        def attic_lines(text: str) -> dict[str, str]:
            return {
                line.rsplit(" ", 1)[0]: line.rsplit(" ", 1)[1]
                for line in text.splitlines()
                if line.startswith("mcl_attic_nginx_")
            }

        def entry(method: str, status: int, uri: str) -> str:
            return json.dumps({"method": method, "status": status, "uri": uri, "body_bytes_sent": 10, "request_length": 3}) + "\n"

        live = root / "inc" / "attic.jsonl"
        live.parent.mkdir()
        state = str(root / "inc" / "state.json")
        every: list[str] = []

        def write(text: str, mode: str = "a") -> None:
            with live.open(mode) as handle:
                handle.write(text)

        def render_inc() -> dict[str, str]:
            return attic_lines(render_metrics([], [str(root / "no-events")], [str(live)], [], nginx_state=state))

        def expect(label: str) -> None:
            reference = root / "inc" / "reference.jsonl"
            reference.write_text("".join(every))
            want = attic_lines(render_metrics([], [str(root / "no-events")], [str(reference)], []))
            want = {k.replace(str(reference), str(live)): v for k, v in want.items()}
            got = render_inc()
            if got != want:
                raise AssertionError(f"incremental != full read after {label}:\n got {got}\nwant {want}")

        first = entry("GET", 200, "/cache/a") + entry("PUT", 403, "/cache/b") + entry("GET", 403, "/mcl-deployments/x")
        write(first, "w")
        every.append(first)
        expect("first pass")
        expect("re-run with no new bytes")

        more = entry("GET", 502, "/cache/c")
        write(more)
        every.append(more)
        expect("append")

        # Rename rotation with a tail the exporter has NOT read yet.
        tail = entry("HEAD", 403, "/cache/d")
        write(tail)
        every.append(tail)
        os.replace(live, str(live) + ".1")
        fresh = entry("GET", 200, "/cache/e")
        write(fresh, "w")
        every.append(fresh)
        expect("rename rotation with unread tail in .1")

        # A write in progress (no trailing newline) is not counted until complete.
        partial = entry("GET", 404, "/cache/f")
        write(partial[:-5])
        expect("partial trailing line")
        write(partial[-5:])
        every.append(partial)
        expect("partial line completed")

        # copytruncate: same inode, shrunk to zero, then new writes.
        write("", "w")
        after = entry("GET", 403, "/cache/g")
        write(after)
        every.append(after)
        expect("copytruncate")

        # Counters are monotonic: no family went down at any step above (each
        # expect() compares against the cumulative reference), and the
        # zero-seeded cache 403 series are always present.
        final = render_inc()
        for seeded in ('mcl_attic_nginx_forbidden_total{method="GET",path_class="cache"}', 'mcl_attic_nginx_forbidden_total{method="HEAD",path_class="cache"}'):
            if seeded not in final:
                raise AssertionError(f"{seeded} missing in incremental mode")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event-log", action="append", default=[], help="Deployment JSONL file to read")
    parser.add_argument(
        "--event-dir",
        action="append",
        default=[],
        help=f"Directory containing deployment *.jsonl files (default: {DEFAULT_EVENT_DIR})",
    )
    parser.add_argument("--nginx-log", action="append", default=[], help="Attic nginx JSONL access log to read")
    parser.add_argument(
        "--nginx-state",
        default=None,
        help=(
            "Incremental mode for --nginx-log (with --once): persist cumulative "
            "counters and per-file offsets here, read only new bytes, and survive "
            "log rotation (rename or copytruncate) without counter resets"
        ),
    )
    parser.add_argument("--expected-target", action="append", default=[], help="Target expected to emit deployment events")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--bind-addresses", default="127.0.0.1")
    parser.add_argument(
        "--refresh-interval",
        type=float,
        default=DEFAULT_REFRESH_SECONDS,
        help=(
            "Minimum seconds between full log re-reads; a cached snapshot is "
            "served in between so concurrent scrapes don't pile up "
            f"(default: {DEFAULT_REFRESH_SECONDS:g})"
        ),
    )
    parser.add_argument("--once", action="store_true", help="Print one metrics snapshot and exit")
    parser.add_argument("--self-test", action="store_true", help="Run deterministic parser/rendering self-test")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.bind_addresses = [part.strip() for part in args.bind_addresses.split(",") if part.strip()]
    if not args.bind_addresses:
        args.bind_addresses = ["127.0.0.1"]

    if args.self_test:
        self_test()
        print("deployment-event-metrics: self-test passed")
        return 0

    if not args.event_dir and not args.event_log:
        args.event_dir = [DEFAULT_EVENT_DIR]

    if args.once:
        sys.stdout.write(
            render_metrics(
                args.event_log,
                args.event_dir,
                args.nginx_log,
                args.expected_target,
                nginx_state=args.nginx_state,
            )
        )
        return 0

    serve(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
