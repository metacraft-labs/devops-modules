#!/usr/bin/env python3
"""The Google API calls of google-workspace-domains, as one small CLI.

    google-workspace-domains-api --key FILE --subject ADMIN OP ARGS…

  state  DOMAIN [--write]   {"kind": "primary"|"secondary"|"alias"|"absent",
                             "verified": bool, "parent": str|null}
  alias  DOMAIN PARENT      add DOMAIN as a domain alias of PARENT (unless the
                            tenant has it already); prints the state
  secondary DOMAIN          add DOMAIN as a secondary domain (same rules)
  token  DOMAIN             the DNS TXT value proving ownership (DNS_TXT)
  verify DOMAIN             ask Google to check that TXT record
  scopes SCOPE…             mint one token per scope; prints {"client_id",
                            "project_id", "scopes": {SCOPE: "ok"|"denied"|…}}
  user   USER               {"primaryEmail", "aliases", "nonEditableAliases"}
  user-alias USER ADDRESS   ensure ADDRESS is a user alias of USER
                            ({"address", "result": "created"|"exists"})
  sendas-list USER          USER's Gmail send-as addresses
                            ([{"sendAsEmail", "verificationStatus", …}])
  sendas-create USER ADDRESS
                            ensure a send-as entry (treatAsAlias) for ADDRESS
                            ({"sendAsEmail", "verificationStatus", "result"})
  group  GROUP [--allow-external]
                            the group's posting settings; with
                            --allow-external, first set what a report
                            mailbox needs (REPORT_GROUP_SETTINGS): anyone may
                            post, and neither suspected spam nor any other
                            message is held for a moderator
  send-test USER FROM TO    send a short test message as USER, From: FROM
                            (one of USER's send-as addresses), To: TO
  smtp-test USER FROM TO    send a test message through the Workspace SMTP
                            relay (smtp-relay.gmail.com:587, STARTTLS), logging
                            in as USER with the password in $SMTP_RELAY_PASSWORD
                            (an app password); prints {"result": "accepted"} or
                            fails with the diagnosis. Needs no delegation.

Every call mints a token through domain-wide delegation for exactly the scope
it needs, so a missing delegation scope is reported by name. The Directory and
Site Verification calls act as ADMIN (a super admin); the Gmail calls act as
USER themselves, which is what Gmail requires. Reads (state, user, sendas-list)
use the read-only scope when the delegation has it and fall back to the write
scope, so `status` works on a delegation that has only the read-only ones.

The key is only ever read by google-auth; nothing here prints it (the client
id and project id it prints are public identifiers, not secrets). Endpoints
can be redirected for tests with GOOGLE_WORKSPACE_ADMIN_API,
GOOGLE_SITE_VERIFICATION_API, GOOGLE_GMAIL_API and GOOGLE_GROUPS_SETTINGS_API
(the token endpoint is the key file's token_uri); GOOGLE_SMTP_RELAY=host:port
redirects smtp-test, and GOOGLE_SMTP_RELAY_STARTTLS=0 lets it talk to a
plain-text test server (never use it against a real relay).
Exit status: 0 ok, 1 failure (the message names the cause and the remedy).
"""

import argparse
import base64
import json
import os
import sys
import urllib.parse
from email.message import EmailMessage

ADMIN_API = os.environ.get("GOOGLE_WORKSPACE_ADMIN_API", "https://admin.googleapis.com").rstrip("/")
SITE_API = os.environ.get("GOOGLE_SITE_VERIFICATION_API", "https://www.googleapis.com").rstrip("/")
GMAIL_API = os.environ.get("GOOGLE_GMAIL_API", "https://gmail.googleapis.com").rstrip("/")
GROUPS_API = os.environ.get("GOOGLE_GROUPS_SETTINGS_API", "https://www.googleapis.com").rstrip("/")

AUTH = "https://www.googleapis.com/auth/"
SCOPE_DOMAIN = AUTH + "admin.directory.domain"
SCOPE_DOMAIN_RO = AUTH + "admin.directory.domain.readonly"
SCOPE_USER = AUTH + "admin.directory.user"
SCOPE_USER_RO = AUTH + "admin.directory.user.readonly"
SCOPE_SITE = AUTH + "siteverification"
SCOPE_SENDAS_READ = AUTH + "gmail.settings.basic"
SCOPE_SENDAS = AUTH + "gmail.settings.sharing"
SCOPE_SEND = AUTH + "gmail.send"
SCOPE_GROUPS = AUTH + "apps.groups.settings"


