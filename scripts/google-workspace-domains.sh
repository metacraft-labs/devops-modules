#!/usr/bin/env bash
# Google Workspace domains: put a domain on the tenant as a domain alias, prove
# ownership through DNS, and switch its mail records to Google — every step of
# docs/Google-Workspace-Domains.md that has an API, as one tool.
#
#   google-workspace-domains onboard --domain D --parent P --data FILE
#                                    [--key KEY --subject USER] [--post-edit CMD]
#                                    [--base BRANCH] [--merge] [--no-pr]
#                                    [--mx PRIO:HOST[,PRIO:HOST…]] [--spf-drop HOST]…
#                                    [--spf-replace] [--dmarc-rua MAILBOX]
#                                    [--dns-timeout SECS] [--verify-timeout SECS]
#   google-workspace-domains status  (--domain D | --all) --data FILE [--key KEY --subject USER]
#
# --key/--subject (or $GOOGLE_WORKSPACE_KEY / $GOOGLE_WORKSPACE_SUBJECT): the
# decrypted service-account key with domain-wide delegation and the super admin
# it acts as (docs/Google-Workspace-Admin-API-Access.md). The delegation must
# include admin.directory.domain and siteverification; the error names the one
# that is missing. The key is passed to google-auth by path and never printed.
#
# FILE is the consumer's mail-auth data file, rendered by the Terranix helper
# terraform/cloudflare/mail-auth.nix (its header documents the contract). The
# domain must already be declared there with its zone (zone_id or zone_lookup).
#
# onboard, in order — each step is skipped when it is already done, so a re-run
# resumes wherever the last one stopped:
#   1. Directory API domainAliases.insert: D becomes a domain alias of P. A
#      domain the tenant already has (primary, secondary or alias) is left as is.
#   2. If D is not verified: Site Verification API webResource.getToken (DNS_TXT)
#      gives the TXT value proving ownership; it is appended to
#      .domains[D].google_verification, the hook runs, and that goes out as its
#      own PR (branch mail/<D>-verification) — commit in a temporary worktree,
#      wait for every check and workflow run of the head, merge with --merge at
#      that head, then wait until the zone's nameservers and then the public
#      resolvers serve the token.
#   3. webResource.insert asks Google to check the record; then the alias is
#      polled until the Directory API reports it verified.
#   4. Only then the mail records, in a SECOND PR (branch mail/<D>-records):
#      .mx = --mx (default 1:smtp.google.com), except that MX records that
#      all point at Google already (the legacy aspmx set) are kept unless --mx
#      is given; .spf gains include:_spf.google.com and keeps the includes
#      already there except each --spf-drop (or becomes just Google's with
#      --spf-replace, or when the domain has none); .dmarc is
#      set to p=none with rua=mailto:--dmarc-rua when the domain has none, and
#      kept otherwise. Google does not deliver mail for an alias before it is
#      verified, so an MX switched earlier would bounce the domain's mail.
#      Waits until MX, SPF and DMARC are served.
#   5. Prints what has no API: "Activate Gmail" for the alias in the Admin
#      console, and DKIM (google-workspace-dkim publish).
#
# The hook (--post-edit CMD) runs in the repository root after each edit with
# DOMAIN, PHASE (verification|records), DATA_FILE, and RECORD_ADDRESSES_ADDED /
# RECORD_ADDRESSES_REMOVED (newline-separated cloudflare_dns_record addresses
# the edit adds or drops, as the helper with default resource names renders
# them) exported — for a reviewed census, say.
#
# --no-pr edits FILE in place for the next step and stops: commit it yourself,
# and re-run once it is applied.
#
# $GOOGLE_WORKSPACE_DOMAINS_DNS_TIMEOUT and $GOOGLE_WORKSPACE_DOMAINS_VERIFY_TIMEOUT
# set the defaults of --dns-timeout (1800 s per DNS phase) and --verify-timeout
# (900 s).
#
# status: per domain, what the tenant knows (with --key/--subject) and what
# public DNS serves for MX, SPF, DMARC, each verification token and each DKIM
# selector, against FILE. Non-zero when anything FILE declares is not served.
# shellcheck source-path=SCRIPTDIR
# jq programs are single-quoted on purpose:
# shellcheck disable=SC2016
set -euo pipefail

