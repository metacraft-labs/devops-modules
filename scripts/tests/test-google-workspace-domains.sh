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
# TXT answers from $STUB_DNS/<name>[@<resolver>], MX from <name>.MX, NS from <name>.NS.
name="" resolver="" type=TXT
for a in "$@"; do
  case "$a" in
    @*) resolver="${a#@}" ;;
    +*) ;;
    TXT | NS | MX) type="$a" ;;
    *) name="$a" ;;
  esac
done
echo "dig $*" >>"$STUB_DIG_LOG"
case "$type" in
  NS | MX) [ -f "$STUB_DNS/$name.$type" ] && cat "$STUB_DNS/$name.$type"; exit 0 ;;
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
for d in $(jq -r '.domains | keys[]' "$f"); do
  {
    jq -r --arg d "$d" '(.domains[$d].google_verification // [])[] | "\"" + . + "\""' "$f"
    s="$(jq -r -L "$GOOGLE_WORKSPACE_TOOLS_LIB" --arg d "$d" 'include "mail-auth"; mail_auth_spf($d) // empty' "$f")"
    [ -z "$s" ] || printf '"%s"\n' "$s"
  } >"$STUB_DNS/$d"
  jq -r -L "$GOOGLE_WORKSPACE_TOOLS_LIB" --arg d "$d" 'include "mail-auth"; mail_auth_mx($d) | . + "."' "$f" >"$STUB_DNS/$d.MX"
  s="$(jq -r -L "$GOOGLE_WORKSPACE_TOOLS_LIB" --arg d "$d" 'include "mail-auth"; mail_auth_dmarc($d) // empty' "$f")"
  if [ -n "$s" ]; then printf '"%s"\n' "$s" >"$STUB_DNS/_dmarc.$d"; else rm -f "$STUB_DNS/_dmarc.$d"; fi
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
export GOOGLE_WORKSPACE_ADMIN_API="http://127.0.0.1:$port" GOOGLE_SITE_VERIFICATION_API="http://127.0.0.1:$port"
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
expect "... the hook ran for PHASE=records with the MX, SPF, DMARC and report-authorisation addresses" \
  bash -c 'for a in "example.org|MX|1" "example.org|TXT|spf" "_dmarc.example.org|TXT" "example.org._report._dmarc.example.com|TXT"; do grep -qF "cloudflare_dns_record.mail_auth[\"$a\"]" "$1" || exit 1; done; grep -qx "PHASE=records DOMAIN=example.org" "$1"' _ "$work/hook.log"
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
expect "... in the order alias -> token -> verification PR -> merge -> verify -> records PR" \
  bash -c 'a="$1"; for n in "$@"; do [ -n "$n" ] || exit 1; done; shift; for n in "$@"; do [ "$n" -gt "$a" ] || exit 1; a="$n"; done' _ \
  "$(line_of '^POST /admin/directory/v1/customer/my_customer/domainaliases')" \
  "$(line_of '^POST /siteVerification/v1/token')" \
  "$(line_of '^gh pr create.*example.biz-verification')" \
  "$(line_of '^gh pr merge 1 ')" \
  "$(line_of '^POST /siteVerification/v1/webResource')" \
  "$(line_of '^gh pr create.*example.biz-records')"
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
expect "... which is no change at all" cmp -s "$data" "$work/data.before-primary"

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

echo
if [ "$fails" -ne 0 ]; then
  echo "test-google-workspace-domains: $fails FAILED"
  exit 1
fi
echo "test-google-workspace-domains: all passed"