def api_of(scope):
    if "/admin.directory." in scope:
        return "admin.googleapis.com"
    if scope.endswith("/siteverification"):
        return "siteverification.googleapis.com"
    if "/gmail." in scope:
        return "gmail.googleapis.com"
    if scope.endswith("/apps.groups.settings"):
        return "groupssettings.googleapis.com"
    return "<api>"


PROG = "google-workspace-domains"

# What a group receiving DMARC/TLS-RPT reports from outside needs: external
# senders may post, and nothing is held in the moderation queue — reports are
# machine-sent and often zipped, which spam filtering tends to flag, and a held
# report is a lost one (nobody moderates this group).
REPORT_GROUP_SETTINGS = {
    "whoCanPostMessage": "ANYONE_CAN_POST",
    "spamModerationLevel": "ALLOW",
    "messageModerationLevel": "MODERATE_NONE",
}
DIR = "/admin/directory/v1/customer/my_customer/"


class Failure(Exception):
    pass


class Denied(Failure):
    """The delegation does not include the scope (unauthorized_client)."""


def key_info(key):
    try:
        with open(key) as f:
            k = json.load(f)
    except (OSError, ValueError) as e:
        raise Failure(f"cannot load the service-account key {key}: {type(e).__name__}") from None
    return {"client_id": k.get("client_id"), "project_id": k.get("project_id")}


def denied_message(scope):
    return (
        f"token refused (unauthorized_client) for scope {scope.rsplit('/', 1)[-1]}: the service account's "
        f"domain-wide delegation does not include {scope} (or is not approved yet, or the client id is "
        f"wrong). Add {scope} to its entry at https://admin.google.com/ac/owl/domainwidedelegation"
    )


def session(key, subject, scope):
    """An authorised session for SCOPE as SUBJECT; the token is minted now, so
    a refused scope raises Denied here rather than at the first request."""
    from google.auth.exceptions import RefreshError
    from google.auth.transport.requests import AuthorizedSession, Request
    from google.oauth2 import service_account

    try:
        creds = service_account.Credentials.from_service_account_file(key, scopes=[scope])
    except (OSError, ValueError) as e:
        # The exception text names the file and the field, never the key.
        raise Failure(f"cannot load the service-account key {key}: {type(e).__name__}") from None
    creds = creds.with_subject(subject)
    try:
        creds.refresh(Request())
    except RefreshError as e:
        text = str(e.args[0] if e.args else e)
        if "unauthorized_client" in text:
            raise Denied(denied_message(scope)) from None
        if "invalid_grant" in text:
            raise Failure(
                f"token refused (invalid_grant) for {subject}: not a user of the tenant, or the key is "
                f"not this service account's ({text[:120]})"
            ) from None
        raise Failure(f"token refused for scope {scope.rsplit('/', 1)[-1]}: {text[:200]}") from None
    return AuthorizedSession(creds), scope


def session_any(key, subject, scopes):
    """The first of SCOPES the delegation grants. When none is granted, the
    error names every one of them, the first as the one to add."""
    for s in scopes:
        try:
            return session(key, subject, s)
        except Denied:
            continue
    first, rest = scopes[0], scopes[1:]
    raise Denied(
        denied_message(first)
        + (f" (it does not include {' or '.join(rest)} either, which would also do)" if rest else "")
    )


def call(sess_scope, method, url, **kw):
    sess, scope = sess_scope
    r = sess.request(method, url, timeout=60, **kw)
    if r.status_code in (401, 403):
        body = r.text
        if "accessNotConfigured" in body or "SERVICE_DISABLED" in body or "has not been used" in body:
            raise Failure(
                f"HTTP {r.status_code}: the {api_of(scope)} API is not enabled in the service account's "
                f"project. Enable it: gcloud services enable {api_of(scope)} --project <project>"
            )
        raise Failure(
            f"HTTP {r.status_code} from {urllib.parse.urlsplit(url).path}: the impersonated user lacks "
            f"the privilege for this call, or the delegation lacks {scope} ({body[:200]})"
        )
    return r


def json_or_fail(r, what):
    if r.status_code // 100 != 2:
        raise Failure(f"{what}: HTTP {r.status_code}: {r.text[:300]}")
    return r.json() if r.text else {}


def q(s):
    return urllib.parse.quote(s, safe="")


# ── domains ──────────────────────────────────────────────────────────────────


