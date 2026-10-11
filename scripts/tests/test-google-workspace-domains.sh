#!/usr/bin/env bash
# Offline test of scripts/google-workspace-domains.sh and its API helper: no
# network, no GitHub, no Google, no credentials. The Google endpoints are a
# local HTTP stub (google-api-stub.py) reached through the service-account
# key's token_uri and the API base overrides; `dig` and `gh` are stubs on PATH;
# "origin" is a local bare repository, and merging a PR "applies" it by
# rendering the merged data file into the stub resolver.
#
#   bash scripts/tests/test-google-workspace-domains.sh
#   (also run by `nix build .#checks.<system>.google-workspace-domains-test`)
#
# Needs bash, coreutils, gawk, git, jq, openssl, and python3 with google-auth
# and requests on PATH.
# The `bash -c '…"$1"…' _ args` assertions expand their arguments inside, on purpose.
# shellcheck disable=SC2016
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tool="${GOOGLE_WORKSPACE_DOMAINS_SCRIPT:-$here/../google-workspace-domains.sh}"
setup_tool="${GOOGLE_WORKSPACE_SETUP_SCRIPT:-$here/../google-workspace-setup.sh}"
dkim_tool="${GOOGLE_WORKSPACE_DKIM_SCRIPT:-$here/../google-workspace-dkim.sh}"
stub_py="${GOOGLE_API_STUB:-$here/google-api-stub.py}"
lib="${GOOGLE_WORKSPACE_TOOLS_LIB:-$here/../lib}"
export GOOGLE_WORKSPACE_TOOLS_LIB="$lib"

work="$(mktemp -d)"
stub_pid=""
trap '[ -n "$stub_pid" ] && kill "$stub_pid" 2>/dev/null; rm -rf "$work"' EXIT
export HOME="$work/home" TMPDIR="$work/tmp"
mkdir -p "$HOME" "$TMPDIR" "$work/bin" "$work/dns"
git config --global user.name test
git config --global user.email test@example.invalid
git config --global init.defaultBranch main
git config --global advice.detachedHead false

fails=0
ok() { echo "ok: $1"; }
bad() {
  echo "FAIL: $1"
  # TEST_DEBUG=1 shows what the last run printed.
  [ -z "${TEST_DEBUG:-}" ] || sed 's/^/    | /' "$work/stderr" "$work/stdout" 2>/dev/null || true
  fails=$((fails + 1))
}
expect() {
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}
expect_not() {
  local d="$1"
  shift
  if "$@"; then bad "$d"; else ok "$d"; fi
}
run() { bash "$tool" "$@" >"$work/stdout" 2>"$work/stderr"; }
stderr_has() { grep -qF -- "$1" "$work/stderr"; }
output_has() { cat "$work/stdout" "$work/stderr" | grep -qF -- "$1"; }

# ── stubs: dig, gh, the Google API ───────────────────────────────────────────
printf '#!%s\n' "$(command -v bash)" | tee "$work/bin/dig" "$work/bin/gh" >"$work/apply"
cat >>"$work/bin/dig" <<'EOF'
# TXT answers from $STUB_DNS/<name>[@<resolver>], MX/NS/A/AAAA from <name>.<TYPE>.
name="" resolver="" type=TXT
for a in "$@"; do
  case "$a" in
    @*) resolver="${a#@}" ;;
    +*) ;;
    TXT | NS | MX | A | AAAA) type="$a" ;;
    *) name="$a" ;;
  esac
done
echo "dig $*" >>"$STUB_DIG_LOG"
case "$type" in
  NS | MX | A | AAAA) [ -f "$STUB_DNS/$name.$type" ] && cat "$STUB_DNS/$name.$type"; exit 0 ;;
esac
f="$STUB_DNS/$name@$resolver"
[ -f "$f" ] || f="$STUB_DNS/$name"
[ -f "$f" ] && cat "$f"
exit 0
EOF
# "Apply": render the data file on origin/main into the stub resolver, the way
# the consumer's CI apply would publish it.
cat >>"$work/apply" <<'EOF'
set -euo pipefail
f="$(mktemp)"
git -C "$STUB_ORIGIN" show main:dns/mail-auth.json >"$f"
for d in $(jq -r '.domains | to_entries[] | select((.value.zone_pending // false) | not) | .key' "$f"); do
  {
    jq -r --arg d "$d" '(.domains[$d].google_verification // [])[] | "\"" + . + "\""' "$f"
    s="$(jq -r -L "$GOOGLE_WORKSPACE_TOOLS_LIB" --arg d "$d" 'include "mail-auth"; mail_auth_spf($d) // empty' "$f")"
    [ -z "$s" ] || printf '"%s"\n' "$s"
  } >"$STUB_DNS/$d"
  jq -r -L "$GOOGLE_WORKSPACE_TOOLS_LIB" --arg d "$d" 'include "mail-auth"; mail_auth_mx($d) | . + "."' "$f" >"$STUB_DNS/$d.MX"
  for sel in $(jq -r --arg d "$d" '(.domains[$d].dkim // {}) | keys[]' "$f"); do
    jq -r --arg d "$d" --arg s "$sel" '"\"" + .domains[$d].dkim[$s] + "\""' "$f" >"$STUB_DNS/$sel._domainkey.$d"
  done
  for p in dmarc:_dmarc tls_rpt:_smtp._tls mta_sts:_mta-sts; do
    s="$(jq -r -L "$GOOGLE_WORKSPACE_TOOLS_LIB" --arg d "$d" "include \"mail-auth\"; mail_auth_${p%%:*}(\$d) // empty" "$f")"
    if [ -n "$s" ]; then printf '"%s"\n' "$s" >"$STUB_DNS/${p#*:}.$d"; else rm -f "$STUB_DNS/${p#*:}.$d"; fi
  done
