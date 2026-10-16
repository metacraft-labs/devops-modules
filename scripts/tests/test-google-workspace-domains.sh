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
# (grep without -q reads all of its input: an early exit would SIGPIPE the
# writer and, under pipefail, fail the pipeline although the text is there)
output_has() { cat "$work/stdout" "$work/stderr" | grep -F -- "$1" >/dev/null; }

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
# moves origin/main to the head and runs the apply — unless $STUB_GH_STATE/
# defer-apply exists (the CI apply has not run yet). While $STUB_GH_STATE/hang
# exists, `pr checks --watch` keeps watching (a run interrupted mid-watch).
cat >>"$work/bin/gh" <<'EOF'
echo "gh $*" >>"$STUB_GH_LOG"
echo "gh $*" >>"$STUB_SEQ_LOG"
st="$STUB_GH_STATE"; mkdir -p "$st"
arg() { local want="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$want" ] && { echo "$2"; return; }; shift; done; }
case "$1 $2" in
  "pr list")
    h="$(arg --head "$@")"
    if [ -z "$h" ]; then
      # Every open PR: "<number> <head branch>".
      for p in "$st"/*; do
        [ -f "$p" ] && [[ $(basename "$p") =~ ^[0-9]+$ ]] && echo "$(basename "$p") $(cat "$p")"
      done
      exit 0
    fi
    for p in "$st"/*; do [ -f "$p" ] && [[ $(basename "$p") =~ ^[0-9]+$ ]] && [ "$(cat "$p")" = "$h" ] && { basename "$p"; exit 0; }; done
    echo "" ;;
  "pr create")
    n=$(( $(ls "$st" | grep -cE '(^|-)[0-9]+$') + 1 )); arg --head "$@" >"$st/$n"
    # Labels, one per line; and the required-check list a test planted for
    # "the next PR" becomes this PR's.
    : >"$st/lbl.$n"
    a=("$@"); for ((i = 0; i < ${#a[@]}; i++)); do [ "${a[i]}" = --label ] && echo "${a[i + 1]}" >>"$st/lbl.$n"; done
    [ -f "$st/checks-next.json" ] && mv "$st/checks-next.json" "$st/checks-$n.json"
    echo "https://github.invalid/o/r/pull/$n" ;;
  "pr checks")
    if [[ " $* " == *" --watch "* ]]; then
      while [ -f "$st/hang" ]; do sleep 0.2; done
      exit "${STUB_GH_CHECKS_RC:-0}"
    fi
    if [ "$(arg --json "$@")" = name,bucket,link ]; then
      # The gate's view: $st/checks-<n>.json as `gh pr checks --json` prints
      # it. "late": N hides a check from the next N reads (it registers
      # late); "pending": N shows it pending for N reads, then as its bucket.
      f="$st/checks-$3.json"
      [ -f "$f" ] || [ ! -f "$st/checks-default.json" ] || cp "$st/checks-default.json" "$f"
      [ -f "$f" ] || { echo "no checks reported on the 'x' branch" >&2; exit 1; }
      jq -c '[.[] | select((.late // 0) <= 0) | {name, bucket: (if (.pending // 0) > 0 then "pending" else .bucket end), link}]' "$f"
      jq '[.[] | if (.late // 0) > 0 then .late -= 1 elif (.pending // 0) > 0 then .pending -= 1 else . end]' "$f" >"$f.t" && mv "$f.t" "$f"
      exit 0
    fi
    echo 0 ;;
  "run rerun")
    # Re-running a run's failed jobs: its failed checks pass (unless the test
    # made the run fail for good), and a re-run apply applies.
    echo "$3" >>"$st/reruns"
    if [ ! -f "$st/fails-for-good-$3" ]; then
      for f in "$st"/checks-*.json; do
        [ -f "$f" ] || continue
        jq --arg r "/runs/$3/" '[.[] | if ((.link // "") | contains($r)) and .bucket != "pass" then .bucket = "pass" else . end]' "$f" >"$f.t" && mv "$f.t" "$f"
      done
      if [ -f "$st/apply-runs.json" ] && jq -e --argjson r "$3" 'any(.[]; .databaseId == $r)' "$st/apply-runs.json" >/dev/null; then
        jq --argjson r "$3" '[.[] | if .databaseId == $r then .conclusion = "success" else . end]' "$st/apply-runs.json" >"$st/apply-runs.json.t" && mv "$st/apply-runs.json.t" "$st/apply-runs.json"
        rm -f "$st/defer-apply"
        "$STUB_APPLY"
      fi
    fi ;;
  "pr view")
    if [ "$(arg --json "$@")" = state ]; then
      if [ -f "$st/$3" ]; then echo OPEN; elif [ -f "$st/merged-$3" ]; then echo MERGED; else echo CLOSED; fi
      exit 0
    fi
    git -C "$STUB_ORIGIN" rev-parse "refs/heads/$(cat "$st/$3" "$st/merged-$3" 2>/dev/null | head -n1)" ;;
  "pr merge")
    head="$(arg --match-head-commit "$@")"
    [ "$head" = "$(git -C "$STUB_ORIGIN" rev-parse "refs/heads/$(cat "$st/$3")")" ] || exit 1
    git -C "$STUB_ORIGIN" update-ref refs/heads/main "$head"
    mv "$st/$3" "$st/merged-$3"
    [ -f "$st/defer-apply" ] || "$STUB_APPLY" ;;
  "run list")
    if [ -n "$(arg --workflow "$@")" ]; then
      cat "$st/apply-runs.json" 2>/dev/null || echo '[]'
    else
      echo ok
    fi ;;
  "repo view") echo main ;;
  *) echo "gh stub: unexpected $*" >&2; exit 9 ;;
esac
EOF
# gcloud: `services enable` succeeds (and enables the APIs on the Google stub)
# unless $STUB_GCLOUD_STATE says "reauth" (until `gcloud auth login` ran) or
# "denied"; `services list --enabled` prints $STUB_GCLOUD_STATE.enabled (one
# API per line), under the same rules. Every call is logged.
printf '#!%s\n' "$(command -v bash)" >"$work/bin/gcloud"
cat >>"$work/bin/gcloud" <<'EOF'
echo "gcloud $*" >>"$STUB_SEQ_LOG"
mode="$(cat "$STUB_GCLOUD_STATE" 2>/dev/null || echo ok)"
reauth() {
  if [ "$mode" = reauth ] && [ ! -f "$STUB_GCLOUD_STATE.login" ]; then
    echo "ERROR: (gcloud.services.$1) There was a problem refreshing your current auth tokens: Reauthentication failed. cannot prompt during non-interactive execution." >&2
    echo "Please run:  \$ gcloud auth login" >&2
    exit 1
  fi
}
case "$1 $2" in
  "auth login") touch "$STUB_GCLOUD_STATE.login"; exit 0 ;;
  "config get-value") echo operator@example.com; exit 0 ;;
  "services list")
    reauth list
    cat "$STUB_GCLOUD_STATE.enabled" 2>/dev/null || true ;;
  "services enable")
    reauth enable
    if [ "$mode" = denied ]; then
      echo "ERROR: (gcloud.services.enable) PERMISSION_DENIED: Permission denied to enable service [$3]" >&2
      exit 1
    fi
    shift 2
    while [ $# -gt 0 ] && [ "$1" != --project ]; do
      case "$1" in
        groupssettings.googleapis.com) k=groups_api_disabled ;;
        siteverification.googleapis.com) k=site_api_disabled ;;
        *) k=other ;;
      esac
      jq ".$k = false" "$STUB_GOOGLE_STATE" >"$STUB_GOOGLE_STATE.g" && mv "$STUB_GOOGLE_STATE.g" "$STUB_GOOGLE_STATE"
      echo "$1" >>"$STUB_GCLOUD_STATE.enabled"
      shift
    done
    echo "Operation finished successfully." >&2 ;;
  *) echo "gcloud stub: unexpected $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$work/bin/dig" "$work/bin/gh" "$work/bin/gcloud" "$work/apply"
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
export STUB_GOOGLE_STATE="$state" STUB_GCLOUD_STATE="$work/gcloud-mode" GOOGLE_WORKSPACE_API_ENABLE_WAIT=0
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
flat_has() { cat "$work/stdout" "$work/stderr" | tr -s ' \n' '  ' | grep -F -- "$1" >/dev/null; }
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
set_state '.aliases["example.app"].verified = true | .domains["example.dev"].verified = false'
expect_not "an alias whose parent is not verified keeps its mail records" \
  run onboard --no-pr --domain example.app --data "$data" --dmarc-rua dmarc@example.com
expect "... naming the parent" stderr_has "its parent example.dev is not"
expect "... and writing no MX" test "$(jq -c '.domains["example.app"].mx // null' "$data")" = null
set_state '.domains["example.dev"].verified = true'
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
# Google's directory shows a just-added alias only after a while: the send-as
# step must wait for it, not skip it and report success.
set_state '.alias_lag = 2'
export GOOGLE_ALIAS_WAIT_SECONDS=0
expect "a new alias the directory does not show yet is waited for" \
  run user-addresses --user jane@example.com --domain example.dev --local lagged --data "$data"
expect "... and still gets its send-as" \
  bash -c 'jq -e ".sendas[\"jane@example.com\"] | map(.sendAsEmail) | index(\"lagged@example.dev\")" "$1" >/dev/null' _ "$state"
set_state '.alias_lag = 1000'
rc=0
GOOGLE_ALIAS_WAIT_TRIES=2 run user-addresses --user jane@example.com --domain example.dev --local slow --data "$data" || rc=$?
expect "an alias that never shows up within the wait exits 2, not success" test "$rc" = 2
expect "... saying to re-run" output_has "not visible in the directory yet"
set_state '.alias_lag = 0 | .alias_hidden = {}'
unset GOOGLE_ALIAS_WAIT_SECONDS
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
expect "... and no report is held for a moderator (spam ALLOW, moderation none)" \
  test "$(jq -c '.groups["dmarc@example.com"] | [.spamModerationLevel, .messageModerationLevel]' "$state")" = '["ALLOW","MODERATE_NONE"]'
: >"$api_log"
expect "a re-run only reads" run dmarc-group --group dmarc@example.com
expect "... (no PATCH)" bash -c '! grep -q "^PATCH" "$1"' _ "$api_log"
set_state '.groups["dmarc@example.com"].spamModerationLevel = "MODERATE"'
: >"$api_log"
expect "a group that accepts outside posts but holds suspected spam is fixed too" run dmarc-group --group dmarc@example.com
expect "... (PATCH, spam moderation ALLOW)" \
  bash -c 'grep -q "^PATCH" "$1" && test "$(jq -r ".groups[\"dmarc@example.com\"].spamModerationLevel" "$2")" = ALLOW' _ "$api_log" "$state"
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
all_scopes="https://www.googleapis.com/auth/admin.directory.domain,https://www.googleapis.com/auth/admin.directory.domain.readonly,https://www.googleapis.com/auth/siteverification,https://www.googleapis.com/auth/admin.directory.user,https://www.googleapis.com/auth/gmail.settings.basic,https://www.googleapis.com/auth/gmail.settings.sharing,https://www.googleapis.com/auth/gmail.send,https://www.googleapis.com/auth/gmail.metadata,https://www.googleapis.com/auth/apps.groups.settings"
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
expect "... until every scope is granted" output_has "all 9 scopes are granted"
run scopes --scopes admin.directory.user,https://www.googleapis.com/auth/admin.directory.group || true
expect "--scopes checks exactly the given list" \
  bash -c 'grep -qx "  ok       admin.directory.group" "$1" && ! grep -q siteverification "$1"' _ "$work/stdout"

# ── 12. the setup wizard, end to end ─────────────────────────────────────────
# A fresh consumer and tenant, driven through `google-workspace-setup guided` by a
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
# With no domain on smtp.google.com yet there is nowhere to send the inbound
# test to: a domain whose mail goes elsewhere is left alone without asking (an
# empty stdin: any question would stop the run with exit 4).
mkdir -p "$work/noprobe"
jq '.domains |= {"example.net": .["example.net"]} | del(.google_users)' "$wdata" >"$work/noprobe/mail-auth.json"
rc=0
GOOGLE_WORKSPACE_DOMAINS_CMD="bash $tool" bash "$setup_tool" onboard-all --data "$work/noprobe/mail-auth.json" \
  </dev/null >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "with no domain already moved, the inbound-test gate refuses without asking" \
  bash -c '[ "$1" = 0 ] && grep -qF "skipping example.net: no inbound test confirmed yet" "$2"' _ "$rc" "$work/stdout"
expect "... and adds nothing" bash -c '! jq -e ".domains[\"example.net\"]" "$1" >/dev/null' _ "$state"
# onboard-all, with the inbound test skipped: the domain with no MX is
# onboarded; those whose MX names a host elsewhere — resolving or not — are NOT
# touched.
{
  echo             # example.org: Activate Gmail done
  echo s           # gate before example.xyz: skip
  echo s           # gate before example.net: skip
  echo s           # gate before example.info: skip
} >"$work/answers"
rc=0
wizard onboard-all <"$work/answers" >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "onboard-all onboards the domain with no MX" \
  bash -c '[ "$1" = 0 ] && test "$(jq -c "[.domains[\"example.org\"].verified]" "$2")" = "[true]"' _ "$rc" "$state"
expect "... asks for an inbound test before a domain whose MX names a host elsewhere" flat_has "Before switching a domain that receives mail today"
expect "... and, without one, leaves those domains alone (no domain added, no PR)" \
  bash -c '! grep -qE "example\.(net|info|xyz)" "$1" && ! jq -e ".domains[\"example.net\"] // .domains[\"example.xyz\"] // .aliases[\"example.info\"]" "$2" >/dev/null' _ "$STUB_GH_LOG" "$state"
expect "... saying so, also for the one whose mail host does not resolve" \
  bash -c 'grep -qF "skipping example.net: no inbound test confirmed yet" "$1" && grep -qF "skipping example.xyz: no inbound test confirmed yet" "$1"' _ "$work/stdout"
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
  echo n           # gate (before example.xyz): no inbound test yet
  echo y           # gate: now it arrived
  echo yes         # switch example.xyz
  echo             # example.xyz: Activate Gmail done
  echo s           # example.xyz: DKIM later
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
wizard guided <"$work/answers" >"$work/stdout" 2>"$work/stderr" || rc=$?
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
expect "... asking for the inbound test before switching example.xyz, and holding off on 'n'" \
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
wizard guided <"$work/answers" >"$work/stdout" 2>"$work/stderr" || rc=$?
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

# ── 14. the batched setup: the interactive phase, then the background phase ─
# A fresh consumer and tenant. `run` does the instant steps, collects the
# decisions and the console values, and opens ONE PR; `follow` lands it, waits
# for DNS, has Google verify, and opens the next batches. Each batch carries
# one kind of change, in the order of a real onboarding: verification tokens,
# the no-mail domains' records, (an inbound test from outside) the records
# that move live mail as decided, DKIM keys. Interrupted runs resume.
rm -f "$work"/dns/*
bsrc="$work/brepo" borigin="$work/borigin.git" bgh="$work/bgh"
git init --quiet --bare "$borigin"
git -C "$borigin" symbolic-ref HEAD refs/heads/main
git init --quiet "$bsrc"
mkdir -p "$bsrc/dns" "$bgh"
bdata="$bsrc/dns/mail-auth.json"
cat >"$bdata" <<'EOF'
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
    "example.org": {"zone_id": "00000000000000000000000000000021", "dkim": {}, "google": {"kind": "secondary"}},
    "example.biz": {"zone_id": "00000000000000000000000000000022", "dkim": {}, "google": {"kind": "alias", "parent": "example.org"}},
    "example.net": {"zone_id": "00000000000000000000000000000023", "dkim": {},
      "mx": [{"priority": 10, "host": "mail.example.net"}], "spf": {"include": ["_spf.oldhost.example"], "all": "?all"},
      "google": {"kind": "secondary", "spf_replace": true}},
    "example.info": {"zone_id": "00000000000000000000000000000024", "dkim": {},
      "mx": [{"priority": 10, "host": "mail.example.info"}], "google": {"kind": "alias", "parent": "example.net"}},
    "example.xyz": {"zone_id": "00000000000000000000000000000025", "dkim": {},
      "mx": [{"priority": 10, "host": "mail.example.xyz"}], "google": {"kind": "secondary"}},
    "example.dev": {"zone_pending": true, "dkim": {}, "google": {"kind": "secondary"}}
  },
  "google_users": {"admin@example.com": {"local_parts": ["admin"]}}
}
EOF
printf 'census\n' >"$bsrc/census.expected"
git -C "$bsrc" add -A && git -C "$bsrc" commit --quiet -m init
git -C "$bsrc" remote add origin "$borigin"
git -C "$bsrc" push --quiet origin HEAD:main
STUB_ORIGIN="$borigin" "$STUB_APPLY"
printf '192.0.2.10\n' >"$work/dns/mail.example.net.A"
printf '192.0.2.11\n' >"$work/dns/mail.example.info.A"
cat >"$state" <<'EOF'
{ "domains": { "example.com": { "isPrimary": true, "verified": true } }, "aliases": {},
  "users": { "admin@example.com": { "aliases": [] } },
  "groups": { "dmarc@example.com": { "whoCanPostMessage": "ALL_IN_DOMAIN_CAN_POST" } },
  "groups_api_disabled": true }
EOF
# gcloud's credentials have expired (the organisation's reauthentication
# policy), and the project has only two of the five APIs.
echo reauth >"$STUB_GCLOUD_STATE"
rm -f "$STUB_GCLOUD_STATE.login"
printf 'admin.googleapis.com\ngmail.googleapis.com\n' >"$STUB_GCLOUD_STATE.enabled"
export GOOGLE_WORKSPACE_STATE_DIR="$work/gws-state" GOOGLE_ALIAS_WAIT_SECONDS=0 GOOGLE_INBOUND_INTERVAL=0.2 GOOGLE_INBOUND_TIMEOUT=2
export GOOGLE_WORKSPACE_VERIFY_RETRY=1 GOOGLE_WORKSPACE_CHECKS_INTERVAL=0 GOOGLE_WORKSPACE_RERUN_SETTLE=0
bstate="$GOOGLE_WORKSPACE_STATE_DIR/example.com.json"
: >"$work/hook.log"
: >"$work/notify.log"
benv=(env STUB_ORIGIN="$borigin" STUB_GH_STATE="$bgh" GOOGLE_WORKSPACE_DOMAINS_CMD="bash $tool"
  GOOGLE_WORKSPACE_DKIM_CMD="bash $dkim_tool"
  GOOGLE_WORKSPACE_NOTIFY="{ echo \"TITLE \$NOTIFY_TITLE\"; cat; } >>$work/notify.log")
bargs=(--data "$bdata" --base main --dmarc-rua dmarc@example.com --group dmarc@example.com --post-edit "$hook")
batch() { timeout 600 "${benv[@]}" GOOGLE_WORKSPACE_FOLLOW_DETACH="${DETACH:-none}" bash "$setup_tool" "$1" "${bargs[@]}" "${@:2}"; }
bst() { jq -r "$@" "$bstate"; }
bst_set() { jq "$1" "$bstate" >"$bstate.t" && mv "$bstate.t" "$bstate"; }
head_of() { git -C "$borigin" rev-parse "refs/heads/$(cat "$bgh/$1" "$bgh/merged-$1" 2>/dev/null | head -n1)"; }
on_main() { git -C "$borigin" show main:dns/mail-auth.json | jq -c "$1"; }
on_pr() { git -C "$borigin" show "$(head_of "$1"):dns/mail-auth.json" | jq -c "$2"; }
# deliver FROM TO SUBJECT: a message from a mailbox outside the tenant, as the
# stub's MX rule delivers it.
deliver() {
  python3 - "$port" "$1" "$2" "$3" <<'EOF'
import json, sys, urllib.request, urllib.error
port, f, t, subj = sys.argv[1:5]
req = urllib.request.Request(f"http://127.0.0.1:{port}/test/deliver", data=json.dumps({"from": f, "to": t, "subject": subj}).encode(), method="POST")
try:
    urllib.request.urlopen(req)
except urllib.error.HTTPError:
    pass
EOF
}
mx_before="$(jq -c '[.domains[] | .mx]' "$bdata")"

# 14.1 the interactive phase
{
  echo e # decisions: one by one
  echo y # example.net: move once verified
  echo y # example.info: move once verified
  echo n # example.xyz: keep
  echo "$dkim_value"
  echo # (end of the paste)
} >"$work/answers"
: >"$api_log"
: >"$STUB_GH_LOG"
rc=0
batch run <"$work/answers" >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "the interactive phase finishes without waiting for any check" test "$rc" = 0
expect "... opening exactly ONE PR, from one batch branch" \
  bash -c '[ "$(grep -c "^gh pr create" "$1")" = 1 ] && grep -q "^mail/google-batch-" "$2/1"' _ "$STUB_GH_LOG" "$bgh"
expect "... one commit with a verification token for each of the five new domains, aliases included, and nothing else" \
  bash -c '[ "$(git -C "$1" rev-list --count "main..$2")" = 1 ] && git -C "$1" show "$2:dns/mail-auth.json" | jq -e "([.domains[\"example.org\",\"example.biz\",\"example.net\",\"example.info\",\"example.xyz\"].google_verification | length] == [1,1,1,1,1]) and ([.domains[].dkim | length] | add) == 0" >/dev/null' _ "$borigin" "$(head_of 1)"
expect "... titled as the verification batch" grep -q -- '--title dns: Google Workspace batch 1 — verification tokens (5 domains)' "$STUB_GH_LOG"
expect "... and no MX change at all (a domain's MX moves only once Google has verified it)" \
  test "$(on_pr 1 '[.domains[] | .mx]')" = "$mx_before"
expect "... the census hook run once, for the whole batch" \
  bash -c '[ "$(grep -c "^PHASE=" "$1")" = 1 ] && grep -qx "PHASE=batch DOMAIN=example.biz,example.info,example.net,example.org,example.xyz" "$1"' _ "$work/hook.log"
expect "... nothing merged, no verification asked for (that is the background phase's)" \
  bash -c '! grep -q "pr merge" "$1" && ! grep -q "^POST /siteVerification/v1/webResource" "$2"' _ "$STUB_GH_LOG" "$api_log"
expect "... the secondary domains on the tenant; the aliases not even tried while their parents are unverified" \
  bash -c 'jq -e "[.domains[\"example.org\",\"example.net\",\"example.xyz\"].isPrimary == false, (.aliases | length == 0), (.domains | has(\"example.dev\") | not)] | all" "$1" >/dev/null && ! grep -q "^POST .*/domainaliases" "$2"' _ "$state" "$api_log"
