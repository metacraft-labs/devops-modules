#!/usr/bin/env python3
"""github-actions-fit-exporter — "does this workflow fit ubuntu-latest?" signal.

Runner-Fleet-Capability-Pools-And-Remote-Driving RD4 (`t_runner_fit_monitoring`).

The operator's question is concrete: a public-repo workflow that was moved to a
free GitHub-hosted `ubuntu-latest` runner (Ubuntu 24.04: 4 vCPU / 16 GB RAM /
14 GB SSD on public repos; 2 vCPU / 8 GB / 14 GB on private) either FITS or it
does not. It does not fit when it gets much SLOWER than it used to, or when it
hits a hard RESOURCE LIMIT — OOM-kill, `No space left on device` (the ~14 GB
SSD), or the job timeout. This exporter turns the GitHub Actions API into the two
Prometheus signals that answer that, per (workflow × runner-type):

  * DURATION — how long each job takes, split github-hosted vs self-hosted, so a
    regression after the move is visible and a hosted-vs-self-hosted comparison is
    possible. (`github_actions_job_duration_seconds`)
  * RESOURCE-LIMIT FAILURE SIGNATURES — detected by scanning the job LOGS of
    non-success jobs for OOM / no-space / timeout patterns.
    (`github_actions_job_resource_limit`)

This is a GENERAL, company-agnostic exporter: which orgs/repos to watch, the API
base, the token, and the lookback are all config (env). It writes a node-exporter
TEXTFILE-collector snapshot atomically (same shape as
win-runner-mem-sampler.py / github-fleet-checks.py), so it needs NO new scrape
target — the existing node-exporter textfile collector picks it up. The alert
rules over these metrics live in the companion `github-actions-fit-alerts`
library; the concrete instantiation (orgs, token, thresholds, the pinned
ubuntu-latest baseline) lives in the operator's `infra`.

Metrics emitted:
  github_actions_job_duration_seconds{repo,workflow,job,runner_type,visibility}
      wall-clock seconds of the MOST RECENT completed run of that job.
  github_actions_job_resource_limit{repo,workflow,job,runner_type,visibility,signature}
      1 when the most recent non-success run of that job matched a resource-limit
      signature (signature = oom | no_space | timeout); absent otherwise.
  github_actions_fit_exporter_up
      1 when the exporter completed a full cycle (self-liveness).

runner_type is `self-hosted` when the job's labels contain `self-hosted`, else
`github-hosted`. visibility is the repo's `public`/`private`.

Config (env):
  GHA_OUTPUT         path to the .prom textfile to write (required)
  GHA_API            GitHub API base (default https://api.github.com)
  GHA_TOKEN_FILE     file containing a GitHub token (optional; unauth otherwise)
  GHA_REPOS_FILE     path to a JSON file listing {"owner","repo"} to inspect
                     (preferred; a path survives systemd's Environment= quote
                     parsing intact, whereas inline JSON has its "-quotes eaten)
  GHA_REPOS_JSON     inline JSON list of {"owner","repo"} (compat fallback when
                     GHA_REPOS_FILE is unset)
  GHA_LOOKBACK_RUNS  recent completed runs per repo to inspect (default 40)
  GHA_SCAN_LOGS      "1"/"0" — fetch+scan logs of non-success jobs (default 1)

Only stdlib is used (urllib/json/re/zipfile) so the exporter has no runtime deps
and is trivial to package. It is fail-soft per repo: one broken repo reports
nothing for itself and does not abort the others; the cycle still writes a file
and sets github_actions_fit_exporter_up so a dead exporter is distinguishable
from a healthy one that simply found nothing.
"""

from __future__ import annotations

import io
import json
import os
import re
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

API = os.environ.get("GHA_API", "https://api.github.com").rstrip("/")
USER_AGENT = "github-actions-fit-exporter/1"

