#!/usr/bin/env python3
"""Integration test for gh-actions-fit-exporter.py (RD4 gate t_runner_fit_monitoring, parts a+b).

MOCK JUSTIFICATION (per the workspace testing policy: every mock must be
justified, and we prefer strong integration tests that mock as little as
possible). The ONLY thing mocked here is the GitHub Actions REST API itself —
the sanctioned mock the RD4 gate calls for ("prove the exporter emits the right
metrics from a MOCK Actions API response"). We do NOT mock the exporter, its
HTTP client, the filesystem, or the textfile format:

  * a REAL `http.server` serves canned Actions-API JSON + plain-text job logs on
    a loopback port — the exporter makes REAL HTTP requests through its REAL
    urllib client;
  * the exporter runs as a REAL subprocess (the packaged script) writing a REAL
    node-exporter textfile, which we then parse and assert.

So this exercises the exact code path production uses, up to the GitHub boundary
we cannot hit hermetically. Hitting the real api.github.com would make the test
non-hermetic and rate-limited — exactly what the gate forbids.

It proves:
  (a) duration metrics carry the right value + runner_type (github-hosted vs
      self-hosted, from job labels) + visibility (from the repo), one series per
      (workflow, job, runner_type);
  (b) the resource-limit signature detector fires OOM / no_space / timeout on the
      corresponding job-log fixtures, and stays silent on a clean success.
"""

from __future__ import annotations

import http.server
import json
import os
import re
import subprocess
import sys
import tempfile
import threading

# ── The mock GitHub Actions API dataset ────────────────────────────────────
#
# One public repo, one workflow ("CI"), five jobs that between them exercise:
# github-hosted vs self-hosted classification, a clean success, and the three
# resource-limit signatures on failed/cancelled hosted jobs.
OWNER, REPO = "metacraft-labs", "web"

REPO_JSON = {"name": REPO, "visibility": "public", "private": False}

RUNS_JSON = {
    "total_count": 1,
    "workflow_runs": [
        {"id": 1001, "name": "CI", "path": ".github/workflows/ci.yml", "status": "completed"}
    ],
}


def _job(job_id, name, labels, started, completed, conclusion, steps=None):
    return {
        "id": job_id,
        "name": name,
        "workflow_name": "CI",
        "labels": labels,
        "runner_name": "GitHub Actions 2" if "self-hosted" not in labels else "gpu-server-001",
        "runner_group_name": "GitHub Actions" if "self-hosted" not in labels else "Default",
        "started_at": started,
        "completed_at": completed,
        "conclusion": conclusion,
        "steps": steps or [],
    }


JOBS_JSON = {
    "total_count": 5,
    "jobs": [
        # github-hosted, clean success, 300s. No log scan (success).
        _job(1, "build", ["ubuntu-latest"], "2026-09-09T12:00:00Z", "2026-09-09T12:05:00Z", "success"),
        # github-hosted, OOM-killed, 120s.
        _job(2, "test-oom", ["ubuntu-latest"], "2026-09-09T12:00:00Z", "2026-09-09T12:02:00Z", "failure"),
        # github-hosted, out of disk, 90s.
        _job(3, "test-nospace", ["ubuntu-latest"], "2026-09-09T12:00:00Z", "2026-09-09T12:01:30Z", "failure"),
        # github-hosted, timed out, 21600s (6h), via a step marked timed_out AND a log line.
        _job(
            4, "e2e-timeout", ["ubuntu-latest"], "2026-09-09T12:00:00Z", "2026-09-09T18:00:00Z", "cancelled",
            steps=[{"name": "run e2e", "conclusion": "timed_out"}],
        ),
        # self-hosted, clean success, 900s — the hosted-vs-self-hosted comparison.
        _job(5, "build-native", ["self-hosted", "linux", "x64"], "2026-09-09T12:00:00Z", "2026-09-09T12:15:00Z", "success"),
    ],
}