expect "... saying so" flat_has "example.biz waits for its parent example.org to be verified"
expect "... the decisions and the pasted key kept in the local state file, the key for a later batch" \
  test "$(bst -c '[.decisions["example.net"], .decisions["example.info"], .decisions["example.xyz"], (.dkim | keys), .batch.pr, .batch.stage, .batch.kind]')" = '["switch","switch","hold",["example.com"],1,"checks","verification"]'
expect "... and that later batch named among what is held back" flat_has "next, once batch 'verification' has landed: DKIM key (selector google) for example.com"
expect "... gcloud logged in again by the tool, then the three missing APIs enabled in one call" \
  bash -c 'l="$(grep "^gcloud" "$1")"; [ "$(sed -n 1p <<<"$l")" = "gcloud services list --enabled --project stub --format value(config.name)" ] && [ "$(sed -n 2p <<<"$l")" = "gcloud auth login" ] && [ "$(sed -n 4p <<<"$l")" = "gcloud services enable siteverification.googleapis.com groupssettings.googleapis.com orgpolicy.googleapis.com --project stub" ] && [ "$(jq -r ".groups[\"dmarc@example.com\"].whoCanPostMessage" "$2")" = ANYONE_CAN_POST ]' _ "$api_log" "$state"
expect "... never asking the operator to type a gcloud command" bash -c '! grep -qE "^ *(run|Run):? *gcloud" "$1"' _ "$work/stdout"
expect "... saying what happens next and how to check on it" \
  bash -c 'f="$(tr -s " \n" "  " <"$1")"; grep -qF "What happens next, without you" <<<"$f" && grep -qF "google-workspace-setup status" <<<"$f"' _ "$work/stdout"