prog=google-workspace-domains
here="$(dirname -- "${BASH_SOURCE[0]}")"
lib="${GOOGLE_WORKSPACE_TOOLS_LIB:-$here/lib}"
# shellcheck source=lib/pr-publish.sh
. "$lib/pr-publish.sh"
read -r -a api_cmd <<<"${GOOGLE_WORKSPACE_DOMAINS_API:-python3 $here/google-workspace-domains-api.py}"

usage="usage: $prog onboard|status ... (see the header of this script, or --help)"
cmd="${1:-}"
[ -n "$cmd" ] || die "$usage"
shift
case "$cmd" in -h | --help) set -- --help ;; esac

domain="" parent="" data="" post_edit="" base="" merge=0 no_pr=0 all=0
key="${GOOGLE_WORKSPACE_KEY:-}" subject="${GOOGLE_WORKSPACE_SUBJECT:-}"
mx_spec="1:smtp.google.com" mx_explicit=0 spf_drop=() spf_replace=0 dmarc_rua=""
dns_timeout="${GOOGLE_WORKSPACE_DOMAINS_DNS_TIMEOUT:-1800}" verify_timeout="${GOOGLE_WORKSPACE_DOMAINS_VERIFY_TIMEOUT:-900}"
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) domain="${2:?--domain needs a value}"; shift 2 ;;
    --parent) parent="${2:?--parent needs a value}"; shift 2 ;;
    --data) data="${2:?--data needs a value}"; shift 2 ;;
    --key) key="${2:?--key needs a value}"; shift 2 ;;
    --subject) subject="${2:?--subject needs a value}"; shift 2 ;;
    --post-edit) post_edit="${2:?--post-edit needs a value}"; shift 2 ;;
    --base) base="${2:?--base needs a value}"; shift 2 ;;
    --merge) merge=1; shift ;;
    --no-pr) no_pr=1; shift ;;
    --all) all=1; shift ;;
    --mx) mx_spec="${2:?--mx needs a value}"; mx_explicit=1; shift 2 ;;
    --spf-drop) spf_drop+=("${2:?--spf-drop needs a value}"); shift 2 ;;
    --spf-replace) spf_replace=1; shift ;;
    --dmarc-rua) dmarc_rua="${2:?--dmarc-rua needs a value}"; shift 2 ;;
    --dns-timeout) dns_timeout="${2:?--dns-timeout needs a value}"; shift 2 ;;
    --verify-timeout) verify_timeout="${2:?--verify-timeout needs a value}"; shift 2 ;;
    -h | --help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1 ($usage)" ;;
  esac
done

read -r -a resolvers <<<"${GOOGLE_WORKSPACE_DKIM_RESOLVERS:-1.1.1.1 8.8.8.8}"
dns_interval="${GOOGLE_WORKSPACE_DKIM_DNS_INTERVAL:-30}"
verify_interval="${GOOGLE_WORKSPACE_DOMAINS_VERIFY_INTERVAL:-30}"

domain_re='^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$'
host_re='^(([a-z0-9_]|[a-z0-9_][a-z0-9_-]*[a-z0-9])\.)+[a-z]{2,63}$'
[[ $dns_timeout =~ ^[0-9]+$ ]] || die "--dns-timeout must be a number of seconds"
[[ $verify_timeout =~ ^[0-9]+$ ]] || die "--verify-timeout must be a number of seconds"
if [ -n "$domain" ]; then
  domain="${domain,,}"
  [[ $domain =~ $domain_re ]] || die "\"$domain\" is not a domain name"
fi
if [ -n "$parent" ]; then
  parent="${parent,,}"
  [[ $parent =~ $domain_re ]] || die "\"$parent\" is not a domain name"
fi

# --mx 1:smtp.google.com[,5:alt1.aspmx.l.google.com…] -> a JSON list.
mx_json() {
  local IFS=, item p h out="[]"
  for item in $mx_spec; do
    p="${item%%:*}" h="${item#*:}"
    h="${h%.}"
    [[ $p =~ ^[0-9]+$ ]] && [ "$p" -le 65535 ] && [[ ${h,,} =~ $host_re ]] ||
      die "--mx: \"$item\" is not PRIORITY:HOST"
    out="$(jq -c --argjson p "$p" --arg h "${h,,}" '. + [{priority: $p, host: $h}]' <<<"$out")"
  done
  [ "$out" != "[]" ] || die "--mx is empty"
  printf '%s' "$out"
}