done
rm -f "$f"
EOF
# gh: a stateful stand-in. PRs live in $STUB_GH_STATE/<n> (head branch); a merge
# moves origin/main to the head and runs the apply.
cat >>"$work/bin/gh" <<'EOF'
echo "gh $*" >>"$STUB_GH_LOG"
echo "gh $*" >>"$STUB_SEQ_LOG"
st="$STUB_GH_STATE"; mkdir -p "$st"
arg() { local want="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { echo "$2"; return; }; shift; done; }
case "$1 $2" in
  "pr list")
    h="$(arg --head "$@")"
    for p in "$st"/*; do [ -f "$p" ] && [ "$(cat "$p")" = "$h" ] && { basename "$p"; exit 0; }; done
    echo "" ;;
  "pr create")
    n=$(( $(ls "$st" | wc -l) + 1 )); arg --head "$@" >"$st/$n"
    echo "https://github.invalid/o/r/pull/$n" ;;
  "pr checks")
    if [[ " $* " == *" --watch "* ]]; then exit "${STUB_GH_CHECKS_RC:-0}"; fi
    echo 0 ;;
  "pr view") git -C "$STUB_ORIGIN" rev-parse "refs/heads/$(cat "$st/$3")" ;;
  "pr merge")
    head="$(arg --match-head-commit "$@")"
    [ "$head" = "$(git -C "$STUB_ORIGIN" rev-parse "refs/heads/$(cat "$st/$3")")" ] || exit 1
    git -C "$STUB_ORIGIN" update-ref refs/heads/main "$head"
    mv "$st/$3" "$st/merged-$3"
    "$STUB_APPLY" ;;
  "run list") echo ok ;;
  "repo view") echo main ;;
  *) echo "gh stub: unexpected $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$work/bin/dig" "$work/bin/gh" "$work/apply"
export PATH="$work/bin:$PATH" STUB_DNS="$work/dns" STUB_GH_LOG="$work/gh.log" STUB_DIG_LOG="$work/dig.log"
export STUB_GH_STATE="$work/gh-prs" STUB_APPLY="$work/apply"
# The API stub and the gh stub append to one log, so the order of what Google
# and GitHub saw can be asserted rather than inferred.
export STUB_SEQ_LOG="$work/api.log"
export GOOGLE_WORKSPACE_DKIM_DNS_INTERVAL=1 GOOGLE_WORKSPACE_DKIM_RESOLVERS="192.0.2.1 192.0.2.2"
export GOOGLE_WORKSPACE_DKIM_CHECK_INTERVAL=0 GOOGLE_WORKSPACE_DOMAINS_VERIFY_INTERVAL=1 GOOGLE_WORKSPACE_DOMAINS_VERIFY_TIMEOUT=3
export GOOGLE_WORKSPACE_DOMAINS_DNS_TIMEOUT=5
: >"$STUB_GH_LOG"

state="$work/google-state.json"
api_log="$work/api.log"
cat >"$state" <<'EOF'
{ "domains": { "example.com": { "isPrimary": true, "verified": true } }, "aliases": {} }
EOF
: >"$api_log"
python3 "$stub_py" "$state" "$work/dns" "$api_log" "$work/port" &
stub_pid=$!
for _ in $(seq 1 100); do [ -s "$work/port" ] && break; sleep 0.1; done
[ -s "$work/port" ] || { echo "the Google API stub did not start"; exit 1; }
port="$(cat "$work/port")"
export GOOGLE_WORKSPACE_ADMIN_API="http://127.0.0.1:$port" GOOGLE_SITE_VERIFICATION_API="http://127.0.0.1:$port" \
  GOOGLE_GMAIL_API="http://127.0.0.1:$port" GOOGLE_GROUPS_SETTINGS_API="http://127.0.0.1:$port"
# Nothing may reach a real endpoint: any URL the helper builds without one of
# the overrides above goes to an unroutable proxy and fails.
export HTTPS_PROXY="http://127.0.0.1:9" https_proxy="http://127.0.0.1:9" NO_PROXY="127.0.0.1" no_proxy="127.0.0.1"
set_state() { jq "$1" "$state" >"$state.new" && mv "$state.new" "$state"; }

# A service-account key whose token_uri is the stub. Its private key is a
# fresh RSA key; the marker below must never appear in any output.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/sa.pem" 2>/dev/null
jq -n --rawfile pk "$work/sa.pem" --arg uri "http://127.0.0.1:$port/token" '{
  type: "service_account", project_id: "stub", private_key_id: "0123", private_key: $pk,
  client_email: "workspace-admin@stub.iam.gserviceaccount.com", client_id: "1",
  token_uri: $uri }' >"$work/sa.json"
key_marker="$(sed -n 2p "$work/sa.pem" | cut -c1-40)"
export GOOGLE_WORKSPACE_KEY="$work/sa.json" GOOGLE_WORKSPACE_SUBJECT="admin@example.com"

# ── the consumer repository ──────────────────────────────────────────────────
repo="$work/repo"
origin="$work/origin.git"
git init --quiet --bare "$origin"
git -C "$origin" symbolic-ref HEAD refs/heads/main
export STUB_ORIGIN="$origin"
git init --quiet "$repo"
mkdir -p "$repo/dns"
data="$repo/dns/mail-auth.json"
cat >"$data" <<'EOF'
{
  "version": 1,
  "domains": {
    "example.com": {
      "zone_id": "0123456789abcdef0123456789abcdef",
      "dkim": {}
    },
    "example.org": {
      "zone_id": "fedcba9876543210fedcba9876543210",
      "dkim": {}
    },
    "example.net": {
      "zone_id": "00000000000000000000000000000001",
      "dkim": {}
    }
  }
}
EOF
# example.com: the tenant's primary domain, on the legacy Google MX set with a
# second sender in SPF and a strict DMARC policy.
jq '.version = 2 | .domains["example.com"] += {
  mx: [{priority: 1, host: "aspmx.l.google.com"}, {priority: 5, host: "alt1.aspmx.l.google.com"}, {priority: 10, host: "alt3.aspmx.l.google.com"}],
  spf: {include: ["mailgun.org", "_spf.google.com"], all: "~all"},
  dmarc: {p: "reject", pct: 100, adkim: "s", aspf: "s"} }
  | .domains["example.net"] += {
  mx: [{priority: 10, host: "spool.mail.example.invalid"}, {priority: 50, host: "fb.mail.example.invalid"}],
  spf: {include: ["_mailcust.example.invalid"], all: "?all"} }' "$data" >"$data.new" && mv "$data.new" "$data"
printf 'census\n' >"$repo/census.expected"
git -C "$repo" add -A && git -C "$repo" commit --quiet -m init
git -C "$repo" remote add origin "$origin"
git -C "$repo" push --quiet origin HEAD:main
"$STUB_APPLY"
# The hook records its environment and appends the added addresses to a census.
hook='{ echo "PHASE=$PHASE DOMAIN=$DOMAIN"; echo "ADDED<<$RECORD_ADDRESSES_ADDED>>"; echo "REMOVED<<$RECORD_ADDRESSES_REMOVED>>"; } >>"'"$work"'/hook.log"; [ -z "$RECORD_ADDRESSES_ADDED" ] || printf "%s\n" "$RECORD_ADDRESSES_ADDED" >>census.expected'
: >"$work/hook.log"

# ── 1. arguments and the data file ───────────────────────────────────────────
cp "$data" "$work/data.orig"
expect_not "onboard refuses a missing --parent" run onboard --no-pr --domain example.org --data "$data"
expect_not "onboard refuses an --mx that is not PRIORITY:HOST" \
  run onboard --no-pr --domain example.org --parent example.com --data "$data" --mx smtp.google.com
expect "... naming it" stderr_has 'is not PRIORITY:HOST'
expect_not "onboard refuses a domain the data file does not declare" \
  run onboard --no-pr --domain example.io --parent example.com --data "$data"
expect "... saying how to declare it, by zone id or by lookup" \
  bash -c 'grep -qF "zone_id: \$z" "$1" && grep -qF "zone_lookup: \$k" "$1"' _ "$work/stderr"
expect "... before any Google call" test ! -s "$api_log"
expect "... leaving the file byte-identical" cmp -s "$data" "$work/data.orig"

# ── 2. the API helper's failures name their cause ────────────────────────────
set_state '.deny_scopes = ["admin.directory.domain"]'
expect_not "a delegation without admin.directory.domain stops onboard" \
  run onboard --no-pr --domain example.org --parent example.com --data "$data"
expect "... naming the missing scope in full" stderr_has 'does not include https://www.googleapis.com/auth/admin.directory.domain'
expect "... and the console page where it is added" stderr_has 'admin.google.com/ac/owl/domainwidedelegation'
expect "... without printing the key" bash -c '! grep -qF -- "$1" "$2" "$3"' _ "$key_marker" "$work/stdout" "$work/stderr"
expect "... and before touching the data file" cmp -s "$data" "$work/data.orig"
set_state '.deny_scopes = ["siteverification"]'
expect_not "a delegation without siteverification stops onboard after the alias" \
  run onboard --no-pr --domain example.org --parent example.com --data "$data"
expect "... naming that scope" stderr_has 'does not include https://www.googleapis.com/auth/siteverification'
expect "... having added the alias (unverified)" \
  test "$(jq -c '.aliases["example.org"]' "$state")" = '{"parent":"example.com","verified":false}'
set_state '.deny_scopes = [] | .site_api_disabled = true'
expect_not "a project without the Site Verification API stops onboard" \
  run onboard --no-pr --domain example.org --parent example.com --data "$data"
expect "... saying which API to enable" stderr_has 'gcloud services enable siteverification.googleapis.com'
set_state '.site_api_disabled = false'
expect "the Directory calls use the admin.directory.domain token, the site calls the siteverification one" \
  bash -c 'grep -q "^GET /admin/directory/v1/customer/my_customer/domains/example.org admin.directory.domain$" "$1" && ! grep -q "^POST /siteVerification/v1/token admin.directory.domain$" "$1"' _ "$api_log"
expect "the token is minted as --subject" grep -q "token:admin.directory.domain:admin@example.com" "$api_log"
cmp -s "$data" "$work/data.orig" || bad "the data file changed during the failure cases"

# ── 3. --no-pr: verification first, mail records only once verified ──────────
: >"$api_log"
expect "onboard --no-pr writes the verification token and stops" \
  run onboard --no-pr --domain example.org --parent example.com --data "$data" --post-edit "$hook"
expect "... the token is appended to google_verification" \
  test "$(jq -r '.domains["example.org"].google_verification | join(",")' "$data")" = "google-site-verification=example-org-Tok_123"
expect "... the file is now version 2" test "$(jq .version "$data")" = 2
expect "... with NO mail records yet (MX before verification would bounce mail)" \
  test "$(jq -c '.domains["example.org"] | [has("mx"), has("spf"), has("dmarc")]' "$data")" = '[false,false,false]'
expect "... the hook ran for PHASE=verification with the added address" \
  bash -c 'grep -qx "PHASE=verification DOMAIN=example.org" "$1" && grep -qF "cloudflare_dns_record.mail_auth[\"example.org|TXT|google-site-verification=example-org-Tok_123\"]" "$1"' _ "$work/hook.log"
expect "... and the alias was not asked to verify yet" bash -c '! grep -q "^POST /siteVerification/v1/webResource" "$1"' _ "$api_log"
expect "... saying to commit and re-run" stderr_has "re-run this command to continue"
expect_not "re-running before the record is applied waits for DNS and gives up" \
  run onboard --no-pr --dns-timeout 0 --domain example.org --parent example.com --data "$data" --post-edit "$hook"
expect "... saying what the resolvers answer" stderr_has "@192.0.2.1 answers:"
expect "... still without asking Google to verify" bash -c '! grep -q "^POST /siteVerification/v1/webResource" "$1"' _ "$api_log"
expect "... and without editing the file again" test "$(grep -c PHASE=verification "$work/hook.log")" = 1
# The operator commits and the change is applied.
git -C "$repo" commit --quiet -am "verification" && git -C "$repo" push --quiet origin HEAD:main && "$STUB_APPLY"
expect "once applied, a re-run verifies and writes the mail records" \
  run onboard --no-pr --domain example.org --parent example.com --data "$data" --post-edit "$hook" --dmarc-rua dmarc@example.com
expect "... Google was asked to verify (webResource.insert, DNS_TXT)" grep -q "^POST /siteVerification/v1/webResource siteverification$" "$api_log"
expect "... and the alias is verified" test "$(jq '.aliases["example.org"].verified' "$state")" = true
expect "... MX is smtp.google.com, priority 1" \
  test "$(jq -c '.domains["example.org"].mx' "$data")" = '[{"priority":1,"host":"smtp.google.com"}]'
expect "... SPF is Google's alone" \
  test "$(jq -c '.domains["example.org"].spf' "$data")" = '{"include":["_spf.google.com"],"all":"~all"}'
expect "... DMARC is p=none reporting to --dmarc-rua" \
  test "$(jq -c '.domains["example.org"].dmarc' "$data")" = '{"p":"none","rua":["mailto:dmarc@example.com"]}'
expect "... TLS-RPT reports to the same mailbox (no --tls-rpt-rua)" \
  test "$(jq -c '.domains["example.org"].tls_rpt' "$data")" = '{"rua":["mailto:dmarc@example.com"]}'
expect "... the hook ran for PHASE=records with the MX, SPF, DMARC, TLS-RPT and report-authorisation addresses" \
  bash -c 'for a in "example.org|MX|1" "example.org|TXT|spf" "_dmarc.example.org|TXT" "_smtp._tls.example.org|TXT" "example.org._report._dmarc.example.com|TXT"; do grep -qF "cloudflare_dns_record.mail_auth[\"$a\"]" "$1" || exit 1; done; grep -qx "PHASE=records DOMAIN=example.org" "$1"' _ "$work/hook.log"
git -C "$repo" commit --quiet -am "records" && git -C "$repo" push --quiet origin HEAD:main && "$STUB_APPLY"
expect "once applied, a re-run finds everything served and finishes" \
  run onboard --no-pr --domain example.org --parent example.com --data "$data" --post-edit "$hook" --dmarc-rua dmarc@example.com
expect "... naming the console-only steps (Activate Gmail, DKIM)" \
  bash -c 'grep -qF "Activate Gmail" "$1" && grep -qF "google-workspace-dkim publish --domain example.org" "$1"' _ "$work/stderr"
expect "... without another edit" test "$(grep -c '^PHASE=' "$work/hook.log")" = 2

# ── 4. the PR flow: two PRs, the second only after verification ──────────────
jq '.domains["example.biz"] = {zone_lookup: "example_biz", dkim: {}}' "$data" >"$data.new" && mv "$data.new" "$data"
git -C "$repo" commit --quiet -am "declare example.biz" && git -C "$repo" push --quiet origin HEAD:main
echo dirty >"$repo/unrelated.txt"
: >"$api_log"
: >"$STUB_GH_LOG"
# Google's verification reaches the Directory API only on the second read after
# webResource.insert, so a tool that went on after insert alone would open the
# records PR while the alias is still unverified.
set_state '.verify_lag = 2'
expect "onboard --merge opens, watches and merges two PRs" \
  run onboard --merge --dns-timeout 5 --domain example.biz --parent example.com --data "$data" --post-edit "$hook" --dmarc-rua dmarc@example.com
expect "... first mail/<domain>-verification, then mail/<domain>-records" \
  test "$(grep '^gh pr create' "$STUB_GH_LOG" | sed 's/.*--head \([^ ]*\).*/\1/' | paste -sd' ' -)" = "mail/example.biz-verification mail/example.biz-records"