def state(args, write=None):
    write = getattr(args, "write", False) if write is None else write
    if write:
        s = session(args.key, args.subject, SCOPE_DOMAIN)
    else:
        s = session_any(args.key, args.subject, [SCOPE_DOMAIN_RO, SCOPE_DOMAIN])
    r = call(s, "GET", f"{ADMIN_API}{DIR}domains/{q(args.domain)}")
    if r.status_code == 200:
        d = r.json()
        return {
            "kind": "primary" if d.get("isPrimary") else "secondary",
            "verified": bool(d.get("verified")),
            "parent": None,
        }
    if r.status_code not in (400, 404):
        json_or_fail(r, f"domains.get {args.domain}")
    r = call(s, "GET", f"{ADMIN_API}{DIR}domainaliases/{q(args.domain)}")
    if r.status_code == 200:
        d = r.json()
        return {"kind": "alias", "verified": bool(d.get("verified")), "parent": d.get("parentDomainName")}
    if r.status_code not in (400, 404):
        json_or_fail(r, f"domainAliases.get {args.domain}")
    return {"kind": "absent", "verified": False, "parent": None}


def add(args, kind):
    st = state(args, write=True)
    if st["kind"] != "absent":
        if kind == "alias" and st["kind"] == "alias" and st["parent"] != args.parent:
            raise Failure(f"{args.domain} is already an alias of {st['parent']}, not of {args.parent}")
        if kind == "alias" and st["kind"] == "secondary":
            raise Failure(
                f"{args.domain} is already a SECONDARY domain of the tenant, and the data says alias. "
                "Google cannot turn one into the other: delete the domain in the Admin console "
                "(Account > Domains > Manage domains; it must have no users or groups) and re-run, "
                "or declare it secondary"
            )
        if kind == "secondary" and st["kind"] == "alias":
            raise Failure(
                f"{args.domain} is already a domain ALIAS of {st['parent']}, and the data says secondary. "
                "Google cannot turn one into the other: remove the alias in the Admin console "
                "(Account > Domains > Manage domains) and re-run, or declare it an alias"
            )
        return st
    s = session(args.key, args.subject, SCOPE_DOMAIN)
    if kind == "alias":
        r = call(
            s,
            "POST",
            f"{ADMIN_API}{DIR}domainaliases",
            json={"parentDomainName": args.parent, "domainAliasName": args.domain},
        )
        what = "domainAliases.insert"
    else:
        r = call(s, "POST", f"{ADMIN_API}{DIR}domains", json={"domainName": args.domain})
        what = "domains.insert"
    if r.status_code != 409:  # 409: added concurrently; read it back below
        json_or_fail(r, f"{what} {args.domain}")
    return state(args, write=True)


def site(domain):
    return {"type": "INET_DOMAIN", "identifier": domain}


def token(args):
    s = session(args.key, args.subject, SCOPE_SITE)
    r = call(
        s,
        "POST",
        f"{SITE_API}/siteVerification/v1/token",
        json={"site": site(args.domain), "verificationMethod": "DNS_TXT"},
    )
    t = json_or_fail(r, f"webResource.getToken {args.domain}").get("token", "")
    if not t.startswith("google-site-verification="):
        raise Failure(f"webResource.getToken returned an unexpected token form: {t[:60]!r}")
    return t


def verify(args):
    s = session(args.key, args.subject, SCOPE_SITE)
    r = call(
        s,
        "POST",
        f"{SITE_API}/siteVerification/v1/webResource",
        params={"verificationMethod": "DNS_TXT"},
        json={"site": site(args.domain)},
    )
    if r.status_code == 400:
        raise Failure(
            f"Google could not find the verification TXT record for {args.domain} yet "
            f"(HTTP 400: {r.text[:200]}). Re-run once public DNS serves it."
        )
    res = json_or_fail(r, f"webResource.insert {args.domain}")
    return {"id": res.get("id"), "owners": len(res.get("owners", []))}


# ── delegation ───────────────────────────────────────────────────────────────


def scopes(args):
    info = key_info(args.key)
    out = {}
    for s in args.scope:
        full = s if s.startswith("https://") else AUTH + s
        try:
            session(args.key, args.subject, full)
            out[full] = "ok"
        except Denied:
            out[full] = "denied"
        except Failure as e:
            out[full] = f"error: {e}"
    return {"client_id": info["client_id"], "project_id": info["project_id"], "scopes": out}


# ── users ────────────────────────────────────────────────────────────────────


def user_get(args):
    s = session_any(args.key, args.subject, [SCOPE_USER_RO, SCOPE_USER])
    r = call(s, "GET", f"{ADMIN_API}/admin/directory/v1/users/{q(args.user)}")
    if r.status_code == 404:
        raise Failure(f"{args.user} is not a user of the tenant")
    u = json_or_fail(r, f"users.get {args.user}")
    return {
        "primaryEmail": u.get("primaryEmail"),
        "aliases": sorted(u.get("aliases", [])),
        "nonEditableAliases": sorted(u.get("nonEditableAliases", [])),
    }