for h in "${spf_drop[@]}"; do
  [[ $h =~ $host_re ]] || die "--spf-drop: \"$h\" is not a host name"
done
if [ -n "$dmarc_rua" ]; then
  dmarc_rua="${dmarc_rua#mailto:}"
  [[ $dmarc_rua =~ ^[a-z0-9._+-]+@([a-z0-9-]+\.)+[a-z]{2,63}$ ]] || die "--dmarc-rua: \"$dmarc_rua\" is not a mailbox"
fi

jqm() { jq -L "$lib" "$@"; }

# ── Google API ───────────────────────────────────────────────────────────────

need_credentials() {
  [ -n "$key" ] || die "--key (or \$GOOGLE_WORKSPACE_KEY) is required: the decrypted service-account key"
  [ -r "$key" ] || die "cannot read the service-account key $key"
  [ -n "$subject" ] || die "--subject (or \$GOOGLE_WORKSPACE_SUBJECT) is required: the super admin the service account acts as"
}
api() { "${api_cmd[@]}" --key "$key" --subject "$subject" "$@"; }

# ── data file ────────────────────────────────────────────────────────────────

require_declared() {
  local f="$1"
  jq -e '.version == 1 or .version == 2' "$f" >/dev/null 2>&1 ||
    die "$f is not a mail-auth data file (expected \"version\": 1 or 2)"
  if ! jq -e --arg d "$domain" '.domains[$d] | (.zone_id // .zone_lookup) | type == "string"' "$f" >/dev/null; then
    cat >&2 <<EOF
$prog: $domain is not declared in $f.
  Declare the domain and the Cloudflare zone that holds it first, in its own
  reviewed change — a zone id (the zone's Overview page in the dashboard):

    jq --arg d $domain --arg z <ZONE_ID> \\
      '.version = 2 | .domains[\$d] = {zone_id: \$z, dkim: {}}' $f > $f.new && mv $f.new $f

  or, for a zone the root resolves with data "cloudflare_zone" "<key>":

    jq --arg d $domain --arg k <KEY> \\
      '.version = 2 | .domains[\$d] = {zone_lookup: \$k, dkim: {}}' $f > $f.new && mv $f.new $f

  then re-run this command.
EOF
    exit 1
  fi
}

# The edits, as jq programs over the whole file. Each is idempotent, so "the
# file already carries the change" is "the edit changes nothing".
verification_prog='.version = 2
  | .domains[$d].google_verification = (
      (.domains[$d].google_verification // []) as $l
      | if any($l[]; . == $t) then $l else $l + [$t] end)'

records_prog='.version = 2
  | .domains[$d] |= (
      .mx = (
        if $mx_explicit then $mx
        elif ((.mx // []) | length > 0 and all(.[]; .host | test("(^|[.])google[.]com$"))) then .mx
        else $mx end)
    | .spf = (
        if $replace or .spf == null then {include: ["_spf.google.com"], all: "~all"}
        else .spf
          | .include = (
              [ (.include // [])[] | select(. as $h | $drop | index([$h]) | not) ] + ["_spf.google.com"]
              | reduce .[] as $h ([]; if any(.[]; . == $h) then . else . + [$h] end))
          | .all = (.all // "~all")
        end)
    | .dmarc = (.dmarc // ({p: "none"} + (if $rua == "" then {} else {rua: ["mailto:" + $rua]} end))))'

verification_token=""
apply_jq() { # FILE PROGRAM -> the edited JSON on stdout
  local f="$1" prog_text="$2" drop
  drop="$(printf '%s\n' "${spf_drop[@]}" | jq -R . | jq -sc 'map(select(. != ""))')"
  jq --indent 2 --arg d "$domain" --arg t "$verification_token" --argjson mx "${mx_list:-[]}" \
    --argjson mx_explicit "$([ "$mx_explicit" = 1 ] && echo true || echo false)" \
    --argjson drop "$drop" --argjson replace "$([ "$spf_replace" = 1 ] && echo true || echo false)" \
    --arg rua "$dmarc_rua" "$prog_text" "$f"
}

phase="" phase_prog=""
phase_state() { # FILE -> "same" when the edit would change nothing
  local f="$1" cur
  cur="$(cat "$f")"
  if [ "$(apply_jq <(printf '%s' "$cur") "$phase_prog" | jq -S .)" = "$(jq -S . <<<"$cur")" ]; then
    echo same
  else
    echo different
  fi
}

# Edits FILE in the repository root ROOT and runs the hook. 0 changed, 3 not.
phase_edit() {
  local f="$1" root="$2" tmp before_addr after_addr added removed
  require_declared "$f"
  if [ "$(phase_state "$f")" = same ]; then
    say "$f already carries the $phase change for $domain; nothing to edit"
    return 3
  fi
  before_addr="$(jqm -r 'include "mail-auth"; mail_auth_addresses' "$f" | sort)"
  tmp="$(mktemp "$f.XXXXXX")"
  apply_jq "$f" "$phase_prog" >"$tmp"
  chmod --reference="$f" "$tmp" 2>/dev/null || true
  mv "$tmp" "$f"
  after_addr="$(jqm -r 'include "mail-auth"; mail_auth_addresses' "$f" | sort)"
  added="$(comm -13 <(printf '%s\n' "$before_addr") <(printf '%s\n' "$after_addr") | sed '/^$/d')"
  removed="$(comm -23 <(printf '%s\n' "$before_addr") <(printf '%s\n' "$after_addr") | sed '/^$/d')"
  say "set the $phase records of $domain in $f"
  if [ -n "$post_edit" ]; then
    say "running the post-edit hook: $post_edit"
    (cd "$root" && DOMAIN="$domain" PHASE="$phase" DATA_FILE="$f" \
      RECORD_ADDRESSES_ADDED="$added" RECORD_ADDRESSES_REMOVED="$removed" bash -c "$post_edit") ||
      die "the post-edit hook failed"
  fi
}

# ── DNS matchers ─────────────────────────────────────────────────────────────

# (Captured before grep -q: under pipefail, grep -q exiting at the first match
# would SIGPIPE the lookup and fail the pipeline.)
token_served() {
  local got
  got="$(lookup_txt "$domain" "$1")" || return 1
  grep -qxF -- "$verification_token" <<<"$got"
}
token_answer() { lookup_txt "$domain" "$1" | grep '^google-site-verification=' | paste -sd' ' -; }

want_mx="" want_spf="" want_dmarc=""
records_served() {
  local got
  got="$(lookup_mx "$domain" "$1")" || return 1
  [ "$got" = "$want_mx" ] || return 1
  got="$(lookup_txt "$domain" "$1" | grep '^v=spf1' || true)"
  [ "$got" = "$want_spf" ] || return 1
  got="$(lookup_txt "_dmarc.$domain" "$1" | grep '^v=DMARC1' || true)"
  [ "$got" = "$want_dmarc" ]
}
records_answer() {
  printf 'MX %s | %s | %s' "$(lookup_mx "$domain" "$1" | paste -sd, -)" \
    "$(lookup_txt "$domain" "$1" | grep '^v=spf1' | paste -sd' ' -)" \
    "$(lookup_txt "_dmarc.$domain" "$1" | grep '^v=DMARC1' | paste -sd' ' -)"
}

# ── onboard ──────────────────────────────────────────────────────────────────

data_abs="" root="" rel=""
locate_data() {
  [ -n "$data" ] || die "--data is required (the mail-auth JSON data file)"
  [ -f "$data" ] || die "no such data file: $data"
  data_abs="$(cd "$(dirname "$data")" && pwd)/$(basename "$data")"
  if root="$(git -C "$(dirname "$data_abs")" rev-parse --show-toplevel 2>/dev/null)"; then
    :
  elif [ "$no_pr" = 1 ] || [ "$cmd" = status ]; then
    root="$(dirname "$data_abs")"
  else
    die "$data is not inside a git repository (use --no-pr to only edit the file)"
  fi
  rel="${data_abs#"$root"/}"
}

# Runs one phase: in place with --no-pr (then stops), else as a PR.
run_phase() {
  local branch="$1" title="$2" body="$3"
  if [ "$no_pr" = 1 ]; then
    local rc=0
    phase_edit "$data_abs" "$root" || rc=$?
    # Already in the file: it was edited by an earlier --no-pr run, so go on
    # to the DNS wait (which tells whether it has been applied).
    [ "$rc" = 3 ] && return 0
    [ "$rc" = 0 ] || exit "$rc"
    say "(--no-pr) edited $rel in place for the $phase step. Commit it, get it applied, and re-run this command to continue."
    exit 0
  fi
  pr_subject="the $phase records of $domain"
  pr_mismatch_msg="the open PR ($branch) carries different $phase records for $domain than this run would write. Close it and delete the branch, then re-run"
  publish_pr "$root" "$rel" "$branch" "$title" "$body" "$title

$body" phase_state phase_edit
}

state_field() { jq -r ".$1" <<<"$2"; }

cmd_onboard() {
  [ -n "$domain" ] || die "--domain is required"
  [ -n "$parent" ] || die "--parent is required (the tenant domain the alias belongs to)"
  [ "$domain" != "$parent" ] || die "--domain and --parent are the same domain"
  locate_data
  require_declared "$data_abs"
  need_credentials
  mx_list="$(mx_json)"

  # 1. the alias
  local st kind verified start now
  st="$(api alias "$domain" "$parent")" || exit 1
  kind="$(state_field kind "$st")"
  verified="$(state_field verified "$st")"
  case "$kind" in
    alias) say "$domain is a domain alias of $(state_field parent "$st") (verified: $verified)" ;;
    primary | secondary) say "$domain is already the tenant's $kind domain (verified: $verified); no alias is added" ;;
    *) die "the alias was not created (state: $st)" ;;
  esac

  # 2-3. ownership
  if [ "$verified" != true ]; then
    verification_token="$(api token "$domain")" || exit 1
    say "verification TXT for $domain: $verification_token"
    phase=verification phase_prog="$verification_prog"
    run_phase "mail/$domain-verification" "dns: Google site verification for $domain" \
      "Publishes the TXT record that proves ownership of \`$domain\` to Google (Site Verification API, DNS_TXT), so the domain can be verified as a domain alias of \`$parent\` on the Workspace tenant.

Opened by \`google-workspace-domains onboard\`. The MX/SPF/DMARC switch follows in a separate PR once Google reports the domain verified."
    wait_until_served "$domain" "the verification TXT at $domain" token_served token_answer \
      "'$prog status --domain $domain --data $data' to see what is published"
    say "asking Google to verify $domain"
    api verify "$domain" >/dev/null || exit 1
    start="$(date +%s)"
    while :; do
      st="$(api state "$domain")" || exit 1
      [ "$(state_field verified "$st")" = true ] && break
      now="$(date +%s)"
      [ $((now - start)) -lt "$verify_timeout" ] ||
        die "Google accepted the verification but the Directory API still reports $domain unverified after ${verify_timeout}s; re-run to keep waiting"
      say "  waiting for the Directory API to report $domain verified"
      sleep "$verify_interval"
    done
    say "$domain is verified"
  fi

  # 4. the mail records
  phase=records phase_prog="$records_prog"
  run_phase "mail/$domain-records" "dns: mail records for $domain (Google Workspace)" \
    "Switches \`$domain\`'s MX to Google Workspace ($(jq -r 'map("\(.priority) \(.host)") | join(", ")' <<<"$mx_list")) and sets its SPF and DMARC records, now that the domain is a verified domain alias of \`$parent\`.

Mail for $domain is delivered to Google from the moment this is applied; any other mail server that received it stops receiving.

Opened by \`google-workspace-domains onboard\`."
  local served
  if [ "$no_pr" = 1 ]; then
    served="$(cat "$data_abs")"
  else
    git -C "$root" fetch --quiet origin "$base"
    served="$(git -C "$root" show "origin/$base:$rel")"
  fi
  want_mx="$(jqm -r --arg d "$domain" 'include "mail-auth"; mail_auth_mx($d)' <<<"$served" | LC_ALL=C sort)"
  want_spf="$(jqm -r --arg d "$domain" 'include "mail-auth"; mail_auth_spf($d) // empty' <<<"$served")"
  want_dmarc="$(jqm -r --arg d "$domain" 'include "mail-auth"; mail_auth_dmarc($d) // empty' <<<"$served")"
  wait_until_served "$domain" "the MX, SPF and DMARC records of $domain" records_served records_answer \
    "'$prog status --domain $domain --data $data' to see what is published"

  # 5. what has no API
  cat >&2 <<EOF

$prog: $domain is on the tenant and its mail records are live. Left to do by hand:
$( [ "$kind" = alias ] && cat <<EOT
  1. Admin console > Account > Domains > Manage domains
     (https://admin.google.com/ac/domains/manage): find $domain and, if it
     offers "Activate Gmail", click it (Google checks the MX records it now
     finds and starts accepting mail for the alias).
EOT
)
  2. DKIM, so mail sent as @$domain is signed by $domain:
       google-workspace-dkim publish --domain $domain --data $data …
     (the key is generated in the console; Google has no API for it).
  3. Users send as @$domain after adding it as a "Send mail as" address
     (Gmail settings > Accounts), or an admin does it with the Gmail API.
Then: $prog status --domain $domain --data $data
EOF
}

# ── status ───────────────────────────────────────────────────────────────────

status_domain() {
  local d="$1" r="${resolvers[0]}" st got want sel status=0 t
  domain="$d"
  echo "== $d"
  if [ -n "$key" ] && [ -n "$subject" ]; then
    if st="$(api state "$d" 2>/dev/null)"; then
      echo "   tenant   $(state_field kind "$st")$( [ "$(state_field kind "$st")" = alias ] && echo " of $(state_field parent "$st")"), verified: $(state_field verified "$st")"
      [ "$(state_field verified "$st")" = true ] || status=1
    else
      echo "   tenant   <the API call failed; run onboard to see why>"
      status=1
    fi
  else
    echo "   tenant   <not asked: pass --key and --subject>"
  fi
  line() { # what want got
    if [ -z "$2" ]; then
      printf '   %-8s not declared (serves: %s)\n' "$1" "${3:-<nothing>}"
    elif [ "$2" = "$3" ]; then
      printf '   %-8s OK  %s\n' "$1" "$3"
    else
      printf '   %-8s DIFFERS: declared %s, serves %s\n' "$1" "$2" "${3:-<nothing>}"
      status=1
    fi
  }
  want="$(jqm -r --arg d "$d" 'include "mail-auth"; mail_auth_mx($d)' "$data_abs" | LC_ALL=C sort | paste -sd, -)"
  got="$(lookup_mx "$d" "$r" | paste -sd, -)"
  line MX "$want" "$got"
  want="$(jqm -r --arg d "$d" 'include "mail-auth"; mail_auth_spf($d) // empty' "$data_abs")"
  got="$(lookup_txt "$d" "$r" | grep '^v=spf1' | paste -sd'|' - || true)"
  line SPF "$want" "$got"
  want="$(jqm -r --arg d "$d" 'include "mail-auth"; mail_auth_dmarc($d) // empty' "$data_abs")"
  got="$(lookup_txt "_dmarc.$d" "$r" | grep '^v=DMARC1' | paste -sd'|' - || true)"
  line DMARC "$want" "$got"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    got="$(lookup_txt "$d" "$r" || true)"
    if grep -qxF -- "$t" <<<"$got"; then got="$t"; else got=""; fi
    line VERIFY "$t" "$got"
  done < <(jq -r --arg d "$d" '(.domains[$d].google_verification // [])[]' "$data_abs")
  while IFS= read -r sel; do
    [ -n "$sel" ] || continue
    want="$(jq -r --arg d "$d" --arg s "$sel" '.domains[$d].dkim[$s]' "$data_abs")"
    got="$(lookup_txt "$sel._domainkey.$d" "$r" | paste -sd'|' - || true)"
    if [ "$want" = "$got" ]; then
      line "DKIM" "$sel" "$sel"
    else
      line "DKIM" "$sel ${want:0:40}…" "${got:+${got:0:40}…}"
    fi
  done < <(jq -r --arg d "$d" '(.domains[$d].dkim // {}) | keys[]' "$data_abs")
  return "$status"
}

cmd_status() {
  locate_data
  local ds=() d status=0
  if [ "$all" = 1 ]; then
    mapfile -t ds < <(jq -r '.domains | keys[]' "$data_abs")
  else
    [ -n "$domain" ] || die "--domain or --all is required"
    require_declared "$data_abs"
    ds=("$domain")
  fi
  say "DNS as $(printf '%s' "${resolvers[0]}") serves it, against $data"
  for d in "${ds[@]}"; do
    status_domain "$d" || status=1
  done
  if [ "$status" = 0 ]; then
    say "OK: everything declared is served"
  else
    say "some declared records are not served (or a domain is not verified)"
  fi
  return "$status"
}

case "$cmd" in
  onboard) cmd_onboard ;;
  status) cmd_status ;;
  *) die "$usage" ;;
esac