v1="$(git -C "$origin" rev-parse refs/heads/mail/example.biz-verification)"
v2="$(git -C "$origin" rev-parse refs/heads/mail/example.biz-records)"
expect "... the verification commit carries the token and no mail record" \
  bash -c 'git -C "$1" show "$2:dns/mail-auth.json" | jq -e ".domains[\"example.biz\"] | (.google_verification | length == 1) and (has(\"mx\") | not)" >/dev/null' _ "$origin" "$v1"
expect "... and the census line the hook added, nothing else" \
  test "$(git -C "$origin" diff --name-only "$v1~1" "$v1" | paste -sd' ' -)" = "census.expected dns/mail-auth.json"
expect "... a zone_lookup domain's addresses name its own resource" \
  bash -c 'git -C "$1" show "$2:census.expected" | grep -qF "cloudflare_dns_record.mail_auth_example_biz[\"example.biz|TXT|google-site-verification=example-biz-Tok_123\"]"' _ "$origin" "$v1"
line_of() { grep -n -m1 -- "$1" "$api_log" | cut -d: -f1; }
expect "... in the order alias -> token -> verification PR -> merge -> verify -> Directory reports verified -> records PR" \
  bash -c 'a="$1"; for n in "$@"; do [ -n "$n" ] || exit 1; done; shift; for n in "$@"; do [ "$n" -gt "$a" ] || exit 1; a="$n"; done' _ \
  "$(line_of '^POST /admin/directory/v1/customer/my_customer/domainaliases')" \
  "$(line_of '^POST /siteVerification/v1/token')" \
  "$(line_of '^gh pr create.*example.biz-verification')" \
  "$(line_of '^gh pr merge 1 ')" \
  "$(line_of '^POST /siteVerification/v1/webResource')" \
  "$(line_of '^READ example.biz verified=true$')" \
  "$(line_of '^gh pr create.*example.biz-records')"
expect "... having seen the alias unverified after webResource.insert (the lag was exercised)" \
  bash -c 'sed -n "/^POST \/siteVerification\/v1\/webResource/,\$p" "$1" | grep -qx "READ example.biz verified=false"' _ "$api_log"
set_state '.verify_lag = 0'

expect "... the records commit sets MX/SPF/DMARC" \
  bash -c 'git -C "$1" show "$2:dns/mail-auth.json" | jq -e ".domains[\"example.biz\"].mx == [{priority: 1, host: \"smtp.google.com\"}]" >/dev/null' _ "$origin" "$v2"