# ── Resource-limit signatures ──────────────────────────────────────────────
#
# Matched case-insensitively against the plain-text job log. Each entry is a
# label value plus a compiled regex. These are deliberately SPECIFIC strings
# GitHub/Linux emit, not broad words, so a job that merely mentions "timeout" in
# its own output does not trip the timeout signature.
_SIGNATURES = [
    (
        "oom",
        re.compile(
            r"out of memory"
            r"|oom-?kill"
            r"|killed process \d+"
            r"|cannot allocate memory"
            r"|std::bad_alloc"
            r"|fatal error: .*memory exhausted"
            r"|exit code 137"  # 128 + SIGKILL(9): the classic OOM-kill exit
            r"|##\[error\].*\bkilled\b",
            re.IGNORECASE,
        ),
    ),
    (
        "no_space",
        re.compile(
            r"no space left on device"
            r"|enospc"
            r"|write error: no space"
            r"|disk quota exceeded"
            r"|there is not enough space on the disk",
            re.IGNORECASE,
        ),
    ),
    (
        "timeout",
        re.compile(
            r"exceeded the maximum execution time"
            r"|the job running on runner .* has exceeded"
            r"|##\[error\]the (?:action|operation|step) .* has timed out"
            r"|error: the operation was canceled\.?\s*$"
            r"|cancelling since the timeout",
            re.IGNORECASE,
        ),
    ),
]

# Runs whose conclusion is worth a log scan (a success never hit a limit).
_NON_SUCCESS = {"failure", "cancelled", "timed_out", "stale"}


def _read_file(path: str) -> str:
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read().strip()


def load_repos() -> list:
    """The watched-repos list, from GHA_REPOS_FILE (a path) or GHA_REPOS_JSON.

    GHA_REPOS_FILE wins: a filesystem path carries no shell-special characters,
    so it survives systemd's `Environment=` shell-quote parsing unchanged. An
    inline GHA_REPOS_JSON value, by contrast, has its JSON double-quotes stripped
    by that same parsing before the process starts, which used to make the very
    first `json.loads` here fail at runtime. GHA_REPOS_JSON is kept as a
    compatibility path for ad-hoc invocation and tests.
    """
    path = os.environ.get("GHA_REPOS_FILE")
    if path:
        return json.loads(_read_file(path))
    return json.loads(os.environ.get("GHA_REPOS_JSON", "[]"))


def _request(url: str, token: str | None, raw: bool = False):
    """GET url. Returns (status, parsed_json | raw_bytes | None). Never raises."""
    req = urllib.request.Request(url, method="GET")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", USER_AGENT)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read()
            if raw:
                return resp.status, body
            text = body.decode("utf-8")
            return resp.status, (json.loads(text) if text else None)
    except urllib.error.HTTPError as exc:
        return exc.code, None
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return 0, None