expect "... within 78 columns" narrow "$work/stdout"
expect "... without printing the key" bash -c '! grep -qF -- "$1" "$2" "$3"' _ "$key_marker" "$work/stdout" "$work/stderr"
batch status >"$work/stdout" 2>"$work/stderr" || true
expect "status shows the batch in flight, its PR and stage, and the decisions" \
  bash -c 'grep -qF "batch 1: PR #1" "$1" && grep -qF "stage checks" "$1" && grep -qF "not running" "$1" && grep -qF "example.xyz hold" "$1"' _ "$work/stdout"

rc=0
batch run </dev/null >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "a second interactive run while the batch is in flight asks nothing and opens no second PR" \
  bash -c '[ "$1" = 0 ] && [ "$(grep -c "^gh pr create" "$2")" = 1 ] && tr -s " \n" "  " <"$3" | grep -qF "Batch 1 is in flight (PR #1, stage checks)"' _ "$rc" "$STUB_GH_LOG" "$work/stdout"

# 14.2 interrupted while watching the checks, then while waiting for DNS
touch "$bgh/hang"
setsid "${benv[@]}" GOOGLE_WORKSPACE_FOLLOW_DETACH=none bash "$setup_tool" follow "${bargs[@]}" >"$work/stdout" 2>"$work/stderr" &
fpid=$!
for _ in $(seq 1 3000); do grep -q "watching the checks of PR #1" "$work/stderr" 2>/dev/null && break; sleep 0.1; done
kill -TERM -- "-$fpid" 2>/dev/null || true
wait "$fpid" 2>/dev/null || true
rm -f "$bgh/hang"
expect "a follower interrupted mid-watch leaves the batch in flight, unmerged" \
  bash -c '[ "$(jq -r ".batch.pr, .batch.stage" "$1" | paste -sd" " -)" = "1 checks" ] && ! grep -q "pr merge" "$2"' _ "$bstate" "$STUB_GH_LOG"