def user_alias(args):
    addr = args.address.lower()
    u = user_get(args)
    if addr == (u["primaryEmail"] or "").lower() or addr in [a.lower() for a in u["aliases"]]:
        return {"address": addr, "result": "exists"}
    s = session(args.key, args.subject, SCOPE_USER)
    r = call(s, "POST", f"{ADMIN_API}/admin/directory/v1/users/{q(args.user)}/aliases", json={"alias": addr})
    if r.status_code == 409:
        # Taken: by this user concurrently, or by someone else.
        if addr in [a.lower() for a in user_get(args)["aliases"]]:
            return {"address": addr, "result": "exists"}
        raise Failure(
            f"{addr} already belongs to another user, group or alias of the tenant; it cannot be "
            f"added to {args.user}. Find it in the Admin console (search the address) and free it first"
        )
    if r.status_code == 400 and "domain" in r.text.lower():
        raise Failure(
            f"users.aliases.insert {addr}: HTTP 400 ({r.text[:200]}). The domain must be a verified "
            "SECONDARY domain of the tenant (an alias domain's addresses exist automatically)"
        )
    json_or_fail(r, f"users.aliases.insert {addr}")
    return {"address": addr, "result": "created"}


# ── Gmail send-as (acting as the user) ───────────────────────────────────────


def sendas_list(args):
    s = session_any(args.key, args.user, [SCOPE_SENDAS_READ, SCOPE_SENDAS])
    r = call(s, "GET", f"{GMAIL_API}/gmail/v1/users/{q(args.user)}/settings/sendAs")
    out = json_or_fail(r, f"sendAs.list {args.user}").get("sendAs", [])
    return [
        {
            "sendAsEmail": a.get("sendAsEmail", "").lower(),
            "verificationStatus": a.get("verificationStatus", "accepted" if a.get("isPrimary") else ""),
            "isPrimary": bool(a.get("isPrimary")),
            "treatAsAlias": bool(a.get("treatAsAlias")),
        }
        for a in out
    ]


def sendas_create(args):
    addr = args.address.lower()
    for a in sendas_list(args):
        if a["sendAsEmail"] == addr:
            return {"sendAsEmail": addr, "verificationStatus": a["verificationStatus"], "result": "exists"}
    s = session(args.key, args.user, SCOPE_SENDAS)
    r = call(
        s,
        "POST",
        f"{GMAIL_API}/gmail/v1/users/{q(args.user)}/settings/sendAs",
        json={"sendAsEmail": addr, "treatAsAlias": True},
    )
    if r.status_code == 409:
        for a in sendas_list(args):
            if a["sendAsEmail"] == addr:
                return {"sendAsEmail": addr, "verificationStatus": a["verificationStatus"], "result": "exists"}
    res = json_or_fail(r, f"sendAs.create {addr} for {args.user}")
    return {"sendAsEmail": addr, "verificationStatus": res.get("verificationStatus", ""), "result": "created"}


def send_test(args):
    s = session(args.key, args.user, SCOPE_SEND)
    m = EmailMessage()
    m["From"] = args.sender
    m["To"] = args.to
    m["Subject"] = f"{PROG}: test message from {args.sender}"
    m.set_content(
        f"Sent by {PROG} through the Gmail API as {args.user}, From: {args.sender}.\n"
        "Check the headers: DKIM-Signature d=<the From domain>, and dmarc=pass.\n"
    )
    raw = base64.urlsafe_b64encode(m.as_bytes()).decode()
    r = call(s, "POST", f"{GMAIL_API}/gmail/v1/users/{q(args.user)}/messages/send", json={"raw": raw})
    res = json_or_fail(r, f"messages.send as {args.user}")
    return {"id": res.get("id"), "from": args.sender, "to": args.to}


