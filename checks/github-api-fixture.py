#!/usr/bin/env python3
"""github-api-fixture — a tiny stand-in for the GitHub REST endpoints the
garm-fleet-external-checks exporter reads, used ONLY by t_garm_webhook_delivery.

MOCK JUSTIFICATION: the gate is hermetic (no real GitHub). The exporter's
delivery-health check calls `GET /orgs/{org}/hooks/{id}/deliveries`; to prove
its "last delivery non-2xx -> github_webhook_last_delivery_ok 0" logic FIRES on
a broken delivery, we serve that exact endpoint with a fixture whose most-recent
delivery has a non-2xx status_code. This exercises the REAL exporter code
(github-fleet-checks.py runs unmodified against it) — only the upstream GitHub
API is faked, which is unavoidable offline.

Config (env):
  FIXTURE_PORT       bind port (default 8080)
  DELIVERY_STATUS    status_code for the most-recent delivery (default 502)
"""

from __future__ import annotations

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATUS = int(os.environ.get("DELIVERY_STATUS", "502"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        # /orgs/{org}/hooks/{id}/deliveries[?...]
        if "/hooks/" in self.path and "/deliveries" in self.path:
            deliveries = [
                {"id": 3, "status_code": STATUS, "status": "failed"},
                {"id": 2, "status_code": 200, "status": "OK"},
                {"id": 1, "status_code": STATUS, "status": "failed"},
            ]
            body = json.dumps(deliveries).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()


def main() -> int:
    port = int(os.environ.get("FIXTURE_PORT", "8080"))
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"github-api-fixture on :{port} (delivery status {STATUS})", file=sys.stderr)
    srv.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