expect "... and records that it stopped" test "$(bst '.follower.state')" = stopped
touch "$bgh/defer-apply"
: >"$STUB_GH_LOG"
rc=0
GOOGLE_WORKSPACE_DOMAINS_DNS_TIMEOUT=1 batch follow >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "resumed, it merges the SAME PR at the head it watched (no second PR)" \
  bash -c '! grep -q "^gh pr create" "$1" && grep -qx "gh pr merge 1 --merge --match-head-commit $2" "$1"' _ "$STUB_GH_LOG" "$(head_of 1)"
expect "... and while DNS does not serve the batch yet, stops in the DNS stage (exit non-zero)" \
  bash -c '[ "$1" != 0 ] && [ "$(jq -r .batch.stage "$2")" = dns ]' _ "$rc" "$bstate"
expect "... telling the notifier" grep -qx "TITLE Google Workspace setup: background phase stopped" "$work/notify.log"
rm -f "$bgh/defer-apply"
STUB_ORIGIN="$borigin" "$STUB_APPLY"

# 14.3 resumed again: it runs as far as it can without the operator
: >"$api_log"
: >"$STUB_GH_LOG"
: >"$work/notify.log"
rc=0
batch follow >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "resumed after the apply, the follower runs until it needs the operator" test "$rc" = 0
expect "... asking Google to verify the three secondary domains once their tokens are served" \
  bash -c 'for d in example.org example.net example.xyz; do grep -qx "VERIFY $d accepted" "$1" || exit 1; done' _ "$api_log"
expect "... adding each alias only once its parent is reported verified, then asking Google again for the alias" \
  bash -c 'a="$(grep -n "^POST .*/domainaliases" "$1" | head -n1 | cut -d: -f1)"; p="$(grep -n "^READ example.org verified=true" "$1" | head -n1 | cut -d: -f1)"; v="$(grep -n "^VERIFY example.biz accepted" "$1" | head -n1 | cut -d: -f1)"; [ -n "$a" ] && [ -n "$p" ] && [ -n "$v" ] && [ "$p" -lt "$a" ] && [ "$a" -lt "$v" ]' _ "$api_log"
expect "... batch 2: the mail records of the no-mail domains (example.org and its alias example.biz), nothing else" \
  bash -c '[ "$(jq -c "[.domains[\"example.org\",\"example.biz\"].mx[0].host]" <(git -C "$1" show "$2:dns/mail-auth.json"))" = "[\"smtp.google.com\",\"smtp.google.com\"]" ] && [ "$(git -C "$1" show "$2:dns/mail-auth.json" | jq -c "[.domains[\"example.net\",\"example.info\",\"example.xyz\"].mx[0].host, ([.domains[].dkim | length] | add)]")" = "[\"mail.example.net\",\"mail.example.info\",\"mail.example.xyz\",0]" ]' _ "$borigin" "$(head_of 2)"
expect "... batch 3: example.com's DKIM key alone" \
  bash -c 'git -C "$1" show "$2:dns/mail-auth.json" | jq -e --arg v "$3" ".domains[\"example.com\"].dkim.google == \$v" >/dev/null && [ "$(git -C "$1" show "$2:dns/mail-auth.json" | jq -S "del(.domains[\"example.com\"].dkim)")" = "$(git -C "$1" show "$4:dns/mail-auth.json" | jq -S "del(.domains[\"example.com\"].dkim)")" ]' _ "$borigin" "$(head_of 3)" "$dkim_value" "$(head_of 2)"
expect "... the mail that goes elsewhere today NOT moved: no message from outside has reached a moved domain yet" \
  test "$(on_main '[.domains["example.net","example.info","example.xyz"].mx[0].host]')" = '["mail.example.net","mail.example.info","mail.example.xyz"]'
expect "... every merge at the head it watched" \
  bash -c 'grep -qx "gh pr merge 2 --merge --match-head-commit $2" "$1" && grep -qx "gh pr merge 3 --merge --match-head-commit $3" "$1"' _ "$STUB_GH_LOG" "$(head_of 2)" "$(head_of 3)"
expect "... the user's addresses on the domains whose mail is on Google now, accepted for sending" \
  test "$(jq -c '[.sendas["admin@example.com"][] | select(.isPrimary | not) | select(.verificationStatus == "accepted") | .sendAsEmail] | sort' "$state")" = '["admin@example.biz","admin@example.org"]'
expect "... ending with what still needs the operator" \
  bash -c 'f="$(tr -s " \n" "  " <"$1")"; for p in "Activate Gmail (https://admin.google.com/ac/domains/manage) for: example.biz, example.org" "Start authentication (https://admin.google.com/ac/apps/gmail/authenticateemail) for: example.com — DNS serves their DKIM keys now" "the inbound test: send a message from a mailbox OUTSIDE the tenant" "DKIM for example.org example.biz after Activate Gmail" "as decided (or undecided), for example.xyz" "zone pending (skipped): example.dev"; do grep -qF -- "$p" <<<"$f" || { echo "missing: $p"; exit 1; }; done' _ "$work/stderr"
expect "... kept for status, and sent to the notifier" \
  bash -c '[ "$(jq ".summary | length" "$1")" -ge 4 ] && grep -qx "TITLE Google Workspace setup: background phase finished" "$2"' _ "$bstate" "$work/notify.log"
expect "... no batch left in flight, three landed" test "$(bst -c '[.batch, (.history | length), .follower.state]')" = '[null,3,"finished"]'
rc=0
batch follow >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "a follower with nothing to do ends at once, opening no PR" \
  bash -c '[ "$1" = 0 ] && [ "$(grep -c "^gh pr create" "$2")" = 2 ]' _ "$rc" "$STUB_GH_LOG"

# 14.4 the inbound test: a message from OUTSIDE the tenant, found in the inbox
# marker_of: the subject marker the tool last asked for.
marker_of() { grep -o 'inbound-test-[0-9-]*' "$work/stdout" | tail -n1; }
set_state '.inbound_broken = true'
: >"$STUB_GH_LOG"
rc=0
guided_run 'deliver ext@outside.example admin@example.org "$(marker_of)"|' '|s' -- \
  "${benv[@]}" GOOGLE_WORKSPACE_FOLLOW_DETACH=none bash "$setup_tool" inbound-test "${bargs[@]}" || rc=$?
expect "when the message from outside does not arrive, nothing that receives mail elsewhere moves" \
  bash -c '[ "$1" = 0 ] && ! grep -q "^gh pr create" "$2" && [ "$(jq -r ".inbound.ok // false" "$3")" = false ]' _ "$rc" "$STUB_GH_LOG" "$bstate"