LOGS = {
    2: "2026-09-09T12:01:59Z ##[group]Run tests\ngcc: fatal error: Killed signal terminated program cc1plus\n"
       "Out of memory: Killed process 4242 (cc1plus)\n##[error]Process completed with exit code 137.\n",
    3: "2026-09-09T12:01:29Z tar: write error: No space left on device\n"
       "##[error]Process completed with exit code 2.\n",
    4: "2026-09-09T18:00:00Z ##[error]The job running on runner GitHub Actions 2 has exceeded the maximum execution time of 360 minutes.\n"
       "Error: The operation was canceled.\n",
}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):  # keep the test output quiet
        pass

    def _send(self, code, body: bytes, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        base = f"/repos/{OWNER}/{REPO}"
        if path == base:
            return self._send(200, json.dumps(REPO_JSON).encode())
        if path == f"{base}/actions/runs":
            return self._send(200, json.dumps(RUNS_JSON).encode())
        if path == f"{base}/actions/runs/1001/jobs":
            return self._send(200, json.dumps(JOBS_JSON).encode())
        m = re.fullmatch(rf"{re.escape(base)}/actions/jobs/(\d+)/logs", path)
        if m:
            job_id = int(m.group(1))
            log = LOGS.get(job_id)
            if log is None:
                return self._send(404, b"")
            return self._send(200, log.encode(), ctype="text/plain")
        return self._send(404, b"")


def parse_prom(text: str):
    """{ metric_name: [ (labels_dict, value), ... ] }"""
    out: dict[str, list] = {}
    line_re = re.compile(r"^(\w+)(?:\{([^}]*)\})?\s+([\d.eE+-]+)$")
    for line in text.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        m = line_re.match(line)
        assert m, f"unparseable metric line: {line!r}"
        name, lbls, val = m.group(1), m.group(2) or "", m.group(3)
        labels = {}
        for pair in re.findall(r'(\w+)="((?:[^"\\]|\\.)*)"', lbls):
            labels[pair[0]] = pair[1].replace('\\"', '"').replace("\\\\", "\\")
        out.setdefault(name, []).append((labels, float(val)))
    return out


def find(series, **want):
    hits = [(l, v) for (l, v) in series if all(l.get(k) == str(v2) for k, v2 in want.items())]
    return hits


def main() -> int:
    exporter = os.environ["EXPORTER"]

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = srv.server_address[1]

    with tempfile.TemporaryDirectory() as d:
        out = os.path.join(d, "github-actions-fit.prom")
        env = dict(
            os.environ,
            GHA_OUTPUT=out,
            GHA_API=f"http://127.0.0.1:{port}",
            GHA_REPOS_JSON=json.dumps([{"owner": OWNER, "repo": REPO}]),
            GHA_SCAN_LOGS="1",
        )
        subprocess.run([exporter], env=env, check=True, timeout=60)
        with open(out, encoding="utf-8") as fh:
            metrics = parse_prom(fh.read())

    srv.shutdown()

    fails = []

    def check(cond, msg):
        if not cond:
            fails.append(msg)

    dur = metrics.get("github_actions_job_duration_seconds", [])
    lim = metrics.get("github_actions_job_resource_limit", [])

    # (a) DURATION + classification -------------------------------------------
    check(bool(metrics.get("github_actions_fit_exporter_up")), "exporter_up missing")

    h_build = find(dur, job="build", runner_type="github-hosted", visibility="public")
    check(len(h_build) == 1 and h_build[0][1] == 300.0,
          f"github-hosted build duration != 300s: {h_build}")

    s_native = find(dur, job="build-native", runner_type="self-hosted", visibility="public")
    check(len(s_native) == 1 and s_native[0][1] == 900.0,
          f"self-hosted build-native duration != 900s: {s_native}")

    # workflow label propagated; no duplicate series
    check(all(l.get("workflow") == "CI" for l, _ in dur), "workflow label missing/wrong")
    keys = [(l["job"], l["runner_type"]) for l, _ in dur]
    check(len(keys) == len(set(keys)), f"duplicate duration series: {keys}")

    # (b) RESOURCE-LIMIT SIGNATURES -------------------------------------------
    check(bool(find(lim, job="test-oom", signature="oom", visibility="public")),
          "OOM signature not detected on test-oom")
    check(bool(find(lim, job="test-nospace", signature="no_space")),
          "no_space signature not detected on test-nospace")
    check(bool(find(lim, job="e2e-timeout", signature="timeout")),
          "timeout signature not detected on e2e-timeout")
    # The clean success must NOT carry any resource-limit series.
    check(not find(lim, job="build"), "resource_limit falsely emitted for a clean success (build)")
    check(not find(lim, job="build-native"), "resource_limit falsely emitted for build-native")

    if fails:
        for f in fails:
            print(f"[fit-exporter-test][FAIL] {f}", file=sys.stderr)
        return 1
    print("[fit-exporter-test][PASS] duration+classification and all three "
          "resource-limit signatures verified against the mock Actions API")
    return 0


if __name__ == "__main__":
    sys.exit(main())
