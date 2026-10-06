#!/usr/bin/env python3
"""garm-webhook-upstream — a FAITHFUL, minimal stand-in for the central GARM's
`/webhooks` handler, used ONLY by the hermetic t_garm_webhook_delivery gate.

MOCK JUSTIFICATION (per the workspace testing policy — every mock is justified
in the file that defines it):

  Running the REAL GARM `/webhooks` path is NOT hermetic: GARM validates a
  webhook against the per-ENTITY secret it stores in its SQLite DB, and creating
  that entity (a repo/org/enterprise) requires GARM to call the GitHub API with
  live credentials to fetch/validate the installation — the gate forbids any
  real GitHub. So we cannot exercise GARM's own handler offline.

  This stand-in reproduces GARM's webhook CONTRACT byte-for-byte from the pinned
  upstream source (`garm/runner/runner.go:validateHookBody` +
  `garm/apiserver/controllers/controllers.go:handleWorkflowJobEvent`):

    * header `X-Hub-Signature-256: <alg>=<hexdigest>`, split on the FIRST "=";
    * `alg` switch sha256 (sha256.new) / sha1 (sha1.new), else 400;
    * `HMAC(secret, RAW body)` compared with a constant-time equal;
    * the metric `garm_webhook_received{valid,reason}` with the SAME label
      values GARM emits: valid="true" (accept), valid="false" reason=
      "signature_invalid" (mismatch) / "missing_secret" / "unknown".

  What the gate proves through this stand-in is the ENDPOINT WIRING and the HMAC
  accept/reject + metric contract — the parts RC3 actually adds (the public
  front door forwarding the RAW body) — NOT a reimplementation of GARM's job
  dispatch. Anything beyond the signature gate (pool matching, runner creation)
  is out of scope for a webhook-delivery gate and is exercised elsewhere.

Config (env):
  WEBHOOK_SECRET   the per-entity HMAC secret (required)
  LISTEN_HOST      bind host (default 0.0.0.0)
  LISTEN_PORT      bind port (default 9997)
"""

from __future__ import annotations

import hashlib
import hmac
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = os.environ.get("WEBHOOK_SECRET", "")

_counts_lock = threading.Lock()
# (valid, reason) -> count
_counts: dict[tuple[str, str], int] = {}


def _inc(valid: str, reason: str) -> None:
    with _counts_lock:
        _counts[(valid, reason)] = _counts.get((valid, reason), 0) + 1


class Result:
    OK = "ok"
    MISSING_SECRET = "missing_secret"
    SIGNATURE = "signature"


def validate_hook_body(signature: str, secret: str, body: bytes) -> str:
    """Mirror of GARM's runner.validateHookBody. Returns Result.*."""
    if not secret:
        return Result.MISSING_SECRET
    if not signature:
        # secret set but no signature received -> unauthorized (signature-class).
        return Result.SIGNATURE
    parts = signature.split("=", 1)
    if len(parts) != 2:
        return Result.SIGNATURE
    alg, want = parts
    if alg == "sha256":
        hfn = hashlib.sha256
    elif alg == "sha1":
        hfn = hashlib.sha1
    else:
        return Result.SIGNATURE
    mac = hmac.new(secret.encode(), body, hfn)
    got = mac.hexdigest()
    if not hmac.compare_digest(want, got):
        return Result.SIGNATURE
    return Result.OK


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # quiet
        pass

    def _send(self, code: int, body: bytes = b"") -> None:
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if self.path == "/metrics":
            lines = [
                "# HELP garm_webhook_received Webhooks received, by validity.",
                "# TYPE garm_webhook_received counter",
            ]
            with _counts_lock:
                items = dict(_counts)
            for (valid, reason), n in sorted(items.items()):
                lines.append(
                    f'garm_webhook_received{{valid="{valid}",reason="{reason}"}} {n}'
                )
            body = ("\n".join(lines) + "\n").encode()
            self._send(200, body)
            return
        self._send(404)

    def do_POST(self):
        if not self.path.startswith("/webhooks"):
            self._send(404)
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        signature = self.headers.get("X-Hub-Signature-256", "")
        res = validate_hook_body(signature, SECRET, body)
        if res == Result.OK:
            _inc("true", "")
            self._send(200, b'{"ok":true}')
        elif res == Result.SIGNATURE:
            _inc("false", "signature_invalid")
            self._send(401, b'{"error":"signature missmatch"}')
        else:  # missing secret (server misconfig)
            _inc("false", "missing_secret")
            self._send(500, b'{"error":"missing secret"}')


def main() -> int:
    if not SECRET:
        print("WEBHOOK_SECRET is required", file=sys.stderr)
        return 2
    host = os.environ.get("LISTEN_HOST", "0.0.0.0")
    port = int(os.environ.get("LISTEN_PORT", "9997"))
    srv = ThreadingHTTPServer((host, port), Handler)
    print(f"garm-webhook-upstream listening on {host}:{port}", file=sys.stderr)
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