expect "... having asked for a message to admin@example.org, from OUTSIDE, with a subject marker" \
  bash -c 'f="$(tr -s " \n" "  " <"$1")"; grep -qF "From a mailbox OUTSIDE this tenant" <<<"$f" && grep -qF "admin@example.org" <<<"$f" && grep -q "inbound-test-[0-9]" <<<"$f"' _ "$work/stdout"
expect "... and saying it is not there, and what to check" flat_has "Check, for example.org: its MX is smtp.google.com"
set_state '.inbound_broken = false | .deny_scopes = ["gmail.metadata", "gmail.readonly"]'
rc=0
{ echo; echo n; echo s; } | "${benv[@]}" GOOGLE_WORKSPACE_FOLLOW_DETACH=none bash "$setup_tool" inbound-test "${bargs[@]}" >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "without a Gmail read scope it cannot look, asks, and on 'n' moves nothing" \
  bash -c '[ "$1" = 0 ] && ! grep -q "^gh pr create" "$2" && [ "$(jq -r ".inbound.ok // false" "$3")" = false ]' _ "$rc" "$STUB_GH_LOG" "$bstate"
expect "... saying why it asks" flat_has "grants neither gmail.metadata nor gmail.readonly, so this tool cannot look"
set_state '.deny_scopes = []'
# A message sent from INSIDE the tenant proves nothing (delivered internally):
# refused, and a new marker asked for; then one from outside passes.
: >"$STUB_GH_LOG"
rc=0
guided_run 'deliver admin@example.com admin@example.org "$(marker_of)"|' 'deliver friend@outside.example admin@example.org "$(marker_of)"|' -- \
  "${benv[@]}" GOOGLE_WORKSPACE_FOLLOW_DETACH=none bash "$setup_tool" inbound-test "${bargs[@]}" || rc=$?
expect "a message from inside the tenant is refused as proof" flat_has "it came from admin@example.com, an address of this tenant: delivered internally, it proves nothing"
expect "... one from outside is found in the inbox and recorded" \
  test "$(bst -c '[.inbound.ok, .inbound.via, .inbound.domain, .inbound.from]')" = '[true,"gmail-api","example.org","friend@outside.example"]'
expect "... and the batch moving the live mail is opened at once: example.net and its alias, as decided, not example.xyz" \
  bash -c '[ "$1" = 0 ] && [ "$(jq -c "[.batch.kind, [.batch.items[] | [.domain, .change]]]" "$2")" = "[\"records-live\",[[\"example.net\",\"records\"],[\"example.info\",\"records\"]]]" ]' _ "$rc" "$bstate"
expect "... titled so" grep -q -- '--title dns: Google Workspace batch 4 — mail records, moving live mail (2 domains)' "$STUB_GH_LOG"
rc=0
batch follow >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "the follower lands it: example.net and example.info on Google, example.xyz kept" \
  bash -c '[ "$1" = 0 ] && [ "$(git -C "$2" show main:dns/mail-auth.json | jq -c "[.domains[\"example.net\",\"example.info\",\"example.xyz\"].mx[0].host, .domains[\"example.net\"].spf.include]")" = "[\"smtp.google.com\",\"smtp.google.com\",\"mail.example.xyz\",[\"_spf.google.com\"]]" ]' _ "$rc" "$borigin"
expect "... then the user's addresses there" \
  test "$(jq -c '[.sendas["admin@example.com"][] | select(.isPrimary | not) | select(.verificationStatus == "accepted") | .sendAsEmail] | sort' "$state")" = '["admin@example.biz","admin@example.info","admin@example.net","admin@example.org"]'

# 14.5 the next interactive run: the console steps the batches made due, then
# the DKIM keys now possible — except for a domain an open per-domain PR has
echo dkim/example.org-google >"$bgh/50"
printf 'y\ny\ns\ns\ns\n' >"$work/answers"
rc=0
batch run <"$work/answers" >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "a domain with an open per-domain PR is left to it: no DKIM prompt for it" \
  bash -c '[ "$1" = 0 ] && f="$(tr -s " \n" "  " <"$2")" && grep -qF "DKIM keys: example.biz example.net example.info" <<<"$f" && grep -qF "example.org: left to the open PR #50 (dkim/example.org-google)" <<<"$f"' _ "$rc" "$work/stdout"
expect "... having confirmed the console steps the batches made due" test "$(bst -c '[.todo.activate_gmail, .todo.start_auth]')" = '[[],[]]'
rm -f "$bgh/50"
batch status >"$work/stdout" 2>"$work/stderr" || true
expect "status then shows the finished follower, the batches landed, the inbound proof and its log" \
  bash -c 'grep -qF "not running (last run finished)" "$1" && grep -qF "no batch in flight (4 landed so far)" "$1" && grep -qF "inbound proof: yes (gmail-api, example.org)" "$1" && grep -qF "nothing more can be published now" "$1"' _ "$work/stdout"
expect "... within 78 columns" narrow "$work/stdout"

# 14.6 a batch made by hand, as an open PR with any branch name: a domain its
# head changes is left to it, and the follower waits for it, then carries on
# from what it published (the domain is on the tenant already, its token
# fetched by hand).
git -C "$bsrc" pull --quiet --ff-only origin main
jq --indent 2 '.domains["example.app"] = {zone_id: "00000000000000000000000000000026", dkim: {}, google: {kind: "secondary"}}' "$bdata" >"$bdata.new" && mv "$bdata.new" "$bdata"
git -C "$bsrc" commit --quiet -am "declare example.app" && git -C "$bsrc" push --quiet origin HEAD:main
STUB_ORIGIN="$borigin" "$STUB_APPLY"
set_state '.domains["example.app"] = {isPrimary: false, verified: false}'
git -C "$bsrc" checkout --quiet -b by-hand
jq --indent 2 '.domains["example.app"].google_verification = ["google-site-verification=example-app-Tok_123"]' "$bdata" >"$bdata.new" && mv "$bdata.new" "$bdata"
git -C "$bsrc" commit --quiet -am "batch 1 by hand" && git -C "$bsrc" push --quiet origin by-hand:mail/batch-1-verification
git -C "$bsrc" checkout --quiet main
echo mail/batch-1-verification >"$bgh/52"
printf 's\ns\ns\ns\n' >"$work/answers"
: >"$STUB_GH_LOG"
rc=0
batch run <"$work/answers" >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "the interactive phase leaves a domain that an open hand-made PR changes to that PR" \
  bash -c '[ "$1" = 0 ] && ! grep -q "^gh pr create" "$2" && tr -s " \n" "  " <"$3" | grep -qF "example.app: left to the open PR #52 (mail/batch-1-verification)"' _ "$rc" "$STUB_GH_LOG" "$work/stdout"
GOOGLE_WORKSPACE_FOREIGN_PR_INTERVAL=1 batch follow >"$work/stdout" 2>"$work/stderr" &
fpid=$!
for _ in $(seq 1 3000); do grep -q "waiting for the open PR(s) that carry example.app: #52" "$work/stderr" 2>/dev/null && break; sleep 0.1; done
expect "the follower waits for that PR rather than publishing the same change" \
  bash -c 'grep -qF "waiting for the open PR(s) that carry example.app: #52" "$1" && ! grep -q "^gh pr create" "$2"' _ "$work/stderr" "$STUB_GH_LOG"
# Merged by hand, and applied.
git -C "$borigin" update-ref refs/heads/main "$(git -C "$borigin" rev-parse refs/heads/mail/batch-1-verification)"
mv "$bgh/52" "$bgh/merged-52"
STUB_ORIGIN="$borigin" "$STUB_APPLY"
rc=0
wait "$fpid" || rc=$?
expect "... and once it is merged, verifies the domain and publishes its mail records in its own batch" \
  bash -c '[ "$1" = 0 ] && [ "$(jq -r ".domains[\"example.app\"].verified" "$2")" = true ] && [ "$(git -C "$3" show main:dns/mail-auth.json | jq -c "[.domains[\"example.app\"].mx[0].host, (.domains[\"example.app\"].google_verification | length)]")" = "[\"smtp.google.com\",1]" ] && [ "$(grep -c "^gh pr create" "$4")" = 1 ]' _ "$rc" "$state" "$borigin" "$STUB_GH_LOG"
git -C "$bsrc" pull --quiet --ff-only origin main

