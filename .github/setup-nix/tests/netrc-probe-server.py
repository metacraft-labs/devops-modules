#!/usr/bin/env python3
"""netrc-probe-server.py — a throwaway HTTP origin that journals the credential
each request arrived with.

It exists so `netrc-wire-test.sh` can assert what a netrc file makes curl SEND,
rather than asserting what the file CONTAINS. Those are different claims: a
`machine` name carrying a port or a path parses fine, reads fine, and matches
nothing, which is indistinguishable from the missing-entry defect the netrc
change fixes. Only the wire tells them apart, and curl is the right witness
because curl is the client nix hands the file to (`CURLOPT_NETRC_FILE`).

Behaviour, deliberately the Attic server's shape:

  * A request with no `Authorization` is answered 401 with a `WWW-Authenticate:
    Basic` challenge. That is what a private binary cache does to an
    unauthenticated `GET /nix-cache-info`, and it is also the belt-and-braces
    path for a curl that declines to send credentials preemptively.
  * A request with Basic credentials is answered 200.

Every request is journalled as one tab-separated line:

    <path>\t<username>\t<password>

with `-` for an absent credential, and `?` for an `Authorization` header that
is not decodable Basic. The password is journalled in full: everything this
server ever sees is a fixture value minted by the suite.

Provenance: copied from metacraft-labs/metacraft-github-actions@03056f3,
`setup-nix/netrc-probe-server.py`, where the same defect was fixed first. Kept
byte-compatible apart from the suite name above so the two stay comparable.

Usage:
    netrc-probe-server.py --journal FILE
      binds 127.0.0.1 on an ephemeral port and prints that port on stdout.
"""

import argparse
import base64
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    journal_path = None
    journal_lock = threading.Lock()

    # Quiet: the suite reads the journal, and stderr chatter would drown its
    # own diagnostics.
    def log_message(self, fmt, *args):  # noqa: A003
        pass

    def _record(self, user, password):
        line = "{}\t{}\t{}\n".format(self.path, user, password)
        with Handler.journal_lock:
            with open(Handler.journal_path, "a", encoding="utf-8") as fh:
                fh.write(line)
                fh.flush()

    def do_GET(self):  # noqa: N802
        header = self.headers.get("Authorization")
        if header is None:
            self._record("-", "-")
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="probe"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        user, password = "?", "?"
        if header.startswith("Basic "):
            try:
                raw = base64.b64decode(header[len("Basic "):], validate=True)
                decoded = raw.decode("utf-8")
                user, _, password = decoded.partition(":")
                if user == "":
                    user = "<empty>"
                if password == "":
                    password = "<empty>"
            except Exception:
                user, password = "?", "?"
        self._record(user, password)

        body = b"StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 40\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/x-nix-cache-info")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--journal", required=True)
    args = parser.parse_args()

    Handler.journal_path = args.journal
    open(args.journal, "a", encoding="utf-8").close()

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    sys.stdout.write("{}\n".format(httpd.server_address[1]))
    sys.stdout.flush()
    httpd.serve_forever()


if __name__ == "__main__":
    main()