expect "... each merge at the head it watched" \
  bash -c 'grep -qx "gh pr merge 1 --merge --match-head-commit $2" "$1" && grep -qx "gh pr merge 2 --merge --match-head-commit $3" "$1"' _ "$STUB_GH_LOG" "$v1" "$v2"
expect "... main carries both" test "$(git -C "$origin" rev-parse main)" = "$v2"
expect "... and the operator's checkout is untouched" \
  test "$(git -C "$repo" status --porcelain | tr '\n' ' ')" = "?? unrelated.txt "
rm -f "$repo/unrelated.txt"
git -C "$repo" pull --quiet --ff-only origin main

# A failed check stops before any merge.
jq '.domains["example.info"] = {zone_id: "00000000000000000000000000000002", dkim: {}}' "$data" >"$data.new" && mv "$data.new" "$data"
git -C "$repo" commit --quiet -am "declare example.info" && git -C "$repo" push --quiet origin HEAD:main
: >"$STUB_GH_LOG"
expect_not "a failed check stops onboard before merging the verification PR" \
  env STUB_GH_CHECKS_RC=1 bash "$tool" onboard --merge --dns-timeout 0 --domain example.info --parent example.com --data "$data" 2>"$work/stderr" >/dev/null
expect "... no merge was attempted" bash -c '! grep -q "pr merge" "$1"' _ "$STUB_GH_LOG"
expect "... and no verification was asked for" bash -c '! grep -q "webResource.*example.info" "$1"' _ "$api_log"

# Google refuses verification when the token is not served.
jq --arg t google-site-verification=example-info-Tok_123 '.domains["example.info"].google_verification = [$t]' "$data" >"$data.new" && mv "$data.new" "$data"
printf 'ns1.example.invalid.\n' >"$work/dns/example.info.NS"
printf '"google-site-verification=example-info-Tok_123"\n' >"$work/dns/example.info@ns1.example.invalid"
printf '"google-site-verification=example-info-Tok_123"\n' >"$work/dns/example.info@192.0.2.1"
printf '"google-site-verification=example-info-Tok_123"\n' >"$work/dns/example.info@192.0.2.2"
expect_not "when Google cannot see the token, onboard stops before the mail records" \
  run onboard --no-pr --dns-timeout 2 --domain example.info --parent example.com --data "$data"
expect "... saying Google could not find it" stderr_has "Google could not find the verification TXT record for example.info"
expect "... and the data file has no MX for it" test "$(jq '.domains["example.info"] | has("mx")' "$data")" = false
rm -f "$work/dns/example.info"* && git -C "$repo" checkout --quiet -- "$data"

# ── 5. a domain the tenant already has, and the SPF merge rules ──────────────
: >"$api_log"
cp "$data" "$work/data.before-primary"
expect "onboarding the primary domain adds no alias and no verification" \
  run onboard --no-pr --domain example.com --parent example.org --data "$data" --dmarc-rua dmarc@example.com
expect "... no domainAliases.insert and no getToken" \
  bash -c '! grep -qE "^POST /admin/directory/v1/customer/my_customer/domainaliases|^POST /siteVerification" "$1"' _ "$api_log"
expect "... the legacy Google MX set is kept" \
  test "$(jq -c '[.domains["example.com"].mx[].host]' "$data")" = '["aspmx.l.google.com","alt1.aspmx.l.google.com","alt3.aspmx.l.google.com"]'
expect "... the other sender stays in SPF next to Google" \
  test "$(jq -c '.domains["example.com"].spf' "$data")" = '{"include":["mailgun.org","_spf.google.com"],"all":"~all"}'
expect "... and the existing DMARC policy is kept" \
  test "$(jq -c '.domains["example.com"].dmarc' "$data")" = '{"p":"reject","pct":100,"adkim":"s","aspf":"s"}'
expect "... the one change is the TLS-RPT record it lacked, reporting to --dmarc-rua" \
  test "$(jq -S 'del(.domains["example.com"].tls_rpt)' "$data")" = "$(jq -S . "$work/data.before-primary")"
expect "... (that record)" test "$(jq -c '.domains["example.com"].tls_rpt' "$data")" = '{"rua":["mailto:dmarc@example.com"]}'
cp "$work/data.before-primary" "$data"
expect "with --tls-rpt-rua, TLS-RPT reports there instead" \
  run onboard --no-pr --domain example.com --parent example.org --data "$data" --dmarc-rua dmarc@example.com --tls-rpt-rua tls@example.com
expect "... as asked" test "$(jq -c '.domains["example.com"].tls_rpt' "$data")" = '{"rua":["mailto:tls@example.com"]}'
cp "$work/data.before-primary" "$data"

set_state '.domains["example.net"] = {isPrimary: false, verified: true}'
cp "$data" "$work/data.before-net"
expect "a cutover drops the old provider's SPF include with --spf-drop" \
  run onboard --no-pr --domain example.net --parent example.com --data "$data" --spf-drop _mailcust.example.invalid
expect "... replacing a non-Google MX set with smtp.google.com (MX|1 updated in place, MX|2 removed)" \
  bash -c 'test "$(jq -c ".domains[\"example.net\"].mx" "$1")" = "[{\"priority\":1,\"host\":\"smtp.google.com\"}]"' _ "$data"
expect "... SPF keeps its qualifier unless replaced" \
  test "$(jq -c '.domains["example.net"].spf' "$data")" = '{"include":["_spf.google.com"],"all":"?all"}'
cp "$work/data.before-net" "$data"
expect "--spf-replace makes SPF Google's alone, ~all" \
  run onboard --no-pr --domain example.net --parent example.com --data "$data" --spf-replace
expect "... as asked" test "$(jq -c '.domains["example.net"].spf' "$data")" = '{"include":["_spf.google.com"],"all":"~all"}'
cp "$work/data.before-net" "$data"
expect "--mx keeps a domain on the legacy set when asked" \
  run onboard --no-pr --domain example.net --parent example.com --data "$data" --mx 1:aspmx.l.google.com,5:alt1.aspmx.l.google.com
expect "... as asked" test "$(jq -c '[.domains["example.net"].mx[].priority]' "$data")" = '[1,5]'
git -C "$repo" checkout --quiet -- "$data"

# ── 6. status ────────────────────────────────────────────────────────────────
expect "status of an onboarded domain passes" run status --domain example.org --data "$data"
expect "... reporting the verified alias" output_has "alias of example.com, verified: true"
expect "... and MX, SPF and DMARC as OK" \
  bash -c 'grep -q "MX       OK  1 smtp.google.com" "$1" && grep -q "SPF      OK" "$1" && grep -q "DMARC    OK" "$1" && grep -q "VERIFY   OK" "$1"' _ "$work/stdout"
printf '10 mail.example.org.\n' >"$work/dns/example.org.MX"
expect_not "status fails when the served MX differs from the data" run status --domain example.org --data "$data"
expect "... saying what is served" output_has "MX       DIFFERS: declared 1 smtp.google.com, serves 10 mail.example.org"
"$STUB_APPLY"
expect "status --all covers every declared domain" \
  bash -c 'bash "$1" status --all --data "$2" 2>/dev/null | grep -c "^== " | grep -qx 5' _ "$tool" "$data"
# Priorities 1, 5 and 10: a collating sort puts "10 …" before "1 …", jq does
# not. Both sides must be sorted alike whatever the operator's locale.
for loc in C $(locale -a 2>/dev/null | grep -iE '^(en_US|C)\.utf-?8$' || true); do
  expect "status of a multi-MX domain passes under LC_ALL=$loc" \
    env LC_ALL="$loc" bash "$tool" status --domain example.com --data "$data"
done
expect "status runs without credentials (DNS only)" \
  env GOOGLE_WORKSPACE_KEY= bash "$tool" status --domain example.org --data "$data" >/dev/null 2>&1