# ── 15. dkim-collect: one sitting, many domains, one PR ──────────────────────
# example.app's Activate Gmail is not confirmed yet (the console offers no key
# before it); example.org, example.biz, example.net and example.info can have a
# key. One invalid paste is refused and asked again; two keys go out in ONE
# PR; once DNS serves them, the follower says to click Start authentication.
{
  echo n                          # Activate Gmail for example.app: not yet
  echo "v=DKIM1; k=rsa; p=AAAAnotakey"
  echo                            # (end of the paste) -> refused
  echo "$dkim_value"
  echo                            # example.org
  echo "$dkim_value"
  echo                            # example.biz
  echo s                          # example.net: later
  echo s                          # example.info: later
} >"$work/answers"
: >"$STUB_GH_LOG"
: >"$work/hook.log"
rc=0
batch dkim-collect <"$work/answers" >"$work/stdout" 2>"$work/stderr" || rc=$?
dpr="$(bst '.batch.pr // empty')"
expect "dkim-collect asks for every domain's key in one sitting and opens ONE PR" \
  bash -c '[ "$1" = 0 ] && [ "$(grep -c "^gh pr create" "$2")" = 1 ] && [ -n "$3" ]' _ "$rc" "$STUB_GH_LOG" "$dpr"
expect "... leaving out a domain whose Activate Gmail is not confirmed" flat_has "DKIM after Activate Gmail (the console offers no key before it): example.app"
expect "... validating each paste: an unusable one is refused and asked again" flat_has "that is not a usable DKIM value (above); paste it again"
expect "... the PR is the DKIM batch, with the two keys and nothing else" \
  bash -c 'grep -q -- "--title dns: Google Workspace batch [0-9]* — DKIM keys (2 domains)" "$1" && git -C "$2" show "$3:dns/mail-auth.json" | jq -e --arg v "$4" "[.domains[\"example.org\",\"example.biz\"].dkim.google] == [\$v, \$v]" >/dev/null && [ "$(git -C "$2" show "$3:dns/mail-auth.json" | jq -S "del(.domains[\"example.org\",\"example.biz\"].dkim)")" = "$(git -C "$2" show main:dns/mail-auth.json | jq -S "del(.domains[\"example.org\",\"example.biz\"].dkim)")" ]' _ "$STUB_GH_LOG" "$borigin" "$(head_of "$dpr")" "$dkim_value"
expect "... the census hook run once for both" grep -qx "PHASE=batch DOMAIN=example.biz,example.org" "$work/hook.log"
expect "... saying not to click Start authentication before DNS serves the key" flat_has "Do NOT click 'Start authentication' yet"
rc=0
batch follow >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "the follower lands it and, once DNS serves the keys, says to click Start authentication for both" \
  bash -c '[ "$1" = 0 ] && [ "$(jq -c ".todo.start_auth" "$2")" = "[\"example.biz\",\"example.org\"]" ] && tr -s " \n" "  " <"$3" | grep -qF "Start authentication (https://admin.google.com/ac/apps/gmail/authenticateemail) for: example.biz, example.org — DNS serves their DKIM keys now"' _ "$rc" "$bstate" "$work/stderr"
expect "... the keys are on main" \
  bash -c 'git -C "$1" show main:dns/mail-auth.json | jq -e --arg v "$2" "[.domains[\"example.org\",\"example.biz\"].dkim.google] == [\$v, \$v]" >/dev/null' _ "$borigin" "$dkim_value"
git -C "$bsrc" pull --quiet --ff-only origin main

# ── 16. the merge gate: required checks present AND green, labels, plan, apply
# A consumer whose CI fails an unrelated check on every DNS change (an import
# gate that refuses creates, machine evaluation shards) names the checks that
# matter. The credentialed plan registers late, then fails once (a runner
# timeout); it is re-run. The plan check is asked until the plan for the head
# is there. The apply on the base branch is cancelled once; it is re-run.
jq --indent 2 '.domains["example.gate"] = {zone_id: "00000000000000000000000000000027", dkim: {}, google: {kind: "secondary"},
  mx: [{priority: 10, host: "mx1.gate.invalid"}, {priority: 20, host: "mx2.gate.invalid"}]}' "$bdata" >"$bdata.new" && mv "$bdata.new" "$bdata"
git -C "$bsrc" commit --quiet -am "declare example.gate" && git -C "$bsrc" push --quiet origin HEAD:main
STUB_ORIGIN="$borigin" "$STUB_APPLY"
bst_set '.decisions["example.gate"] = "switch"'
cat >"$work/plan-check.sh" <<EOF
# The first look at a PR finds no plan for its head yet (2); the next matches.
{ echo "PR=\$PR HEAD=\$HEAD_SHA KNOWN=\$RECORD_ADDRESSES_KNOWN"; echo "ADDED<<\$RECORD_ADDRESSES_ADDED>>"; echo "REMOVED<<\$RECORD_ADDRESSES_REMOVED>>"; } >>"$work/plan.log"
[ -f "$work/plan-seen-\$PR" ] && exit 0
touch "$work/plan-seen-\$PR"
exit 2
EOF
: >"$work/plan.log"
rm -f "$work"/plan-seen-*
cat >"$bgh/checks-next.json" <<'EOF'
[
  {"name": "checks/ gates that need Nix", "bucket": "pass", "link": "https://github.invalid/o/r/actions/runs/101/job/1", "pending": 2},
  {"name": "pr (terraform/cloudflare/x) / credentialed-plan", "bucket": "fail", "link": "https://github.invalid/o/r/actions/runs/102/job/2", "late": 3},
  {"name": "import / plan", "bucket": "fail", "link": "https://github.invalid/o/r/actions/runs/103/job/3"},
  {"name": "ci / eval-matrix (shard-07)", "bucket": "fail", "link": "https://github.invalid/o/r/actions/runs/104/job/4"}
]
EOF
echo '[{"name": "checks/ gates that need Nix", "bucket": "pass", "link": "https://github.invalid/o/r/actions/runs/201/job/1"}, {"name": "pr (terraform/cloudflare/x) / credentialed-plan", "bucket": "pass", "link": "https://github.invalid/o/r/actions/runs/202/job/1"}]' >"$bgh/checks-default.json"
echo '[{"databaseId": 900, "status": "completed", "conclusion": "cancelled"}]' >"$bgh/apply-runs.json"
touch "$bgh/defer-apply"
: >"$bgh/reruns"
gate_env=(GOOGLE_WORKSPACE_REQUIRED_CHECKS='checks/ gates that need Nix; pr (*) / credentialed-plan'
  GOOGLE_WORKSPACE_PR_LABELS=sensitive-change GOOGLE_WORKSPACE_DESTROY_LABEL=allow-destroy
  GOOGLE_WORKSPACE_PLAN_CHECK="bash $work/plan-check.sh" GOOGLE_WORKSPACE_APPLY_WORKFLOW="Terraform Infrastructure"
  GOOGLE_WORKSPACE_CHECKS_TIMEOUT=60)
: >"$STUB_GH_LOG"
: >"$api_log"
rc=0
(export "${gate_env[@]}" GOOGLE_WORKSPACE_DOMAINS_DNS_TIMEOUT=3; batch follow) >"$work/stdout" 2>"$work/stderr" || rc=$?
g1="$(sed -n 's/^gh pr merge \([0-9]*\) .*/\1/p' "$STUB_GH_LOG" | head -n1)"
g2="$(sed -n 's/^gh pr merge \([0-9]*\) .*/\1/p' "$STUB_GH_LOG" | sed -n 2p)"
expect "the follower merges the token batch once the REQUIRED checks passed, with the import gate and an unrelated shard failing" \
  bash -c '[ "$1" = 0 ] && [ -n "$2" ] && grep -qx "gh pr merge $2 --merge --match-head-commit $3" "$4"' _ "$rc" "$g1" "$(head_of "$g1")" "$STUB_GH_LOG"
expect "... having waited while the credentialed plan was not even registered yet (not 'nothing pending')" \
  flat_has "missing: pr (*) / credentialed-plan"
expect "... re-running the failed credentialed plan's run, and the cancelled apply's, never the ignored ones" \
  bash -c 'grep -qx 102 "$1" && grep -qx 900 "$1" && ! grep -qxE "103|104" "$1"' _ "$bgh/reruns"