def smtp_test(args):
    import smtplib
    import socket

    pw = os.environ.get("SMTP_RELAY_PASSWORD", "")
    if not pw:
        raise Failure("SMTP_RELAY_PASSWORD is empty: the relay login needs USER's app password")
    host, _, port = os.environ.get("GOOGLE_SMTP_RELAY", "smtp-relay.gmail.com:587").rpartition(":")
    m = EmailMessage()
    m["From"] = args.sender
    m["To"] = args.to
    m["Subject"] = f"{PROG}: SMTP relay test from {args.sender}"
    m.set_content(f"Sent by {PROG} through the Workspace SMTP relay ({host}), logged in as {args.user}.\n")
    try:
        with smtplib.SMTP(host, int(port), timeout=30) as c:
            c.ehlo()
            if os.environ.get("GOOGLE_SMTP_RELAY_STARTTLS", "1") != "0":
                c.starttls()
                c.ehlo()
            c.login(args.user, pw)
            c.send_message(m)
    except smtplib.SMTPAuthenticationError as e:
        raise Failure(
            f"the relay refused the login of {args.user} ({e.smtp_code}): use an APP PASSWORD "
            "(https://myaccount.google.com/apppasswords, needs 2-Step Verification), not the account password"
        ) from None
    except (smtplib.SMTPSenderRefused, smtplib.SMTPRecipientsRefused, smtplib.SMTPDataError) as e:
        text = str(e)[:240]
        raise Failure(
            f"the relay refused the message ({text}). The SMTP relay rule is missing or not active yet "
            "(changes take up to an hour, occasionally 24), or it only allows senders in the tenant's "
            f"domains and {args.sender} is not one"
        ) from None
    except (OSError, smtplib.SMTPException) as e:
        raise Failure(f"could not talk to {host}:{port}: {type(e).__name__}: {str(e)[:200]}") from None
    return {"result": "accepted", "relay": host, "from": args.sender, "to": args.to}


# ── Groups Settings ──────────────────────────────────────────────────────────


def group(args):
    s = session(args.key, args.subject, SCOPE_GROUPS)
    url = f"{GROUPS_API}/groups/v1/groups/{q(args.group)}"
    if args.allow_external:
        r = call(s, "PATCH", url, params={"alt": "json"}, json=REPORT_GROUP_SETTINGS)
        if r.status_code == 404:
            raise Failure(f"no group {args.group} (create it in the Admin console first)")
        if r.status_code == 400:
            raise Failure(
                f"Groups Settings refused whoCanPostMessage=ANYONE_CAN_POST for {args.group} "
                f"(HTTP 400: {r.text[:200]}). The organisation's Groups for Business sharing setting "
                "probably does not let group owners allow incoming email from outside the organisation"
            )
        json_or_fail(r, f"groups.patch {args.group}")
    r = call(s, "GET", url, params={"alt": "json"})
    if r.status_code == 404:
        raise Failure(f"no group {args.group} (create it in the Admin console first)")
    g = json_or_fail(r, f"groups.get {args.group}")
    keep = ("email", "whoCanPostMessage", "allowExternalMembers", "messageModerationLevel", "spamModerationLevel")
    return {k: g.get(k) for k in keep}


def main():
    ap = argparse.ArgumentParser(prog=f"{PROG}-api", description=__doc__.split("\n\n")[0])
    ap.add_argument("--key", required=True)
    ap.add_argument("--subject", required=True)
    sub = ap.add_subparsers(dest="op", required=True)
    p = sub.add_parser("state")
    p.add_argument("domain")
    p.add_argument("--write", action="store_true")
    for op in ("token", "verify", "secondary"):
        sub.add_parser(op).add_argument("domain")
    p = sub.add_parser("alias")
    p.add_argument("domain")
    p.add_argument("parent")
    sub.add_parser("scopes").add_argument("scope", nargs="+")
    for op in ("user", "sendas-list"):
        sub.add_parser(op).add_argument("user")
    for op in ("user-alias", "sendas-create"):
        p = sub.add_parser(op)
        p.add_argument("user")
        p.add_argument("address")
    p = sub.add_parser("group")
    p.add_argument("group")
    p.add_argument("--allow-external", action="store_true")
    for op in ("send-test", "smtp-test"):
        p = sub.add_parser(op)
        p.add_argument("user")
        p.add_argument("sender")
        p.add_argument("to")
    args = ap.parse_args()
    if not os.access(args.key, os.R_OK):
        print(f"{PROG}: cannot read the service-account key {args.key}", file=sys.stderr)
        return 1
    ops = {
        "state": state,
        "alias": lambda a: add(a, "alias"),
        "secondary": lambda a: add(a, "secondary"),
        "token": token,
        "verify": verify,
        "scopes": scopes,
        "user": user_get,
        "user-alias": user_alias,
        "sendas-list": sendas_list,
        "sendas-create": sendas_create,
        "group": group,
        "send-test": send_test,
        "smtp-test": smtp_test,
    }
    try:
        out = ops[args.op](args)
    except Failure as e:
        msg = str(e)
        if "--project <project>" in msg:
            try:
                pid = key_info(args.key).get("project_id")
            except Failure:
                pid = None
            if pid:
                msg = msg.replace("<project>", pid)
        print(f"{PROG}: {msg}", file=sys.stderr)
        return 1
    print(out if isinstance(out, str) else json.dumps(out, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