# ── helpers for the sections below ───────────────────────────────────────────
commit_push() { git -C "$repo" commit --quiet -am "$1" && git -C "$repo" push --quiet origin HEAD:main && "$STUB_APPLY"; }
edit_data() { jq --indent 2 "$1" "$data" >"$data.new" && mv "$data.new" "$data"; }
log_has() { grep -q -- "$1" "$api_log"; }
# Guidance is word-wrapped: match a phrase across line breaks.
flat_has() { cat "$work/stdout" "$work/stderr" | tr -s ' \n' '  ' | grep -qF -- "$1"; }
# Every stdout line fits 78 columns, except a line that is one unbreakable
# value (a URL, a line to paste), which is kept whole on purpose.
narrow() { ! awk 'length > 78 { t = $0; sub(/^ +/, "", t); if (t ~ / /) { print; bad = 1 } } END { exit !bad }' "$1" >/dev/null; }

# guided_run "ACTION|ANSWER"… -- CMD…: runs CMD with stdin from a FIFO; before
# the Nth answer it waits until the Nth "[Enter] verify now" prompt is on
# stdout, then runs ACTION (shell, may be empty) — the operator's console edit,
# simulated on the stub — and types ANSWER. The guided flow's own verification
# then has to see the change.
guided_run() {
  local steps=() fifo="$work/guide.fifo" i=0 st n pid rc=0
  while [ "$1" != -- ]; do
    steps+=("$1")
    shift
  done
  shift
  rm -f "$fifo"
  mkfifo "$fifo"
  timeout 300 "$@" <"$fifo" >"$work/stdout" 2>"$work/stderr" &
  pid=$!
  exec 7>"$fifo"
  for st in "${steps[@]}"; do
    i=$((i + 1))
    for _ in $(seq 1 400); do
      n="$(grep -c 'verify now' "$work/stdout" 2>/dev/null || true)"
      [ "${n:-0}" -ge "$i" ] && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    eval "${st%%|*}"
    printf '%s\n' "${st#*|}" >&7 2>/dev/null || true
  done
  exec 7>&-
  wait "$pid" || rc=$?
  rm -f "$fifo"
  return "$rc"
}

# ── 7. domain kinds: secondary domains, aliases from the data, pending zones ─
edit_data '.domains["example.dev"] = {zone_id: "00000000000000000000000000000003", dkim: {}, google: {kind: "secondary"}}
  | .domains["example.app"] = {zone_id: "00000000000000000000000000000004", dkim: {}, google: {kind: "alias", parent: "example.dev"}}
  | .domains["example.later"] = {zone_pending: true, dkim: {}, google: {kind: "secondary"}}'
commit_push "declare example.dev, example.app, example.later"
: >"$api_log"
: >"$work/hook.log"
expect "a secondary domain is added with domains.insert" \
  run onboard --no-pr --domain example.dev --data "$data" --post-edit "$hook"
expect "... (POST domains, admin.directory.domain token)" log_has "^POST /admin/directory/v1/customer/my_customer/domains admin.directory.domain$"
expect "... and never as an alias" bash -c '! grep -q "^POST .*domainaliases" "$1"' _ "$api_log"
expect "... the tenant has it, unverified, as a secondary domain" \
  test "$(jq -c '.domains["example.dev"]' "$state")" = '{"isPrimary":false,"verified":false}'
expect "... and the data its verification token" \
  test "$(jq -r '.domains["example.dev"].google_verification | join(",")' "$data")" = google-site-verification=example-dev-Tok_123
expect "... editing only the verification records" stderr_has "set the verification records of example.dev"
commit_push "verification example.dev"
expect "once applied, a re-run verifies it (domains.get) and writes the records" \
  run onboard --no-pr --domain example.dev --data "$data" --dmarc-rua dmarc@example.com
expect "... verified on the tenant" test "$(jq '.domains["example.dev"].verified' "$state")" = true
expect "... as read back through domains.get" log_has '^READ example.dev verified=true$'
expect "... MX smtp.google.com and TLS-RPT to the report mailbox" \
  test "$(jq -c '.domains["example.dev"] | [.mx[0].host, .tls_rpt.rua[0], .dmarc.p]' "$data")" = '["smtp.google.com","mailto:dmarc@example.com","none"]'
commit_push "records example.dev"
expect "... and the closing message names the kind" \
  run onboard --no-pr --domain example.dev --data "$data" --dmarc-rua dmarc@example.com
expect "... (a secondary domain; Activate Gmail; user-addresses)" \
  bash -c 'grep -qF "as a secondary domain" "$1" && grep -qF "Activate Gmail" "$1" && grep -qF "user-addresses --user" "$1"' _ "$work/stderr"
expect "an alias declared in the data needs no --parent" run onboard --no-pr --domain example.app --data "$data"
expect "... it is a domain alias of the data's parent" test "$(jq -r '.aliases["example.app"].parent' "$state")" = example.dev
git -C "$repo" checkout --quiet -- "$data"

edit_data '.domains["example.org"].google = {kind: "secondary"}'
cp "$data" "$work/data.kind-mismatch"
: >"$api_log"
expect_not "a domain the tenant has as an alias is refused as a secondary" run onboard --no-pr --domain example.org --data "$data"
expect "... saying Google cannot convert one into the other" stderr_has "Google cannot turn one into the other"
expect "... adding nothing" bash -c '! grep -q "^POST /admin" "$1"' _ "$api_log"
expect "... and leaving the data as it was" cmp -s "$data" "$work/data.kind-mismatch"
git -C "$repo" checkout --quiet -- "$data"
expect_not "--kind contradicting the data is refused" \
  run onboard --no-pr --domain example.dev --kind alias --parent example.com --data "$data"
expect "... naming the contradiction" stderr_has 'contradicts the data'
: >"$api_log"
expect_not "a zone_pending domain is refused by onboard" run onboard --no-pr --domain example.later --data "$data"
expect "... saying its zone is not in Cloudflare yet" stderr_has '"zone_pending": true'
expect "... before any Google call" test ! -s "$api_log"
edit_data '.domains["example.net"].google = {kind: "secondary", spf_replace: true}'
expect "google.spf_replace in the data makes SPF Google's alone" run onboard --no-pr --domain example.net --data "$data"
expect "... as declared" test "$(jq -c '.domains["example.net"].spf' "$data")" = '{"include":["_spf.google.com"],"all":"~all"}'
git -C "$repo" checkout --quiet -- "$data"

# ── 8. status: proxied MX, TLS-RPT, MTA-STS, read-only scope, pending, table ─
edit_data '.domains["example.net"].mx = [{priority: 10, host: "mail.example.net"}]'
commit_push "example.net on a proxied mail host"
printf '10 _dc-mx.0a1b2c3d4e5f.example.net.\n' >"$work/dns/example.net.MX"
expect "an MX Cloudflare serves as its proxied-MX substitute is OK" run status --domain example.net --data "$data"
expect "... and labelled so" output_has "MX       OK  10 mail.example.net (served as Cloudflare's proxied-MX substitute 10 _dc-mx.0a1b2c3d4e5f.example.net"
printf '10 _dc-mx.0a1b2c3d4e5f.example.org.\n' >"$work/dns/example.net.MX"
expect_not "... but a substitute named in another zone is not" run status --domain example.net --data "$data"
printf '20 _dc-mx.0a1b2c3d4e5f.example.net.\n' >"$work/dns/example.net.MX"
expect_not "... nor one at another priority" run status --domain example.net --data "$data"
"$STUB_APPLY"
expect "status reports TLS-RPT" run status --domain example.dev --data "$data"
expect "... as served" output_has 'TLS-RPT  OK  v=TLSRPTv1; rua=mailto:dmarc@example.com'
rm -f "$work/dns/_smtp._tls.example.dev"
expect_not "status fails when the declared TLS-RPT is not served" run status --domain example.dev --data "$data"
expect "... saying what is missing" output_has 'TLS-RPT  DIFFERS: declared v=TLSRPTv1; rua=mailto:dmarc@example.com, serves <nothing>'
"$STUB_APPLY"
edit_data '.domains["example.dev"].mta_sts = {enabled: true, id: "20261011", mode: "testing"}'
commit_push "mta-sts example.dev"
expect "status reports an enabled MTA-STS record" run status --domain example.dev --data "$data"
expect "... as served" output_has 'MTA-STS  OK  v=STSv1; id=20261011'
set_state '.deny_scopes = ["admin.directory.domain"]'
: >"$api_log"
expect "the tenant check needs only admin.directory.domain.readonly" run status --domain example.dev --data "$data"
expect "... reporting kind and verification" output_has "tenant   OK  secondary, verified: true"
expect "... read with the read-only token" log_has "^GET /admin/directory/v1/customer/my_customer/domains/example.dev admin.directory.domain.readonly$"
set_state '.deny_scopes = ["admin.directory.domain", "admin.directory.domain.readonly"]'
expect_not "with neither domain scope the tenant check fails" run status --domain example.dev --data "$data"
expect "... naming the read-only scope as the one to add" output_has 'does not include https://www.googleapis.com/auth/admin.directory.domain.readonly'
set_state '.deny_scopes = []'
expect "status of a zone_pending domain skips it, without failing" run status --domain example.later --data "$data"
expect "... saying why" output_has "skipped: zone_pending"
run status --all --table --data "$data" || true
expect "status --table prints one row per domain under a header" \
  bash -c 'head -n1 "$1" | grep -q "^DOMAIN  *KIND VER  MX  SPF DMARC TLS DKIM" && grep -qE "^example\.dev  +seco yes  ok  ok  ok  +ok  --" "$1"' _ "$work/stdout"