expect "... asking the plan check until the plan for the head was there, with what the batch added" \
  bash -c '[ "$(grep -c "^PR=$2 HEAD=$3 KNOWN=1$" "$1")" = 2 ] && grep -qF "google-site-verification=example-gate-Tok_123" "$1"' _ "$work/plan.log" "$g1" "$(head_of "$g1")"
expect "... the token batch labelled for the credentialed plan only (it removes nothing)" \
  test "$(paste -sd, "$bgh/lbl.$g1")" = sensitive-change
expect "... then example.gate's MX switch, which drops its second MX: labelled allow-destroy too" \
  bash -c '[ -n "$2" ] && [ "$(paste -sd, "$1/lbl.$2")" = "sensitive-change,allow-destroy" ] && git -C "$3" show main:dns/mail-auth.json | jq -e ".domains[\"example.gate\"].mx == [{priority: 1, host: \"smtp.google.com\"}]" >/dev/null' _ "$bgh" "$g2" "$borigin"
expect "... its plan check told what it removes" grep -qF 'example.gate|MX|2' "$work/plan.log"
rm -f "$bgh/checks-default.json" "$bgh/apply-runs.json" "$bgh/defer-apply"
git -C "$bsrc" pull --quiet --ff-only origin main

# ── 17. domain aliases: only after the parent, and a lagging verification ────
set_state '.domains["example.unv"] = {isPrimary: false, verified: false}'
rc=0
read -r -a apic <<<"${GOOGLE_WORKSPACE_DOMAINS_API:-python3 $here/../google-workspace-domains-api.py}"
"${apic[@]}" --key "$GOOGLE_WORKSPACE_KEY" --subject admin@example.com \
  alias example.zz example.unv >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "Google's 409 for an alias of an unverified parent is exit 4, not a success" test "$rc" = 4
expect "... saying to add it again once the parent is verified" stderr_has "the parent domain is not verified yet"
expect "... and nothing was added" test "$(jq '.aliases | has("example.zz")' "$state")" = false
# example.lag, an alias of the verified example.app, whose Workspace
# verification lags well behind Site Verification: its token goes out, Site
# Verification accepts it, its (no-mail) records go out while the Directory
# still says unverified, and the follower keeps asking until it is verified.
jq --indent 2 '.domains["example.lag"] = {zone_id: "00000000000000000000000000000028", dkim: {}, google: {kind: "alias", parent: "example.app"}}' "$bdata" >"$bdata.new" && mv "$bdata.new" "$bdata"
git -C "$bsrc" commit --quiet -am "declare example.lag" && git -C "$bsrc" push --quiet origin HEAD:main
STUB_ORIGIN="$borigin" "$STUB_APPLY"
set_state '.alias_verify_lag = 10'
: >"$api_log"
: >"$STUB_GH_LOG"
rc=0
GOOGLE_WORKSPACE_DOMAINS_VERIFY_TIMEOUT=1 batch follow >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "an alias whose verification lags is published, accepted by Site Verification, and waited for" \
  bash -c '[ "$1" = 0 ] && [ "$(jq -r ".aliases[\"example.lag\"].verified" "$2")" = true ]' _ "$rc" "$state"
expect "... Site Verification asked only once the alias existed" \
  bash -c '[ "$(grep -n "^POST .*/domainaliases" "$1" | head -n1 | cut -d: -f1)" -lt "$(grep -n "^VERIFY example.lag" "$1" | head -n1 | cut -d: -f1)" ]' _ "$api_log"
expect "... its no-mail records published while the Directory still reported it unverified" \
  bash -c 'c="$(grep -n "^gh pr create" "$1" | sed -n 2p | cut -d: -f1)"; v="$(grep -n "^READ example.lag verified=true" "$1" | head -n1 | cut -d: -f1)"; [ -n "$c" ] && [ -n "$v" ] && [ "$c" -lt "$v" ] && git -C "$2" show main:dns/mail-auth.json | jq -e ".domains[\"example.lag\"].mx[0].host == \"smtp.google.com\"" >/dev/null' _ "$api_log" "$borigin"
expect "... saying why" flat_has "example.lag: Site Verification accepted its token; Workspace does not report it verified yet"
expect "... and that it kept asking Google" flat_has "waiting for Google to report verified: example.lag"
set_state 'del(.alias_verify_lag)'
git -C "$bsrc" pull --quiet --ff-only origin main

# ── 18. registrar-debris: what a transferred-in zone carries ─────────────────
# A Cloudflare API stand-in with a zone that came from a registrar that had
# suspended the domain: subdomain delegations to its suspension nameservers,
# parking A records; plus an intentional delegation and real records.
cat >"$work/cf-stub.py" <<'EOF'
import json, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
STATE, LOG, PORT_FILE = sys.argv[1:4]
READ, WRITE = "plan-tok", "apply-tok"
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body):
        d = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d)
    def tok(self): return self.headers.get("Authorization", "")[len("Bearer "):]
    def go(self, method):
        u = urllib.parse.urlsplit(self.path); s = json.load(open(STATE)); t = self.tok()
        open(LOG, "a").write(f"{method} {u.path} token={'apply' if t == WRITE else 'plan' if t == READ else 'bad'}\n")
        if t not in (READ, WRITE): return self.reply(403, {"success": False, "errors": [{"code": 9109, "message": "Invalid access token"}]})
        p = u.path.split("/")
        if u.path == "/zones":
            name = urllib.parse.parse_qs(u.query).get("name", [""])[0]
            return self.reply(200, {"success": True, "result": [{"id": z, "name": v["name"]} for z, v in s.items() if v["name"] == name]})
        z = s.get(p[2]) if len(p) > 2 else None
        if not z: return self.reply(404, {"success": False, "errors": [{"code": 7003, "message": "no zone"}]})
        if len(p) == 3: return self.reply(200, {"success": True, "result": {"id": p[2], "name": z["name"], "name_servers": z["ns"]}})
        if len(p) == 4 and method == "GET":
            return self.reply(200, {"success": True, "result": z["records"], "result_info": {"page": 1, "total_pages": 1}})
        if len(p) == 5 and method == "DELETE":
            if t != WRITE: return self.reply(403, {"success": False, "errors": [{"code": 10000, "message": "Authentication error"}]})
            z["records"] = [r for r in z["records"] if r["id"] != p[4]]
            json.dump(s, open(STATE, "w")); return self.reply(200, {"success": True, "result": {"id": p[4]}})
        return self.reply(404, {"success": False, "errors": [{"code": 1, "message": "no route"}]})
    def do_GET(self): self.go("GET")
    def do_DELETE(self): self.go("DELETE")
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(PORT_FILE, "w").write(str(srv.server_address[1])); srv.serve_forever()
EOF
cat >"$work/cf-state.json" <<'EOF'
{"zone0000000000000000000000000029": {"name": "example.moved", "ns": ["ada.ns.cloudflare.com", "bob.ns.cloudflare.com"], "records": [
  {"id": "r01", "type": "NS", "name": "_dmarc.example.moved", "content": "failed-whois-verification.namecheap.com"},
  {"id": "r02", "type": "NS", "name": "_dmarc.example.moved", "content": "verify-contact-details.namecheap.com"},
  {"id": "r03", "type": "NS", "name": "www.example.moved", "content": "failed-whois-verification.namecheap.com"},
  {"id": "r04", "type": "NS", "name": "lab.example.moved", "content": "ns1.other-dns.example"},
  {"id": "r05", "type": "A", "name": "example.moved", "content": "198.54.117.242"},
  {"id": "r06", "type": "A", "name": "api.example.moved", "content": "192.0.2.5"},
  {"id": "r07", "type": "MX", "name": "example.moved", "content": "smtp.google.com"},
  {"id": "r08", "type": "NS", "name": "example.moved", "content": "ada.ns.cloudflare.com"}]}}
EOF
python3 "$work/cf-stub.py" "$work/cf-state.json" "$work/cf.log" "$work/cf.port" &
cf_pid=$!
trap '[ -n "$stub_pid" ] && kill "$stub_pid" 2>/dev/null; kill "$smtp_pid" "$cf_pid" 2>/dev/null; rm -rf "$work"' EXIT
for _ in $(seq 1 100); do [ -s "$work/cf.port" ] && break; sleep 0.1; done
CLOUDFLARE_API_BASE="http://127.0.0.1:$(cat "$work/cf.port")"
export CLOUDFLARE_API_BASE
printf 'ada.ns.cloudflare.com.\nbob.ns.cloudflare.com.\n' >"$work/dns/example.moved.NS"
printf 'plan-tok\n' >"$work/cf-plan"
: >"$work/cf.log"
rc=0
run registrar-debris --domain example.moved --token-file "$work/cf-plan" || rc=$?
expect "registrar-debris lists a zone's registrar debris through the API, read-only (exit 2)" \
  bash -c '[ "$1" = 2 ] && ! grep -q "^DELETE" "$2"' _ "$rc" "$work/cf.log"