def _parse_ts(value: str | None) -> float | None:
    """ISO-8601 (e.g. 2026-09-09T12:00:00Z) -> unix seconds."""
    if not value:
        return None
    try:
        return time.mktime(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")) - time.timezone
    except (ValueError, TypeError):
        return None


def _runner_type(job: dict) -> str:
    labels = [str(x).lower() for x in (job.get("labels") or [])]
    if "self-hosted" in labels:
        return "self-hosted"
    return "github-hosted"


def _fetch_log_text(owner: str, repo: str, job_id, token: str | None) -> str:
    """The job-logs endpoint returns either plain text or a zip; handle both."""
    url = f"{API}/repos/{owner}/{repo}/actions/jobs/{job_id}/logs"
    status, body = _request(url, token, raw=True)
    if status != 200 or not body:
        return ""
    # A zip archive starts with 'PK'. Real GitHub returns a 302 to a text
    # download (urllib follows it); a zip is the other documented shape.
    if body[:2] == b"PK":
        try:
            zf = zipfile.ZipFile(io.BytesIO(body))
            return "\n".join(
                zf.read(n).decode("utf-8", "replace") for n in zf.namelist()
            )
        except (zipfile.BadZipFile, OSError):
            return ""
    return body.decode("utf-8", "replace")


def _signatures_in(text: str) -> list[str]:
    return [name for name, rx in _SIGNATURES if rx.search(text)]


def _quote(v: str) -> str:
    return str(v).replace("\\", "\\\\").replace('"', '\\"')


def _labels(d: dict) -> str:
    return ",".join(f'{k}="{_quote(v)}"' for k, v in d.items())


def check_repo(spec: dict, token: str | None, lookback: int, scan_logs: bool) -> list[str]:
    """Emit duration + resource-limit metric lines for one repo. Fail-soft."""
    owner = spec["owner"]
    repo = spec["repo"]
    lines: list[str] = []

    # Repo visibility (public vs private) — the alert scopes to public repos.
    status, repo_json = _request(f"{API}/repos/{owner}/{repo}", token)
    if status != 200 or not isinstance(repo_json, dict):
        return lines
    visibility = repo_json.get("visibility") or (
        "private" if repo_json.get("private") else "public"
    )

    # Most recent completed runs, newest first (the API default order).
    q = urllib.parse.urlencode({"status": "completed", "per_page": lookback})
    status, runs_json = _request(f"{API}/repos/{owner}/{repo}/actions/runs?{q}", token)
    if status != 200 or not isinstance(runs_json, dict):
        return lines
    runs = runs_json.get("workflow_runs") or []

    # First-seen wins: runs come newest-first, so the first time we see a
    # (workflow, job, runner_type) triple is its MOST RECENT result. This keeps
    # the textfile free of duplicate label sets (a textfile with two identical
    # series is rejected by the collector).
    seen_duration: set[tuple] = set()
    seen_limit: set[tuple] = set()

    for run in runs:
        workflow = run.get("name") or run.get("display_title") or "unknown"
        run_id = run.get("id")
        if run_id is None:
            continue
        status, jobs_json = _request(
            f"{API}/repos/{owner}/{repo}/actions/runs/{run_id}/jobs?per_page=100",
            token,
        )
        if status != 200 or not isinstance(jobs_json, dict):
            continue
        for job in jobs_json.get("jobs") or []:
            name = job.get("name") or "unknown"
            rtype = _runner_type(job)
            wf = job.get("workflow_name") or workflow
            base = {
                "repo": f"{owner}/{repo}",
                "workflow": wf,
                "job": name,
                "runner_type": rtype,
                "visibility": visibility,
            }
            key = (base["repo"], wf, name, rtype)

            # Duration of the most recent run of this job.
            start = _parse_ts(job.get("started_at"))
            end = _parse_ts(job.get("completed_at"))
            if start is not None and end is not None and end >= start and key not in seen_duration:
                seen_duration.add(key)
                lines.append(
                    f"github_actions_job_duration_seconds{{{_labels(base)}}} {end - start:.0f}"
                )

            # Resource-limit signatures on the most recent non-success run.
            conclusion = (job.get("conclusion") or "").lower()
            if not scan_logs or conclusion not in _NON_SUCCESS or key in seen_limit:
                continue
            sigs = set()
            # A step marked timed_out is an authoritative timeout signal that
            # needs no log fetch.
            for step in job.get("steps") or []:
                if (step.get("conclusion") or "").lower() == "timed_out":
                    sigs.add("timeout")
            text = _fetch_log_text(owner, repo, job.get("id"), token)
            if text:
                sigs.update(_signatures_in(text))
            if sigs:
                seen_limit.add(key)
                for sig in sorted(sigs):
                    lab = dict(base, signature=sig)
                    lines.append(f"github_actions_job_resource_limit{{{_labels(lab)}}} 1")

    return lines


def main() -> int:
    output = os.environ.get("GHA_OUTPUT")
    if not output:
        print("GHA_OUTPUT is required", file=sys.stderr)
        return 2

    token = None
    token_file = os.environ.get("GHA_TOKEN_FILE")
    if token_file and os.path.exists(token_file):
        token = _read_file(token_file)

    repos = load_repos()
    lookback = int(os.environ.get("GHA_LOOKBACK_RUNS", "40"))
    scan_logs = os.environ.get("GHA_SCAN_LOGS", "1") != "0"

    lines: list[str] = [
        "# HELP github_actions_job_duration_seconds Wall-clock seconds of the most recent completed run of a job, by runner_type.",
        "# TYPE github_actions_job_duration_seconds gauge",
        "# HELP github_actions_job_resource_limit The most recent non-success run of this job hit a resource-limit signature (1).",
        "# TYPE github_actions_job_resource_limit gauge",
        "# HELP github_actions_fit_exporter_up The fit exporter completed a full cycle.",
        "# TYPE github_actions_fit_exporter_up gauge",
    ]

    for spec in repos:
        try:
            lines.extend(check_repo(spec, token, lookback, scan_logs))
        except Exception:  # noqa: BLE001 - fail-soft per repo.
            continue

    lines.append("github_actions_fit_exporter_up 1")

    out_dir = os.path.dirname(output) or "."
    fd, tmp = tempfile.mkstemp(dir=out_dir, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        os.replace(tmp, output)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return 0


if __name__ == "__main__":
    sys.exit(main())