expect "... the pending domain as such" grep -q '^example.later .*zone pending' "$work/stdout"
expect "... within 78 columns" narrow "$work/stdout"

# ── 9. user addresses and send-as ────────────────────────────────────────────
set_state '.users = {"admin@example.com": {aliases: []}, "jane@example.com": {aliases: []}, "other@example.com": {aliases: ["taken@example.dev"]}}
  | .aliases["example.app"].verified = true | .sendas = {}'
edit_data '.google_users = {"jane@example.com": {local_parts: ["jane", "j"]}}
  | .domains["example.net"].google = {kind: "secondary"}
  | .domains["example.org"].google = {kind: "alias", parent: "example.com"}
  | .domains["example.biz"].google = {kind: "alias", parent: "example.com"}
  | .domains["example.com"].google = {kind: "primary"}'
commit_push "kinds and google_users"
: >"$api_log"
expect "user-addresses --all --all-domains puts every address in place" \
  run user-addresses --all --all-domains --data "$data"
expect "... user aliases at the secondary domains, from google_users' local parts" \
  test "$(jq -c '.users["jane@example.com"].aliases | sort' "$state")" = '["j@example.dev","j@example.net","jane@example.dev","jane@example.net"]'
expect "... a send-as for those and for the parent's addresses mirrored at each alias domain, all accepted" \
  test "$(jq -c '[.sendas["jane@example.com"][] | select(.isPrimary | not) | select(.verificationStatus == "accepted" and .treatAsAlias) | .sendAsEmail] | sort' "$state")" = \
  '["j@example.app","j@example.dev","j@example.net","jane@example.app","jane@example.biz","jane@example.dev","jane@example.net","jane@example.org"]'
expect "... the Directory calls act as the admin, the Gmail calls as the user" \
  bash -c 'grep -q "token:admin.directory.user:admin@example.com" "$1" && grep -q "token:gmail.settings.sharing:jane@example.com" "$1" && ! grep -q "token:gmail.settings.sharing:admin@example.com" "$1"' _ "$api_log"
: >"$api_log"
expect "a re-run changes nothing" run user-addresses --all --all-domains --data "$data"
expect "... (no POST at all)" bash -c '! grep -qE "^POST /(admin|gmail)" "$1"' _ "$api_log"
expect "... and says the addresses exist" grep -qE '^ +jane@example\.dev +send-as: accepted \(exists\)$' "$work/stdout"
expect "status --user shows each address and its send-as" run status --domain example.app --user jane@example.com --data "$data"
expect "... mirrored at the alias domain, accepted" \
  output_has "ADDR     OK  j@example.app mirrored, send-as accepted; jane@example.app mirrored, send-as accepted"
set_state '.sendas_pending = ["hostmaster@example.dev"]'
rc=0
run user-addresses --user jane@example.com --domain example.dev --local hostmaster --data "$data" || rc=$?
expect "a send-as Google leaves pending exits 2" test "$rc" = 2
expect "... saying what the user has to click" bash -c 'grep -qE "hostmaster@example\.dev +send-as: pending" "$1" && grep -qF "confirmation link" "$1"' _ "$work/stdout"
set_state '.domains["example.new"] = {isPrimary: false, verified: false}'
edit_data '.domains["example.new"] = {zone_id: "00000000000000000000000000000005", dkim: {}, google: {kind: "secondary"}}'
rc=0
run user-addresses --user jane@example.com --domain example.new --data "$data" || rc=$?
expect "a secondary domain the tenant has not verified is skipped (exit 2)" test "$rc" = 2
expect "... saying so" output_has "skipped: not a verified secondary domain of the tenant yet"
git -C "$repo" checkout --quiet -- "$data"
expect_not "an address another user has is refused" \
  run user-addresses --user jane@example.com --domain example.dev --local taken --data "$data"
expect "... naming the conflict" stderr_has "taken@example.dev already belongs to another user"
expect_not "the primary domain is refused (its addresses are the users' own)" \
  run user-addresses --user jane@example.com --domain example.com --data "$data"

# ── 10. the DMARC report group ───────────────────────────────────────────────
set_state '.groups = {"dmarc@example.com": {whoCanPostMessage: "ALL_IN_DOMAIN_CAN_POST", spamModerationLevel: "MODERATE", messageModerationLevel: "MODERATE_NONE"}}'
: >"$api_log"
expect "dmarc-group lets the group receive mail from outside" run dmarc-group --group dmarc@example.com
expect "... through the Groups Settings API with apps.groups.settings" \
  log_has "^PATCH /groups/v1/groups/dmarc%40example.com apps.groups.settings$"
expect "... whoCanPostMessage is now ANYONE_CAN_POST" \
  test "$(jq -r '.groups["dmarc@example.com"].whoCanPostMessage' "$state")" = ANYONE_CAN_POST
: >"$api_log"
expect "a re-run only reads" run dmarc-group --group dmarc@example.com
expect "... (no PATCH)" bash -c '! grep -q "^PATCH" "$1"' _ "$api_log"
set_state '.deny_scopes = ["apps.groups.settings"] | .groups["dmarc@example.com"].whoCanPostMessage = "ALL_IN_DOMAIN_CAN_POST"'
expect_not "without apps.groups.settings it stops" run dmarc-group --group dmarc@example.com
expect "... naming the scope in full" stderr_has "does not include https://www.googleapis.com/auth/apps.groups.settings"
set_state '.deny_scopes = [] | .groups_api_disabled = true'
expect_not "without the Groups Settings API it stops" run dmarc-group --group dmarc@example.com
expect "... saying which API to enable in which project" stderr_has "gcloud services enable groupssettings.googleapis.com --project stub"
expect "--guide waits for the fix, then verifies it" \
  guided_run "set_state '.groups_api_disabled = false'|" -- bash "$tool" dmarc-group --group dmarc@example.com --guide
expect "... having printed the command and the console page on stdout" \
  bash -c 'grep -qF "gcloud services enable groupssettings.googleapis.com --project stub" "$1" && grep -qF "console.cloud.google.com/apis/library/groupssettings.googleapis.com?project=stub" "$1"' _ "$work/stdout"
expect "... and is done" test "$(jq -r '.groups["dmarc@example.com"].whoCanPostMessage' "$state")" = ANYONE_CAN_POST
set_state '.groups["dmarc@example.com"].whoCanPostMessage = "ALL_IN_DOMAIN_CAN_POST" | .groups_external_forbidden = true'
rc=0
guided_run "|s" -- bash "$tool" dmarc-group --group dmarc@example.com --guide || rc=$?
expect "when the organisation forbids external posting, --guide says where to allow it; s skips (exit 2)" test "$rc" = 2
expect "... (Groups for Business sharing settings)" flat_has "Tick 'Group owners can allow incoming email from outside the organization'"
set_state '.groups_external_forbidden = false'