expect "... the delegations to the suspension nameservers, as registrar debris" \
  bash -c '[ "$(grep -c "registrar debris: delegates" "$1")" = 3 ] && grep -qE "^r01 +NS +_dmarc\.example\.moved" "$1" && grep -qE "^r03 +NS +www\.example\.moved" "$1"' _ "$work/stdout"
expect "... a delegation elsewhere, flagged for a look" grep -qE "^r04 .*ns1\.other-dns\.example — delegated to a nameserver that is not the zone's" "$work/stdout"
expect "... the parking address, and nothing else (not the real A, MX or the apex NS)" \
  bash -c 'grep -qE "^r05 +A +example\.moved +198\.54\.117\.242 — a registrar.s parking address" "$1" && ! grep -qE "^r0[678] " "$1"' _ "$work/stdout"
expect "... never printing the token" bash -c '! grep -qF plan-tok "$1" "$2"' _ "$work/stdout" "$work/stderr"
rc=0
run registrar-debris --domain example.moved --token-file "$work/cf-plan" --allow-ns 'ns1.other-dns.example' || rc=$?
expect "--allow-ns accepts an intentional delegation" bash -c '[ "$1" = 2 ] && ! grep -q "^r04 " "$2" && grep -q "^r05 " "$2"' _ "$rc" "$work/stdout"
# Without a token: public DNS for the usual names.
printf 'failed-whois-verification.namecheap.com.\n' >"$work/dns/_dmarc.example.moved.NS"
printf '198.54.117.242\n' >"$work/dns/www.example.moved.A"
rc=0
env CLOUDFLARE_API_TOKEN= bash "$tool" registrar-debris --domain example.moved >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "without a token it probes public DNS and finds the same kind of debris" \
  bash -c '[ "$1" = 2 ] && grep -qE "^- +NS +_dmarc\.example\.moved +failed-whois-verification" "$2" && grep -qE "^- +A +www\.example\.moved +198\.54\.117\.242" "$2"' _ "$rc" "$work/stdout"
printf 'failed-whois-verification.namecheap.com.\nverify-contact-details.namecheap.com.\n' >"$work/dns/example.suspended.NS"
rc=0
env CLOUDFLARE_API_TOKEN= bash "$tool" registrar-debris --domain example.suspended --names www >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "a domain the registrar itself has suspended is called out (exit 2)" \
  bash -c '[ "$1" = 2 ] && grep -qF "the registrar has suspended its DNS" "$2"' _ "$rc" "$work/stderr"
# The guided deletion: the edit token is unlocked first, the records listed
# and deleted on "yes", listed again, and the token locked whatever happens.
unlock="echo apply-tok >$work/cf-apply; echo unlocked >>$work/cf-lock.log"
lock="rm -f $work/cf-apply; echo locked >>$work/cf-lock.log"
: >"$work/cf-lock.log"
rc=0
echo no | bash "$tool" registrar-debris --domain example.moved --token-file "$work/cf-apply" --unlock "$unlock" --lock "$lock" --delete \
  >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "--delete answered other than yes deletes nothing, and locks the token again" \
  bash -c '[ "$1" = 2 ] && ! grep -q "^DELETE" "$2" && [ "$(paste -sd, "$3")" = unlocked,locked ] && [ ! -e "$4" ]' _ "$rc" "$work/cf.log" "$work/cf-lock.log" "$work/cf-apply"
: >"$work/cf-lock.log"
: >"$work/cf.log"
rc=0
echo yes | bash "$tool" registrar-debris --domain example.moved --token-file "$work/cf-apply" --unlock "$unlock" --lock "$lock" --allow-ns 'ns1.other-dns.example' --delete \
  >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "--delete with yes removes exactly the debris through the API, with the edit token" \
  bash -c '[ "$1" = 0 ] && [ "$(grep -c "^DELETE .* token=apply" "$2")" = 4 ] && [ "$(jq -r "[.[].records[].id] | join(\",\")" "$3")" = "r04,r06,r07,r08" ]' _ "$rc" "$work/cf.log" "$work/cf-state.json"
expect "... checking the zone again afterwards" stderr_has "OK: the zone has no registrar debris left"
expect "... the token unlocked before and locked after" \
  bash -c '[ "$(paste -sd, "$1")" = unlocked,locked ] && [ ! -e "$2" ]' _ "$work/cf-lock.log" "$work/cf-apply"
unset CLOUDFLARE_API_BASE

# ── 19. credentials: the key unlock, and a key gone under the follower ───────
missing_key="$work/runtime/google-admin/service-account.json"
unlock_key="mkdir -p $work/runtime/google-admin && cp $work/sa.json $missing_key"
rc=0
env GOOGLE_WORKSPACE_KEY="$missing_key" GOOGLE_WORKSPACE_KEY_UNLOCK="$unlock_key" "${benv[@]}" \
  bash "$setup_tool" status "${bargs[@]}" </dev/null >"$work/stdout" 2>"$work/stderr" || rc=$?
expect "a missing key stops a step without a terminal, naming the unlock command (not running it)" \
  bash -c '[ "$1" != 0 ] && grep -qF "unlock it with: $3" "$2" && grep -qF "a restart empties" "$2" && [ ! -e "$4" ]' _ "$rc" "$work/stderr" "$unlock_key" "$missing_key"
rc=0
printf 'y\n' | script -qec "env GOOGLE_WORKSPACE_KEY='$missing_key' GOOGLE_WORKSPACE_KEY_UNLOCK='$unlock_key' $(printf '%q ' "${benv[@]}") bash $(printf '%q' "$setup_tool") status $(printf '%q ' "${bargs[@]}")" /dev/null \
  >"$work/stdout" 2>&1 || rc=$?
expect "... at a terminal it offers to run it, runs it, and goes on" \
  bash -c '[ -r "$1" ] && grep -qF "now, in this terminal?" "$2" && grep -qE "^example\.org +seco" "$2"' _ "$missing_key" "$work/stdout"
# The follower: the key disappears while it waits for a PR (a host restart).
jq --indent 2 '.domains["example.key"] = {zone_id: "00000000000000000000000000000030", dkim: {}, google: {kind: "secondary"}}' "$bdata" >"$bdata.new" && mv "$bdata.new" "$bdata"
git -C "$bsrc" commit --quiet -am "declare example.key" && git -C "$bsrc" push --quiet origin HEAD:main
STUB_ORIGIN="$borigin" "$STUB_APPLY"
touch "$bgh/hang"
: >"$work/notify.log"
: >"$STUB_GH_LOG"
env GOOGLE_WORKSPACE_KEY="$missing_key" GOOGLE_WORKSPACE_KEY_UNLOCK="$unlock_key" "${benv[@]}" GOOGLE_WORKSPACE_FOLLOW_DETACH=none \
  bash "$setup_tool" follow "${bargs[@]}" >"$work/stdout" 2>"$work/stderr" &
fpid=$!
for _ in $(seq 1 3000); do grep -q "watching the checks of PR" "$work/stderr" 2>/dev/null && break; sleep 0.1; done
expect "(the follower is watching its PR when the key disappears)" grep -q "watching the checks of PR" "$work/stderr"
rm -f "$missing_key"
rm -f "$bgh/hang"
rc=0
wait "$fpid" || rc=$?
expect "a follower whose key disappeared stops, saying why and how to unlock it" \
  bash -c '[ "$1" != 0 ] && tr -s " \n" "  " <"$2" | grep -qF "is gone (a restart empties \$XDG_RUNTIME_DIR, where it was unlocked); unlock it again: $3"' _ "$rc" "$work/stderr" "$unlock_key"
expect "... telling the notifier" grep -qx "TITLE Google Workspace setup: background phase stopped" "$work/notify.log"

echo
if [ "$fails" -ne 0 ]; then
  echo "test-google-workspace-domains: $fails FAILED"
  exit 1
fi
echo "test-google-workspace-domains: all passed"
