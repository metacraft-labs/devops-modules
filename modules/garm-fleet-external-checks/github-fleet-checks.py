#!/usr/bin/env python3
"""garm-fleet-external-checks — the two runner-chain checks garm_* cannot see.

Runner-Fleet-Capability-Pools-And-Remote-Driving RE1. GARM only observes what
reaches it; two links in the chain are invisible to `garm_*`:

  1. GitHub App token / JWT validity. GARM needs an installation token to
     register and reap runners. The App private key does not carry a readable
     expiry, and a rotated/revoked key or a removed installation is invisible
     until a mint fails — so we MINT one and report success + the token expiry.

  2. Webhook delivery health (POST-PHASE-C). Pool mode needs GitHub -> GARM
     webhook POSTs; a dead tunnel/relay looks identical to "no jobs". GitHub's
     own delivery ledger (`GET /orgs/{org}/hooks/{id}/deliveries`) is the
     authoritative signal.

This is a general, company-agnostic exporter: everything host/org-specific comes
from config (env). It writes a node-exporter TEXTFILE snapshot (the same shape
as win-runner-mem-sampler.py) rendered atomically, so a partial write never
yields half a scrape. Alert rules over these metrics live in the
garm-fleet-alerts library.

Metrics emitted:
  github_app_installation_token_mint_ok{app}                      1 ok / 0 fail
  github_app_installation_token_expiry_timestamp_seconds{app}     unix ts of the minted token
  github_webhook_last_delivery_ok{org,hook_id}                    1 if last delivery 2xx
  github_webhook_deliveries_failed_total{org,hook_id}             non-2xx in the recent page
  probe_success{endpoint,name}                                    1 if the public webhook endpoint answered (blackbox)
  probe_http_status_code{endpoint,name}                           the status the endpoint returned to an unsigned probe
  github_fleet_checks_up                                          exporter self-liveness

RC3 (Runner-Fleet-Capability-Pools): the webhook-endpoint blackbox probe
(`probe_success`) is the second delivery-health signal GARM cannot see — a dead
Cloudflare Tunnel / NetBird relay / expired cert looks identical to "no jobs".
We POST an UNSIGNED workflow_job-shaped body and expect the endpoint to reject
it (a 4xx) — a rejection proves the whole path (tunnel/relay -> GARM) is alive
and reachable, WITHOUT a valid signature ever reaching GARM. probe_success is 1
when the endpoint answered at all (connection completed); 0 on a connect/TLS
failure or timeout. It feeds the RE1b GithubWebhookEndpointProbeDown alert.

Config (env):
  GFC_OUTPUT            path to the .prom textfile to write (required)
  GFC_CONFIG_FILE      JSON file {"apps":[...],"webhooks":[...],"probes":[...]}
                       (preferred — quote-safe; the module always sets this)
  GFC_APPS_JSON        JSON list of {"app","app_id","installation_id","private_key_file"} (fallback)
  GFC_WEBHOOKS_JSON    JSON list of {"org","hook_id","token_file"} (fallback)
  GFC_PROBES_JSON      JSON list of {"name","url","expect_reject"(bool,default true)} (fallback)
  GFC_API              GitHub API base (default https://api.github.com)

Dependencies: PyJWT (`jwt`) for the RS256 App JWT; the rest is stdlib.
The exporter is deliberately fail-soft per target: one broken App/hook reports
its own 0 and does not abort the others.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.request

try:
    import jwt  # PyJWT
except ImportError:  # pragma: no cover - packaged with PyJWT in the module
    jwt = None


API = os.environ.get("GFC_API", "https://api.github.com")
USER_AGENT = "garm-fleet-external-checks/1"


def _read_file(path: str) -> str:
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read().strip()


def _api_request(method: str, url: str, token: str, jwt_auth: bool = False):
    """Return (status_code, parsed_json_or_none). Never raises for HTTP errors."""
    scheme = "Bearer" if jwt_auth else "token"
    req = urllib.request.Request(url, method=method)
    req.add_header("Authorization", f"{scheme} {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", USER_AGENT)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8")
            return resp.status, (json.loads(body) if body else None)
    except urllib.error.HTTPError as exc:
        return exc.code, None
    except (urllib.error.URLError, TimeoutError, OSError):
        return 0, None


def _app_jwt(app_id: str, private_key: str) -> str:
    now = int(time.time())
    payload = {"iat": now - 60, "exp": now + 540, "iss": str(app_id)}
    return jwt.encode(payload, private_key, algorithm="RS256")


def check_app(app: dict) -> list[str]:
    """Mint an installation token; report mint_ok + the token expiry."""
    name = app["app"]
    labels = f'app="{name}"'
    ok = 0
    expiry = 0
    try:
        pkey = _read_file(app["private_key_file"])
        signed = _app_jwt(app["app_id"], pkey)
        url = f"{API}/app/installations/{app['installation_id']}/access_tokens"
        status, data = _api_request("POST", url, signed, jwt_auth=True)
        if status == 201 and data and "token" in data:
            ok = 1
            # expires_at is ISO-8601 (e.g. 2026-09-08T12:00:00Z); convert to unix.
            exp = data.get("expires_at")
            if exp:
                expiry = int(
                    time.mktime(time.strptime(exp, "%Y-%m-%dT%H:%M:%SZ"))
                    - time.timezone
                )
    except Exception:  # noqa: BLE001 - fail-soft: this App reports 0.
        ok = 0
    return [
        f"github_app_installation_token_mint_ok{{{labels}}} {ok}",
        f"github_app_installation_token_expiry_timestamp_seconds{{{labels}}} {expiry}",
    ]


def check_webhook(hook: dict) -> list[str]:
    """Read GitHub's delivery ledger for one org webhook."""
    org = hook["org"]
    hook_id = str(hook["hook_id"])
    labels = f'org="{org}",hook_id="{hook_id}"'
    last_ok = 0
    failed = 0
    try:
        token = _read_file(hook["token_file"])
        url = f"{API}/orgs/{org}/hooks/{hook_id}/deliveries?per_page=30"
        status, data = _api_request("GET", url, token)
        if status == 200 and isinstance(data, list) and data:
            # data[0] is the most recent delivery.
            latest = data[0]
            code = int(latest.get("status_code") or 0)
            last_ok = 1 if 200 <= code < 300 else 0
            for d in data:
                c = int(d.get("status_code") or 0)
                if not (200 <= c < 300):
                    failed += 1
    except Exception:  # noqa: BLE001 - fail-soft: this hook reports 0/failed.
        last_ok = 0
    return [
        f"github_webhook_last_delivery_ok{{{labels}}} {last_ok}",
        f"github_webhook_deliveries_failed_total{{{labels}}} {failed}",
    ]