# ── 11. delegation scopes ────────────────────────────────────────────────────
all_scopes="https://www.googleapis.com/auth/admin.directory.domain,https://www.googleapis.com/auth/admin.directory.domain.readonly,https://www.googleapis.com/auth/siteverification,https://www.googleapis.com/auth/admin.directory.user,https://www.googleapis.com/auth/gmail.settings.basic,https://www.googleapis.com/auth/gmail.settings.sharing,https://www.googleapis.com/auth/gmail.send,https://www.googleapis.com/auth/apps.groups.settings"
set_state '.deny_scopes = ["apps.groups.settings", "gmail.send"]'
rc=0
run scopes || rc=$?
expect "scopes exits 3 while any is missing" test "$rc" = 3
expect "... marking each scope" \
  bash -c 'grep -qx "  MISSING  apps.groups.settings" "$1" && grep -qx "  MISSING  gmail.send" "$1" && grep -qx "  ok       siteverification" "$1"' _ "$work/stdout"
expect "... naming the client id and the console page" \
  bash -c 'grep -qF "client id 1" "$1" && grep -qF "https://admin.google.com/ac/owl/domainwidedelegation" "$1"' _ "$work/stdout"
expect "... printing the COMPLETE replacement line (granted + missing), unwrapped" grep -qxF "      $all_scopes" "$work/stdout"
expect "... warning that the saved list replaces the old one" output_has "REPLACES the old one"
expect "... within 78 columns, except the line to paste" narrow "$work/stdout"
expect "... and never printing the key" bash -c '! grep -qF -- "$1" "$2" "$3"' _ "$key_marker" "$work/stdout" "$work/stderr"
expect "--guide waits for the console edit and checks again" \
  guided_run "set_state '.deny_scopes = []'|" -- bash "$tool" scopes --guide
expect "... until every scope is granted" output_has "all 8 scopes are granted"
run scopes --scopes admin.directory.user,https://www.googleapis.com/auth/admin.directory.group || true
expect "--scopes checks exactly the given list" \
  bash -c 'grep -qx "  ok       admin.directory.group" "$1" && ! grep -q siteverification "$1"' _ "$work/stdout"

