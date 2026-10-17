#!/usr/bin/env python3
"""A local stand-in for the Google endpoints google-workspace-domains calls:
the OAuth token endpoint (domain-wide delegation JWT bearer grant), the Admin
SDK Directory domains/domainAliases/users/aliases resources, the Site
Verification API, the Gmail sendAs and messages.send resources and the Groups
Settings API.

    google-api-stub.py STATE.json DNS_DIR LOG PORT_FILE

STATE.json is re-read on every request, so a test changes behaviour by editing
it between runs:

    {"domains": {"example.com": {"isPrimary": true, "verified": true}},
     "aliases": {"example.org": {"parent": "example.com", "verified": false}},
     "deny_scopes": ["admin.directory.domain"],   # token refused: unauthorized_client
     "site_api_disabled": false,                  # 403 accessNotConfigured
     "verify_lag": 2,                             # see below
     "users": {"admin@example.com": {"aliases": ["a@example.com"]}},
     "sendas": {"admin@example.com": [{"sendAsEmail": "…", "verificationStatus": "accepted"}]},
     "sendas_pending": ["x@example.org"],         # sendAs.create answers pending
     "groups": {"dmarc@example.com": {"whoCanPostMessage": "ALL_IN_DOMAIN_CAN_POST"}},
     "groups_api_disabled": false,                # 403 SERVICE_DISABLED
     "groups_external_forbidden": false}          # PATCH ANYONE_CAN_POST -> 400

"deny_scopes" may name gmail.metadata and gmail.readonly too (the inbound
test's read scopes). messages.send delivers into the stub mailbox of the user
who owns the To address — labels INBOX and SENT — only when the To domain's MX,
as the stub resolver serves it (DNS_DIR/<domain>.MX), names a Google host, and
"inbound_broken" is not set; otherwise SENT only. POST /test/deliver {from,
to, subject} (no token; the tests' stand-in for a message sent from a mailbox
OUTSIDE the tenant) delivers by the same rule, with label INBOX. messages.list
and messages.get (format=metadata: Subject, From, To) read that mailbox.

domainAliases.insert answers 409 "Parent domain <p> is not verified." while the
parent is not verified, as Google does.

A user's nonEditableAliases are derived as Google derives them: every address
of the user at the parent of a VERIFIED domain alias, at the alias. A user
alias can only be added at a verified primary or secondary domain (else 400),
and not when any user already has the address (409). Gmail calls must be made
with a token minted for the user in the path (else 403, delegation denied);
a send-as entry created for one of the user's own addresses is "accepted", any
other "pending". messages.send appends "SENT <user> From=<from> To=<to>" to LOG.

getToken and webResource.insert answer 400 unless the site is INET_DOMAIN and
the method DNS_TXT, the only form the tool may use for a domain.

webResource.insert succeeds only when DNS_DIR/<domain> (the stub resolver's
TXT answer for the apex) holds the token getToken issued; it then marks the
domain or alias verified — at once, or, with "verify_lag": N, only on the Nth
Directory read after it (Google's verification reaches the Directory API with a
delay, and the tool must wait for it; "alias_verify_lag": N does so for
domain aliases alone, whose verification lags most). Each insert is logged as
"VERIFY <domain> accepted|notfound". Every request is appended to LOG as
"<METHOD> <path> <scope the bearer token was minted for>", and every Directory
read of a known domain or alias also as "READ <name> verified=<true|false>". No
network beyond 127.0.0.1.
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
SCOPE_DOMAIN_READ = ("admin.directory.domain", "admin.directory.domain.readonly")
SCOPE_USER = "admin.directory.user"
SCOPE_USER_READ = ("admin.directory.user", "admin.directory.user.readonly")
SCOPE_SITE = "siteverification"
SCOPE_SENDAS = "gmail.settings.sharing"
SCOPE_SENDAS_READ = ("gmail.settings.basic", "gmail.settings.sharing")
SCOPE_SEND = "gmail.send"
SCOPE_GROUPS = "apps.groups.settings"
SCOPE_MAIL_READ = ("gmail.metadata", "gmail.readonly")
USERS = "/admin/directory/v1/users/"
GMAIL = "/gmail/v1/users/"
GROUPS = "/groups/v1/groups/"


def load():
    with open(STATE) as f:
        s = json.load(f)
    for k in ("domains", "aliases", "users", "sendas", "groups", "mail"):
        s.setdefault(k, {})
    return s


def user_view(s, u):
    """users.get as Google answers it, nonEditableAliases derived."""
    own = [u] + s["users"][u].get("aliases", [])
    derived = []
    for alias, a in s["aliases"].items():
        if a.get("verified"):
            derived += [x.split("@")[0] + "@" + alias for x in own if x.split("@")[1] == a["parent"]]
    return {"primaryEmail": u, "aliases": s["users"][u].get("aliases", []), "nonEditableAliases": sorted(derived)}


def addresses_of(s, u):
    v = user_view(s, u)
    return [v["primaryEmail"]] + v["aliases"] + v["nonEditableAliases"]


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

    def token(self):
        a = self.headers.get("Authorization", "")
        return a[len("Bearer at:") :] if a.startswith("Bearer at:") else "|"

    def scope(self):
        return self.token().split("|", 1)[0]

    def sub(self):
        return self.token().split("|", 1)[1]

    def log(self, scope):
        with open(LOG, "a") as f:
            f.write(f"{self.command} {urllib.parse.urlsplit(self.path).path} {scope}\n")

    def need(self, scope):
        ok = (scope,) if isinstance(scope, str) else scope
        if self.scope() not in ok:
            self.reply(403, {"error": {"code": 403, "message": "Request had insufficient authentication scopes."}})
            return False
        return True

    def do_POST(self):
        u = urllib.parse.urlsplit(self.path)
        raw = self.body()
        s = load()
        if u.path == "/test/deliver":
            b = json.loads(raw)
            to = b["to"].lower()
            owner = next((x for x in s["users"] if to in addresses_of(s, x)), None)
            try:
                with open(os.path.join(DNS, to.split("@")[1] + ".MX")) as f:
                    mx = f.read()
            except OSError:
                mx = ""
            ok = bool(owner) and "google.com" in mx and not s.get("inbound_broken")
            with open(LOG, "a") as f:
                f.write(f"DELIVER From={b['from']} To={to} {'delivered' if ok else 'bounced'}\n")
            if ok:
                box = s["mail"].setdefault(owner, [])
                box.append({"id": f"m{len(box) + 1}", "subject": b["subject"], "from": b["from"], "to": to,
                            "labelIds": ["INBOX"]})
                save(s)
            return self.reply(200 if ok else 550, {"delivered": ok})
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
            token = "at:" + short + "|" + str(claims.get("sub"))
            return self.reply(200, {"access_token": token, "expires_in": 3600, "token_type": "Bearer"})
        self.log(self.scope())
        if u.path == DIR + "domains":
            if not self.need(SCOPE_DOMAIN):
                return
            name = json.loads(raw)["domainName"]
            if name in s["aliases"] or name in s["domains"]:
                return self.reply(409, {"error": {"code": 409, "message": "Entity already exists."}})
            s["domains"][name] = {"isPrimary": False, "verified": False}
            save(s)
            return self.reply(200, {"domainName": name, "isPrimary": False, "verified": False})
        if u.path.startswith(USERS) and u.path.endswith("/aliases"):
            if not self.need(SCOPE_USER):
                return
            user = urllib.parse.unquote(u.path[len(USERS) : -len("/aliases")])
            if user not in s["users"]:
                return self.reply(404, {"error": {"code": 404, "message": "Resource Not Found: userKey"}})
            alias = json.loads(raw)["alias"]
            d = alias.split("@")[1]
            if not s["domains"].get(d, {}).get("verified"):
                return self.reply(400, {"error": {"code": 400, "message": "Invalid Input: domain " + d}})
            if any(alias in addresses_of(s, x) for x in s["users"]):
                return self.reply(409, {"error": {"code": 409, "message": "Entity already exists."}})
            s["users"][user].setdefault("aliases", []).append(alias)
            if s.get("alias_lag"):
                s.setdefault("alias_hidden", {})[alias] = s["alias_lag"]
            save(s)
            return self.reply(200, {"alias": alias, "primaryEmail": user})
        if u.path.startswith(GMAIL):
            user = urllib.parse.unquote(u.path[len(GMAIL) :].split("/")[0])
            rest = u.path[len(GMAIL) + len(urllib.parse.quote(user, safe="")) :]
            if rest == "/settings/sendAs":
                if not self.need(SCOPE_SENDAS) or not self.as_user(user):
                    return
                b = json.loads(raw)
                addr = b["sendAsEmail"]
                lst = s["sendas"].setdefault(user, [{"sendAsEmail": user, "isPrimary": True, "verificationStatus": "accepted"}])
                if any(a["sendAsEmail"] == addr for a in lst):
                    return self.reply(409, {"error": {"code": 409, "message": "Already exists"}})
                own = addr in addresses_of(s, user) and addr not in s.get("sendas_pending", [])
                entry = {"sendAsEmail": addr, "treatAsAlias": bool(b.get("treatAsAlias")),
                         "verificationStatus": "accepted" if own else "pending"}
                lst.append(entry)
                save(s)
                return self.reply(200, entry)
            if rest == "/messages/send":
                if not self.need(SCOPE_SEND) or not self.as_user(user):
                    return
                import email
                m = email.message_from_bytes(base64.urlsafe_b64decode(json.loads(raw)["raw"]))
                with open(LOG, "a") as f:
                    f.write(f"SENT {user} From={m['From']} To={m['To']}\n")
                to = str(m["To"]).lower()
                owner = next((x for x in s["users"] if to in addresses_of(s, x)), None)
                try:
                    with open(os.path.join(DNS, to.split("@")[1] + ".MX")) as f:
                        mx = f.read()
                except OSError:
                    mx = ""
                delivered = bool(owner) and "google.com" in mx and not s.get("inbound_broken")

                def put(box_user, labels):
                    box = s["mail"].setdefault(box_user, [])
                    box.append({"id": f"m{len(box) + 1}", "subject": m["Subject"], "from": m["From"], "to": m["To"],
                                "labelIds": labels})

                if delivered and owner == user:
                    put(user, ["INBOX", "SENT"])
                else:
                    put(user, ["SENT"])
                    if delivered:
                        put(owner, ["INBOX"])
                save(s)
                return self.reply(200, {"id": "msg-1", "threadId": "t-1"})
        if u.path == DIR + "domainaliases":
            if not self.need(SCOPE_DOMAIN):
                return
            b = json.loads(raw)
            name = b["domainAliasName"]
            if name in s["aliases"] or name in s["domains"]:
                return self.reply(409, {"error": {"code": 409, "message": "Entity already exists."}})
            if not s["domains"].get(b["parentDomainName"], {}).get("verified"):
                return self.reply(
                    409, {"error": {"code": 409, "message": f"Parent domain {b['parentDomainName']} is not verified."}}
                )
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
            if b["site"].get("type") != "INET_DOMAIN":
                return self.reply(400, {"error": {"code": 400, "message": "bad site type"}})
            if u.path == "/siteVerification/v1/token":
                if b.get("verificationMethod") != "DNS_TXT":
                    return self.reply(400, {"error": {"code": 400, "message": "bad verificationMethod"}})
                return self.reply(200, {"method": "DNS_TXT", "token": token_for(domain)})
            if u.path == "/siteVerification/v1/webResource":
                if urllib.parse.parse_qs(u.query).get("verificationMethod") != ["DNS_TXT"]:
                    return self.reply(400, {"error": {"code": 400, "message": "bad verificationMethod"}})
                try:
                    with open(os.path.join(DNS, domain)) as f:
                        served = f.read()
                except OSError:
                    served = ""
                found = f'"{token_for(domain)}"' in served
                with open(LOG, "a") as f:
                    f.write(f"VERIFY {domain} {'accepted' if found else 'notfound'}\n")
                if not found:
                    return self.reply(
                        400,
                        {"error": {"code": 400, "message": "The necessary verification token could not be found on your site."}},
                    )
                for coll in ("domains", "aliases"):
                    lag = s.get("alias_verify_lag", s.get("verify_lag", 0)) if coll == "aliases" else s.get("verify_lag", 0)
                    if domain in s[coll] and not s[coll][domain].get("verified") and "reads_until_verified" not in s[coll][domain]:
                        if lag > 0:
                            s[coll][domain]["reads_until_verified"] = lag
                        else:
                            s[coll][domain]["verified"] = True
                save(s)
                return self.reply(200, {"id": "dns://" + domain, "site": b["site"], "owners": ["admin@example.com"]})
        return self.reply(404, {"error": {"code": 404, "message": "no such stub route"}})

    def as_user(self, user):
        if self.sub() != user:
            self.reply(403, {"error": {"code": 403, "message": f"Delegation denied for {self.sub()}"}})
            return False
        return True

    def groups(self, s, u, raw=None):
        if s.get("groups_api_disabled"):
            return self.reply(
                403,
                {"error": {"code": 403, "message": "Groups Settings API has not been used in project stub before or it is disabled.",
                           "details": [{"reason": "SERVICE_DISABLED"}]}},
            )
        if not self.need(SCOPE_GROUPS):
            return
        g = urllib.parse.unquote(u.path[len(GROUPS) :])
        if g not in s["groups"]:
            return self.reply(404, {"error": {"code": 404, "message": "Resource Not Found: groupUniqueId"}})
        if raw is not None:
            b = json.loads(raw)
            if b.get("whoCanPostMessage") == "ANYONE_CAN_POST" and s.get("groups_external_forbidden"):
                return self.reply(400, {"error": {"code": 400, "message": "Invalid Value"}})
            s["groups"][g].update(b)
            save(s)
        return self.reply(200, dict(email=g, **s["groups"][g]))

    def do_PATCH(self):
        u = urllib.parse.urlsplit(self.path)
        raw = self.body()
        self.log(self.scope())
        s = load()
        if u.path.startswith(GROUPS):
            return self.groups(s, u, raw)
        return self.reply(404, {"error": {"code": 404, "message": "no such stub route"}})

    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        self.log(self.scope())
        s = load()
        if u.path.startswith(GROUPS):
            return self.groups(s, u)
        if u.path.startswith(USERS):
            if not self.need(SCOPE_USER_READ):
                return
            user = urllib.parse.unquote(u.path[len(USERS) :])
            if user not in s["users"]:
                return self.reply(404, {"error": {"code": 404, "message": "Resource Not Found: userKey"}})
            v = user_view(s, user)
            # "alias_lag": N hides a just-added alias from the next N reads of
            # the user, as Google's directory does for a while.
            hidden = s.setdefault("alias_hidden", {})
            for a in list(hidden):
                if a in v["aliases"]:
                    v["aliases"] = [x for x in v["aliases"] if x != a]
                    hidden[a] -= 1
                    if hidden[a] <= 0:
                        del hidden[a]
            save(s)
            return self.reply(200, v)
        if u.path.startswith(GMAIL) and "/messages" in u.path:
            user = urllib.parse.unquote(u.path[len(GMAIL) :].split("/")[0])
            if not self.need(SCOPE_MAIL_READ) or not self.as_user(user):
                return
            box = list(reversed(s["mail"].get(user, [])))
            rest = u.path.split("/messages", 1)[1]
            if rest in ("", "/"):
                return self.reply(200, {"messages": [{"id": m["id"]} for m in box[:25]]})
            mid = urllib.parse.unquote(rest.lstrip("/"))
            for m in box:
                if m["id"] == mid:
                    return self.reply(200, {"id": mid, "labelIds": m["labelIds"], "payload": {"headers": [
                        {"name": "Subject", "value": m["subject"]},
                        {"name": "From", "value": m.get("from", "")},
                        {"name": "To", "value": m.get("to", "")}]}})
            return self.reply(404, {"error": {"code": 404, "message": "Requested entity was not found."}})
        if u.path.startswith(GMAIL) and u.path.endswith("/settings/sendAs"):
            user = urllib.parse.unquote(u.path[len(GMAIL) : -len("/settings/sendAs")])
            if not self.need(SCOPE_SENDAS_READ) or not self.as_user(user):
                return
            lst = s["sendas"].get(user, [{"sendAsEmail": user, "isPrimary": True, "verificationStatus": "accepted"}])
            return self.reply(200, {"sendAs": lst})
        for coll, prefix in (("domains", DIR + "domains/"), ("aliases", DIR + "domainaliases/")):
            if u.path.startswith(prefix):
                if not self.need(SCOPE_DOMAIN_READ):
                    return
                name = urllib.parse.unquote(u.path[len(prefix) :])
                if name not in s[coll]:
                    return self.reply(404, {"error": {"code": 404, "message": "Resource Not Found: domain"}})
                d = s[coll][name]
                if d.get("reads_until_verified", 0) > 0:
                    d["reads_until_verified"] -= 1
                    if d["reads_until_verified"] == 0:
                        del d["reads_until_verified"]
                        d["verified"] = True
                    save(s)
                with open(LOG, "a") as f:
                    f.write(f"READ {name} verified={str(d['verified']).lower()}\n")
                if coll == "domains":
                    return self.reply(200, {"domainName": name, "isPrimary": d.get("isPrimary", False), "verified": d["verified"]})
                return self.reply(200, {"domainAliasName": name, "parentDomainName": d["parent"], "verified": d["verified"]})
        return self.reply(404, {"error": {"code": 404, "message": "no such stub route"}})


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(PORT_FILE + ".tmp", "w") as f:
    f.write(str(srv.server_address[1]))
os.replace(PORT_FILE + ".tmp", PORT_FILE)
srv.serve_forever()
