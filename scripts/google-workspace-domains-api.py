#!/usr/bin/env python3
"""The Google API calls of google-workspace-domains, as one small CLI.

    google-workspace-domains-api --key FILE --subject USER state  DOMAIN
    google-workspace-domains-api --key FILE --subject USER alias  DOMAIN PARENT
    google-workspace-domains-api --key FILE --subject USER token  DOMAIN
    google-workspace-domains-api --key FILE --subject USER verify DOMAIN

Every call mints a token through domain-wide delegation: the service account
in FILE acting as USER (a super admin of the tenant), for exactly the one scope
the call needs, so a missing delegation scope is reported by name.

  state   prints {"kind": "primary"|"secondary"|"alias"|"absent",
                  "verified": bool, "parent": str|null} — what the tenant knows
          about DOMAIN (Directory API domains.get, then domainAliases.get).
  alias   adds DOMAIN as a domain alias of PARENT unless the tenant already
          has it (as a domain or an alias); prints the resulting state.
  token   prints the DNS TXT value that proves ownership of DOMAIN for USER
          (Site Verification API webResource.getToken, method DNS_TXT).
  verify  asks Google to check that TXT record and record USER as a verified
          owner of DOMAIN (webResource.insert, method DNS_TXT).

The key is only ever read by google-auth; nothing here prints it. Endpoints can
be redirected for tests with GOOGLE_WORKSPACE_ADMIN_API and
GOOGLE_SITE_VERIFICATION_API (the token endpoint is the key file's token_uri).
Exit status: 0 ok, 1 failure (the message names the cause and the remedy).
"""

import argparse
import json
import os
import sys
import urllib.parse

ADMIN_API = os.environ.get("GOOGLE_WORKSPACE_ADMIN_API", "https://admin.googleapis.com").rstrip("/")
SITE_API = os.environ.get("GOOGLE_SITE_VERIFICATION_API", "https://www.googleapis.com").rstrip("/")
SCOPE_DOMAIN = "https://www.googleapis.com/auth/admin.directory.domain"
SCOPE_SITE = "https://www.googleapis.com/auth/siteverification"
APIS = {
    SCOPE_DOMAIN: "admin.googleapis.com",
    SCOPE_SITE: "siteverification.googleapis.com",
}
PROG = "google-workspace-domains"


class Failure(Exception):
    pass


def session(key, subject, scope):
    from google.auth.transport.requests import AuthorizedSession
    from google.oauth2 import service_account

    try:
        creds = service_account.Credentials.from_service_account_file(key, scopes=[scope])
    except (OSError, ValueError) as e:
        # The exception text names the file and the field, never the key.
        raise Failure(f"cannot load the service-account key {key}: {type(e).__name__}") from None
    return AuthorizedSession(creds.with_subject(subject)), scope


def call(sess_scope, method, url, **kw):
    from google.auth.exceptions import RefreshError

    sess, scope = sess_scope
    short = scope.rsplit("/", 1)[-1]
    try:
        r = sess.request(method, url, timeout=60, **kw)
    except RefreshError as e:
        text = str(e.args[0] if e.args else e)
        if "unauthorized_client" in text:
            raise Failure(
                f"token refused (unauthorized_client) for scope {short}: the service account's "
                f"domain-wide delegation does not include {scope} (or is not approved yet, or the "
                f"client id is wrong). Add {scope} to its entry at "
                "https://admin.google.com/ac/owl/domainwidedelegation"
            ) from None
        if "invalid_grant" in text:
            raise Failure(
                f"token refused (invalid_grant): --subject is not a user of the tenant, or the key "
                f"is not this service account's ({text[:120]})"
            ) from None
        raise Failure(f"token refused for scope {short}: {text[:200]}") from None
    if r.status_code in (401, 403):
        body = r.text
        if "accessNotConfigured" in body or "SERVICE_DISABLED" in body or "has not been used" in body:
            raise Failure(
                f"HTTP {r.status_code}: the {APIS.get(scope, 'required')} API is not enabled in the "
                f"service account's project. Enable it: gcloud services enable "
                f"{APIS.get(scope, '<api>')} --project <project>"
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


def state(args):
    s = session(args.key, args.subject, SCOPE_DOMAIN)
    q = urllib.parse.quote(args.domain, safe="")
    r = call(s, "GET", f"{ADMIN_API}/admin/directory/v1/customer/my_customer/domains/{q}")
    if r.status_code == 200:
        d = r.json()
        return {
            "kind": "primary" if d.get("isPrimary") else "secondary",
            "verified": bool(d.get("verified")),
            "parent": None,
        }
    if r.status_code not in (400, 404):
        json_or_fail(r, f"domains.get {args.domain}")
    r = call(s, "GET", f"{ADMIN_API}/admin/directory/v1/customer/my_customer/domainaliases/{q}")
    if r.status_code == 200:
        d = r.json()
        return {"kind": "alias", "verified": bool(d.get("verified")), "parent": d.get("parentDomainName")}
    if r.status_code not in (400, 404):
        json_or_fail(r, f"domainAliases.get {args.domain}")
    return {"kind": "absent", "verified": False, "parent": None}


def alias(args):
    st = state(args)
    if st["kind"] != "absent":
        if st["kind"] == "alias" and st["parent"] != args.parent:
            raise Failure(f"{args.domain} is already an alias of {st['parent']}, not of {args.parent}")
        return st
    s = session(args.key, args.subject, SCOPE_DOMAIN)
    r = call(
        s,
        "POST",
        f"{ADMIN_API}/admin/directory/v1/customer/my_customer/domainaliases",
        json={"parentDomainName": args.parent, "domainAliasName": args.domain},
    )
    if r.status_code != 409:  # 409: added concurrently; read it back below
        json_or_fail(r, f"domainAliases.insert {args.domain}")
    return state(args)


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


def main():
    ap = argparse.ArgumentParser(prog=f"{PROG}-api", description=__doc__.split("\n\n")[0])
    ap.add_argument("--key", required=True)
    ap.add_argument("--subject", required=True)
    sub = ap.add_subparsers(dest="op", required=True)
    for op in ("state", "token", "verify"):
        sub.add_parser(op).add_argument("domain")
    a = sub.add_parser("alias")
    a.add_argument("domain")
    a.add_argument("parent")
    args = ap.parse_args()
    if not os.access(args.key, os.R_OK):
        print(f"{PROG}: cannot read the service-account key {args.key}", file=sys.stderr)
        return 1
    try:
        out = {"state": state, "alias": alias, "token": token, "verify": verify}[args.op](args)
    except Failure as e:
        print(f"{PROG}: {e}", file=sys.stderr)
        return 1
    print(out if isinstance(out, str) else json.dumps(out, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