# ── 12. the setup wizard, end to end ─────────────────────────────────────────
# A fresh consumer and tenant, driven through `google-workspace-setup run` by a
# scripted operator: the order, the inbound-test gate before mail that goes
# elsewhere today, Activate Gmail, addresses, one DKIM key, the SMTP relay.
rm -f "$work"/dns/*
wsrc="$work/wrepo" worigin="$work/worigin.git"
git init --quiet --bare "$worigin"
git -C "$worigin" symbolic-ref HEAD refs/heads/main
git init --quiet "$wsrc"
mkdir -p "$wsrc/dns"
wdata="$wsrc/dns/mail-auth.json"
cat >"$wdata" <<'EOF'
{
  "version": 2,
  "domains": {
    "example.com": {
      "zone_id": "0123456789abcdef0123456789abcdef", "dkim": {},
      "mx": [{"priority": 1, "host": "aspmx.l.google.com"}, {"priority": 5, "host": "alt1.aspmx.l.google.com"}],
      "spf": {"include": ["_spf.google.com"], "all": "~all"},
      "dmarc": {"p": "reject"}, "tls_rpt": {"rua": ["mailto:dmarc@example.com"]},
      "google": {"kind": "primary"}
    },
    "example.org": {"zone_id": "00000000000000000000000000000011", "dkim": {}, "google": {"kind": "secondary"}},
    "example.net": {"zone_id": "00000000000000000000000000000012", "dkim": {},
      "mx": [{"priority": 10, "host": "mail.example.net"}], "spf": {"include": ["_spf.oldhost.example"], "all": "?all"},
      "google": {"kind": "secondary", "spf_replace": true}},
    "example.info": {"zone_id": "00000000000000000000000000000013", "dkim": {},
      "mx": [{"priority": 10, "host": "mail.example.info"}], "google": {"kind": "alias", "parent": "example.net"}},
    "example.xyz": {"zone_id": "00000000000000000000000000000014", "dkim": {},
      "mx": [{"priority": 10, "host": "mail.example.xyz"}], "google": {"kind": "secondary"}},
    "example.dev": {"zone_pending": true, "dkim": {}, "google": {"kind": "secondary"}}
  },
  "google_users": {"admin@example.com": {"local_parts": ["admin"]}}
}
EOF
git -C "$wsrc" add -A && git -C "$wsrc" commit --quiet -m init
git -C "$wsrc" remote add origin "$worigin"
git -C "$wsrc" push --quiet origin HEAD:main
printf '192.0.2.10\n' >"$work/dns/mail.example.net.A"
printf '192.0.2.11\n' >"$work/dns/mail.example.info.A"
cat >"$state" <<'EOF'
{ "domains": { "example.com": { "isPrimary": true, "verified": true } }, "aliases": {},
  "users": { "admin@example.com": { "aliases": [] } },
  "groups": { "dmarc@example.com": { "whoCanPostMessage": "ALL_IN_DOMAIN_CAN_POST" } } }
EOF
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/dkim.pem" 2>/dev/null
dkim_value="v=DKIM1; k=rsa; p=$(openssl rsa -in "$work/dkim.pem" -pubout -outform DER 2>/dev/null | base64 -w0)"
: >"$api_log"
: >"$STUB_GH_LOG"
# Bounded: a guided flow that loops instead of reading its answers fails here.
wizard() {
  timeout 600 env STUB_ORIGIN="$worigin" STUB_GH_STATE="$work/wgh" \
    GOOGLE_WORKSPACE_DOMAINS_CMD="bash $tool" GOOGLE_WORKSPACE_DKIM_CMD="bash $dkim_tool" \
    bash "$setup_tool" "$@" --data "$wdata" --base main --dmarc-rua dmarc@example.com --test-to ext@example.net
}
STUB_ORIGIN="$worigin" "$STUB_APPLY"
# onboard-all, with the inbound test skipped: the domains with no mail today
# are onboarded, the two whose mail goes elsewhere are NOT touched.
{
  echo             # example.org: Activate Gmail done
  echo             # example.xyz: Activate Gmail done
  echo s           # gate before example.net: skip
  echo s           # gate before example.info: skip
} >"$work/answers"
rc=0
wizard onboard-all <"$work/answers" >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "onboard-all onboards the domains with no mail today" \
  bash -c '[ "$1" = 0 ] && test "$(jq -c "[.domains[\"example.org\",\"example.xyz\"].verified]" "$2")" = "[true,true]"' _ "$rc" "$state"
expect "... asks for an inbound test before a domain whose mail goes elsewhere" flat_has "Before switching a domain that receives mail today"
expect "... and, without one, leaves those domains alone (no domain added, no PR)" \
  bash -c '! grep -qE "example\.(net|info)" "$1" && ! jq -e ".domains[\"example.net\"] // .aliases[\"example.info\"]" "$2" >/dev/null' _ "$STUB_GH_LOG" "$state"
expect "... saying so" output_has "skipping example.net: no inbound test confirmed yet"
expect "... and printing the Activate Gmail steps" \
  bash -c 'grep -qF "https://admin.google.com/ac/domains/manage" "$1" && grep -qF "Activate Gmail" "$1"' _ "$work/stdout"
# The full run. example.org and example.xyz are on Google now.
{
  echo s           # example.com: DKIM later
  echo y           # example.org: generate DKIM now
  echo "$dkim_value"
  echo             # (end of the paste)
  echo             # example.org: Start authentication clicked
  echo y           # example.org: the test message shows DKIM pass
  echo s           # example.xyz: DKIM later
  echo n           # gate: no inbound test yet
  echo y           # gate: now it arrived
  echo yes         # switch example.net
  echo             # example.net: Activate Gmail done
  echo s           # example.net: DKIM later
  echo yes         # switch example.info
  echo             # example.info: Activate Gmail done
  echo s           # example.info: DKIM later
  echo             # SMTP relay saved
  echo s           # no live relay test
} >"$work/answers"
rc=0
wizard run <"$work/answers" >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "the wizard runs every step to the end" test "$rc" = 0
expect "... taking the domains in the safe order: primary, on Google, then mail elsewhere (alias after parent)" \
  test "$(grep -oE '^Domain [0-9]/5: [a-z.]+' "$work/stdout" | cut -d' ' -f3 | paste -sd' ' -)" = "example.com example.org example.xyz example.net example.info"
expect "... listing the zone_pending domain as skipped" grep -qE '^ +example\.dev +secondary; SKIPPED: zone pending' "$work/stdout"
expect "... onboarding each one onto the tenant with its kind" \
  test "$(jq -c '[.domains["example.org","example.xyz","example.net"].verified, .aliases["example.info"].parent, .aliases["example.info"].verified]' "$state")" = '[true,true,true,"example.net",true]'
expect "... publishing their records on the base branch" \
  bash -c 'git -C "$1" show main:dns/mail-auth.json | jq -e ".domains[\"example.net\"] | .mx == [{priority: 1, host: \"smtp.google.com\"}] and .spf.include == [\"_spf.google.com\"] and .tls_rpt != null" >/dev/null' _ "$worigin"
expect "... the DKIM key the operator pasted, for example.org only" \
  bash -c 'git -C "$1" show main:dns/mail-auth.json | jq -e --arg v "$2" "(.domains[\"example.org\"].dkim.google == \$v) and ([.domains[] | .dkim | length] | add) == 1" >/dev/null' _ "$worigin" "$dkim_value"
expect "... sending the DKIM test message as the user from the new domain" log_has "^SENT admin@example.com From=admin@example.org To=ext@example.net$"
expect "... an address and an accepted send-as at every domain, mirrored at the alias" \
  test "$(jq -c '[.sendas["admin@example.com"][] | select(.isPrimary | not) | select(.verificationStatus == "accepted") | .sendAsEmail] | sort' "$state")" = '["admin@example.info","admin@example.net","admin@example.org","admin@example.xyz"]'
expect "... the report group accepting mail from outside" test "$(jq -r '.groups["dmarc@example.com"].whoCanPostMessage' "$state")" = ANYONE_CAN_POST
expect "... asking for the inbound test before switching example.net, and holding off on 'n'" \
  bash -c 'grep -qF "send a message to admin@example.org" <(tr -s " \n" "  " <"$1") && grep -qF "Then do not switch more mail yet" "$1"' _ "$work/stdout"
expect "... printing the DKIM console steps with the exact choices" \
  bash -c 'f="$(tr -s " \n" "  " <"$1")"; for p in "https://admin.google.com/ac/apps/gmail/authenticateemail" "DKIM key bit length: 2048. Prefix selector: google." "START AUTHENTICATION"; do grep -qF -- "$p" <<<"$f" || exit 1; done' _ "$work/stdout"
expect "... and the SMTP relay settings" \
  bash -c 'f="$(tr -s " \n" "  " <"$1")"; for p in "https://admin.google.com/ac/apps/gmail/routing" "Require SMTP Authentication" "Require TLS encryption" "Only addresses in my domains"; do grep -qF -- "$p" <<<"$f" || exit 1; done' _ "$work/stdout"
expect "... ending with the status table" grep -qE '^example\.org +seco yes +ok +ok +ok +ok +ok +ok' "$work/stdout"
expect "... all of it within 78 columns" narrow "$work/stdout"
expect "... without printing the key" bash -c '! grep -qF -- "$1" "$2" "$3"' _ "$key_marker" "$work/stdout" "$work/stderr"
: >"$api_log"
prs="$(grep -c '^gh pr create' "$STUB_GH_LOG")"
printf 's\ns\ns\ns\n\ns\n' >"$work/answers"
rc=0
wizard run <"$work/answers" >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "a second run resumes: nothing left to change" test "$rc" = 0
expect "... no domain, alias, user alias, send-as or group write" \
  bash -c '! grep -qE "^(POST|PATCH) /(admin|groups|gmail)" "$1"' _ "$api_log"
expect "... and no new PR" test "$(grep -c '^gh pr create' "$STUB_GH_LOG")" = "$prs"
wizard_quit_rc=0
printf 'q\n' | wizard dkim-all >"$work/stdout" 2>"$work/stderr" || wizard_quit_rc=$?
expect "q quits a guided step (exit 3), saying how to resume" bash -c '[ "$1" = 3 ] && grep -qF "Re-run to resume" "$2"' _ "$wizard_quit_rc" "$work/stderr"

# ── 13. the SMTP relay test ──────────────────────────────────────────────────
cat >"$work/smtp-stub.py" <<'EOF'
import base64, socketserver, sys
LOG, PORT_FILE, PASSWORD = sys.argv[1:4]
class H(socketserver.StreamRequestHandler):
    def w(self, s): self.wfile.write((s + "\r\n").encode())
    def handle(self):
        self.w("220 stub ESMTP"); authed = False; frm = ""
        while True:
            line = self.rfile.readline().decode().rstrip("\r\n")
            if not line: return
            cmd = line.split(" ")[0].upper()
            if cmd == "EHLO": self.w("250-stub"); self.w("250 AUTH PLAIN")
            elif cmd == "AUTH":
                user, pw = base64.b64decode(line.split(" ")[2]).split(b"\0")[1:]
                if pw.decode() == PASSWORD: authed = True; self.w("235 2.7.0 Accepted")
                else: self.w("535 5.7.8 Username and Password not accepted")
            elif cmd == "MAIL":
                if not authed: self.w("530 5.7.0 Authentication Required"); continue
                frm = line; self.w("250 OK")
            elif cmd == "RCPT": self.w("250 OK")
            elif cmd == "DATA":
                self.w("354 go")
                while self.rfile.readline().decode().rstrip("\r\n") != ".": pass
                open(LOG, "a").write("RELAYED " + frm + "\n"); self.w("250 queued")
            elif cmd == "QUIT": self.w("221 bye"); return
            else: self.w("250 OK")
srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), H)
open(PORT_FILE, "w").write(str(srv.server_address[1]))
srv.serve_forever()
EOF
python3 "$work/smtp-stub.py" "$work/smtp.log" "$work/smtp.port" app-pw-123 &
smtp_pid=$!
trap '[ -n "$stub_pid" ] && kill "$stub_pid" 2>/dev/null; kill "$smtp_pid" 2>/dev/null; rm -rf "$work"' EXIT
for _ in $(seq 1 100); do [ -s "$work/smtp.port" ] && break; sleep 0.1; done
: >"$work/smtp.log"
printf '\nwrong-pw\n\napp-pw-123\n' >"$work/answers"
rc=0
env GOOGLE_SMTP_RELAY="127.0.0.1:$(cat "$work/smtp.port")" GOOGLE_SMTP_RELAY_STARTTLS=0 \
  STUB_ORIGIN="$worigin" STUB_GH_STATE="$work/wgh" GOOGLE_WORKSPACE_DOMAINS_CMD="bash $tool" \
  bash "$setup_tool" smtp-relay --data "$wdata" --base main --test-to ext@example.net \
  <"$work/answers" >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "smtp-relay verifies the console setting by sending through the relay" test "$rc" = 0
expect "... a refused login says to use an app password, and asks again" flat_has "use an APP PASSWORD"
expect "... then the relay takes the message, logged in" grep -qi '^RELAYED MAIL FROM:<admin@example.com>' "$work/smtp.log"
expect "... and the tool says so" flat_has "the relay accepted a message from admin@example.com to ext@example.net"
expect "... never echoing the password" bash -c '! grep -qF app-pw-123 "$1" "$2"' _ "$work/stdout" "$work/stderr"

echo
if [ "$fails" -ne 0 ]; then
  echo "test-google-workspace-domains: $fails FAILED"
  exit 1
fi
echo "test-google-workspace-domains: all passed"
