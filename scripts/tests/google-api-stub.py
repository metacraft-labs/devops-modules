#!/usr/bin/env python3
"""A local stand-in for the Google endpoints google-workspace-domains calls:
the OAuth token endpoint (domain-wide delegation JWT bearer grant), the Admin
SDK Directory domains/domainAliases resources and the Site Verification API.

    google-api-stub.py STATE.json DNS_DIR LOG PORT_FILE

STATE.json is re-read on every request, so a test changes behaviour by editing
it between runs:

    {"domains": {"example.com": {"isPrimary": true, "verified": true}},
     "aliases": {"example.org": {"parent": "example.com", "verified": false}},
     "deny_scopes": ["admin.directory.domain"],   # token refused: unauthorized_client
     "site_api_disabled": false}                  # 403 accessNotConfigured

webResource.insert succeeds only when DNS_DIR/<domain> (the stub resolver's
TXT answer for the apex) holds the token getToken issued; it then marks the
domain or alias verified. Every request is appended to LOG as
"<METHOD> <path> <scope the bearer token was minted for>". No network beyond
127.0.0.1.
"""

import base64
import json
import os
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE, DNS, LOG, PORT_FILE = sys.argv[1:5]
DIR = "/admin/directory/v1/customer/my_customer/"
SCOPE_DOMAIN = "admin.directory.domain"
SCOPE_SITE = "siteverification"


def load():
    with open(STATE) as f:
        s = json.load(f)
    s.setdefault("domains", {})
    s.setdefault("aliases", {})
    return s


def save(s):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f, indent=1, sort_keys=True)
    os.replace(tmp, STATE)


def token_for(domain):
    return "google-site-verification=" + domain.replace(".", "-") + "-Tok_123"


def b64json(seg):
    seg += "=" * (-len(seg) % 4)
    return json.loads(base64.urlsafe_b64decode(seg))


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def scope(self):
        a = self.headers.get("Authorization", "")
        return a[len("Bearer at:") :] if a.startswith("Bearer at:") else ""

    def log(self, scope):
        with open(LOG, "a") as f:
            f.write(f"{self.command} {urllib.parse.urlsplit(self.path).path} {scope}\n")

    def need(self, scope):
        if self.scope() != scope:
            self.reply(403, {"error": {"code": 403, "message": "Request had insufficient authentication scopes."}})
            return False
        return True

    def do_POST(self):
        u = urllib.parse.urlsplit(self.path)
        raw = self.body()
        s = load()
        if u.path == "/token":
            form = urllib.parse.parse_qs(raw.decode())
            claims = b64json(form["assertion"][0].split(".")[1])
            short = claims["scope"].rsplit("/", 1)[-1]
            self.log(f"token:{short}:{claims.get('sub')}")
            if short in s.get("deny_scopes", []):
                return self.reply(
                    401,
                    {
                        "error": "unauthorized_client",
                        "error_description": "Client is unauthorized to retrieve access tokens using this method, "
                        "or client not authorized for any of the scopes requested.",
                    },
                )
            return self.reply(200, {"access_token": "at:" + short, "expires_in": 3600, "token_type": "Bearer"})
        self.log(self.scope())
        if u.path == DIR + "domainaliases":
            if not self.need(SCOPE_DOMAIN):
                return
            b = json.loads(raw)
            name = b["domainAliasName"]
            if name in s["aliases"] or name in s["domains"]:
                return self.reply(409, {"error": {"code": 409, "message": "Entity already exists."}})
            s["aliases"][name] = {"parent": b["parentDomainName"], "verified": False}
            save(s)
            return self.reply(200, {"domainAliasName": name, "parentDomainName": b["parentDomainName"], "verified": False})
        if u.path.startswith("/siteVerification/v1/"):
            if s.get("site_api_disabled"):
                return self.reply(
                    403,
                    {
                        "error": {
                            "code": 403,
                            "message": "Site Verification API has not been used in project 1 before or it is disabled.",
                            "status": "PERMISSION_DENIED",
                            "details": [{"reason": "SERVICE_DISABLED"}],
                        }
                    },
                )
            if not self.need(SCOPE_SITE):
                return
            b = json.loads(raw)
            domain = b["site"]["identifier"]
            if u.path == "/siteVerification/v1/token":
                return self.reply(200, {"method": "DNS_TXT", "token": token_for(domain)})
            if u.path == "/siteVerification/v1/webResource":
                if urllib.parse.parse_qs(u.query).get("verificationMethod") != ["DNS_TXT"]:
                    return self.reply(400, {"error": {"code": 400, "message": "bad verificationMethod"}})
                try:
                    with open(os.path.join(DNS, domain)) as f:
                        served = f.read()
                except OSError:
                    served = ""
                if f'"{token_for(domain)}"' not in served:
                    return self.reply(
                        400,
                        {"error": {"code": 400, "message": "The necessary verification token could not be found on your site."}},
                    )
                for coll in ("domains", "aliases"):
                    if domain in s[coll]:
                        s[coll][domain]["verified"] = True
                save(s)
                return self.reply(200, {"id": "dns://" + domain, "site": b["site"], "owners": ["admin@example.com"]})
        return self.reply(404, {"error": {"code": 404, "message": "no such stub route"}})

    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        self.log(self.scope())
        s = load()
        for coll, prefix in (("domains", DIR + "domains/"), ("aliases", DIR + "domainaliases/")):
            if u.path.startswith(prefix):
                if not self.need(SCOPE_DOMAIN):
                    return
                name = urllib.parse.unquote(u.path[len(prefix) :])
                if name not in s[coll]:
                    return self.reply(404, {"error": {"code": 404, "message": "Resource Not Found: domain"}})
                d = s[coll][name]
                if coll == "domains":
                    return self.reply(200, {"domainName": name, "isPrimary": d.get("isPrimary", False), "verified": d["verified"]})
                return self.reply(200, {"domainAliasName": name, "parentDomainName": d["parent"], "verified": d["verified"]})
        return self.reply(404, {"error": {"code": 404, "message": "no such stub route"}})


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(PORT_FILE + ".tmp", "w") as f:
    f.write(str(srv.server_address[1]))
os.replace(PORT_FILE + ".tmp", PORT_FILE)
srv.serve_forever()