def check_probe(probe: dict) -> list[str]:
    """Blackbox HTTP probe of the public webhook endpoint (RC3).

    POST an UNSIGNED workflow_job-shaped body. A live endpoint fronting GARM
    rejects it (missing/invalid X-Hub-Signature-256 -> 4xx); that rejection is
    exactly the evidence the whole delivery path is reachable. probe_success is
    1 whenever the endpoint answered (any HTTP status), 0 on a transport
    failure. When expect_reject is set (default), a 2xx is treated as a probe
    FAILURE too — an endpoint that accepts an unsigned body is misconfigured
    (HMAC not enforced), which is itself a delivery-health defect worth paging.
    """
    name = probe.get("name", "webhook")
    url = probe["url"]
    expect_reject = probe.get("expect_reject", True)
    labels = f'endpoint="{url}",name="{name}"'
    success = 0
    status = 0
    body = b'{"action":"queued","probe":true}'
    req = urllib.request.Request(url, method="POST", data=body)
    req.add_header("Content-Type", "application/json")
    req.add_header("X-GitHub-Event", "workflow_job")
    req.add_header("User-Agent", USER_AGENT)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            status = resp.status
    except urllib.error.HTTPError as exc:
        # An HTTP error status still means the endpoint ANSWERED — reachable.
        status = exc.code
    except (urllib.error.URLError, TimeoutError, OSError):
        status = 0
    if status:
        rejected = not (200 <= status < 300)
        success = 1 if (rejected or not expect_reject) else 0
    return [
        f"probe_success{{{labels}}} {success}",
        f"probe_http_status_code{{{labels}}} {status}",
    ]


def main() -> int:
    output = os.environ.get("GFC_OUTPUT")
    if not output:
        print("GFC_OUTPUT is required", file=sys.stderr)
        return 2
    if jwt is None:
        print("PyJWT (jwt) is required", file=sys.stderr)
        return 2

    config_file = os.environ.get("GFC_CONFIG_FILE")
    if config_file:
        with open(config_file, "r", encoding="utf-8") as fh:
            conf = json.load(fh)
        apps = conf.get("apps", [])
        webhooks = conf.get("webhooks", [])
        probes = conf.get("probes", [])
    else:
        apps = json.loads(os.environ.get("GFC_APPS_JSON", "[]"))
        webhooks = json.loads(os.environ.get("GFC_WEBHOOKS_JSON", "[]"))
        probes = json.loads(os.environ.get("GFC_PROBES_JSON", "[]"))

    lines: list[str] = [
        "# HELP github_app_installation_token_mint_ok App installation token minting succeeded (1) or failed (0).",
        "# TYPE github_app_installation_token_mint_ok gauge",
        "# HELP github_app_installation_token_expiry_timestamp_seconds Unix expiry of the last minted installation token.",
        "# TYPE github_app_installation_token_expiry_timestamp_seconds gauge",
        "# HELP github_webhook_last_delivery_ok Most recent org-webhook delivery was 2xx (1) or not (0).",
        "# TYPE github_webhook_last_delivery_ok gauge",
        "# HELP github_webhook_deliveries_failed_total Non-2xx deliveries in the recent ledger page.",
        "# TYPE github_webhook_deliveries_failed_total gauge",
        "# HELP probe_success Blackbox probe of the public webhook endpoint answered (1) or not (0).",
        "# TYPE probe_success gauge",
        "# HELP probe_http_status_code Status the public webhook endpoint returned to an unsigned probe.",
        "# TYPE probe_http_status_code gauge",
        "# HELP github_fleet_checks_up The external-checks exporter completed a full cycle.",
        "# TYPE github_fleet_checks_up gauge",
    ]

    for app in apps:
        lines.extend(check_app(app))
    for hook in webhooks:
        lines.extend(check_webhook(hook))
    for probe in probes:
        lines.extend(check_probe(probe))

    lines.append("github_fleet_checks_up 1")

    # Atomic write so a scrape never sees a partial file.
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
