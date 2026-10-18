#!/usr/bin/env bash
# Google Workspace domains: put a domain on the tenant — as a SECONDARY domain or
# a domain ALIAS — prove ownership through DNS, switch its mail records to
# Google, and give users addresses there that they can send from. Every step of
# docs/Google-Workspace-Domains.md that has an API, as one tool.
#
#   google-workspace-domains onboard --domain D --data FILE [--kind secondary|alias] [--parent P]
#                                    [--key KEY --subject ADMIN] [--post-edit CMD]
#                                    [--base BRANCH] [--merge] [--no-pr]
#                                    [--mx PRIO:HOST[,PRIO:HOST…]] [--spf-drop HOST]…
#                                    [--spf-replace] [--dmarc-rua MAILBOX] [--tls-rpt-rua MAILBOX]
#                                    [--dns-timeout SECS] [--verify-timeout SECS]
#   google-workspace-domains status  (--domain D | --all) --data FILE [--key KEY --subject ADMIN]
#                                    [--user USER [--local L]…] [--table]
#   google-workspace-domains user-addresses (--user USER | --all) (--domain D | --all-domains)
#                                    --data FILE [--local L]… [--key KEY --subject ADMIN]
#   google-workspace-domains dmarc-group --group GROUP [--guide] [--key KEY --subject ADMIN]
#   google-workspace-domains scopes  [--scopes S,S,…] [--guide] [--key KEY --subject ADMIN]
#   google-workspace-domains edit    --domain D --data FILE (--phase verification --token T |
#                                    --phase records [--mx …] [--spf-drop H]… [--spf-replace]
#                                    [--dmarc-rua M] [--tls-rpt-rua M]) [--dry-run]
#   google-workspace-domains registrar-debris --domain D [--data FILE] [--zone-id Z]
#                                    [--token-file F] [--unlock CMD] [--lock CMD]
#                                    [--parking-ip IP]… [--debris-ns PATTERN]…
#                                    [--allow-ns PATTERN]… [--names N,N,…] [--delete]
#
# --key/--subject (or $GOOGLE_WORKSPACE_KEY / $GOOGLE_WORKSPACE_SUBJECT): the
# decrypted service-account key with domain-wide delegation and the super admin
# it acts as (docs/Google-Workspace-Admin-API-Access.md). Each call mints a
# token for exactly the scope it needs, so an error names the missing one;
# `scopes` checks them all at once. The key is passed to google-auth by path
# and never printed.
#
# FILE is the consumer's mail-auth data file, rendered by the Terranix helper
# terraform/cloudflare/mail-auth.nix (its header documents the contract). The
# domain must already be declared there with its zone (zone_id or zone_lookup);
# a domain declared "zone_pending": true (DNS not in Cloudflare yet) is skipped
# by `status` and refused by `onboard`.
#
# THE KIND of a domain is --kind (with --parent for an alias), else the data's
# .domains[D].google {kind, parent}; for data that says nothing, a --parent
# alone means an alias (the original behaviour). "secondary": users can be
# created with a primary address there, nobody receives one automatically.
# "alias": every user of the parent automatically receives mail at the same
# local part here. "primary": the tenant's own domain; only its records are
# managed.
#
# onboard, in order — each step is skipped when it is already done, so a re-run
# resumes wherever the last one stopped:
#   1. Directory API domains.insert (secondary) or domainAliases.insert (alias,
#      of P). A domain the tenant already has with the wanted kind is left as
#      is; one it has with the OTHER kind is refused (Google cannot convert).
#   2. If D is not verified: Site Verification API webResource.getToken (DNS_TXT)
#      gives the TXT value proving ownership; it is appended to
#      .domains[D].google_verification, the hook runs, and that goes out as its
#      own PR (branch mail/<D>-verification) — commit in a temporary worktree,
#      wait for every check and workflow run of the head, merge with --merge at
#      that head, then wait until the zone's nameservers and then the public
#      resolvers serve the token.
#   3. webResource.insert asks Google to check the record; then the domain is
#      polled (domains.get / domainAliases.get) until it is reported verified.
#   4. Only then — and for an alias only once its parent is verified too — the
#      mail records, in a SECOND PR (branch mail/<D>-records):
#      .mx = --mx (default 1:smtp.google.com), except that MX records that
#      all point at Google already (the legacy aspmx set) are kept unless --mx
#      is given; .spf gains include:_spf.google.com and keeps the includes
#      already there except each --spf-drop (or becomes just Google's with
#      --spf-replace or the data's google.spf_replace, or when the domain has
#      none); .dmarc is set to p=none with rua=mailto:--dmarc-rua when the
#      domain has none, and kept otherwise; .tls_rpt is set to
#      rua=mailto:--tls-rpt-rua (default: the --dmarc-rua mailbox) when the
#      domain has none. Google does not deliver mail for a domain before it is
#      verified, so an MX switched earlier would bounce the domain's mail.
#      Waits until MX, SPF, DMARC and TLS-RPT are served.
#   5. Prints what has no API: "Activate Gmail" in the Admin console, DKIM
#      (google-workspace-dkim publish) and the users' addresses.
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
# status: per domain, its kind (data and tenant, with --key/--subject; the
# read-only admin.directory.domain.readonly scope suffices), and what public DNS
# serves for MX, SPF, DMARC, TLS-RPT, MTA-STS, each verification token and each
# DKIM selector, against FILE. An MX that Cloudflare serves as its proxied-MX
# substitute (_dc-mx.<hex>.<domain>, for a declared mail host in the zone whose
# A record is proxied) is reported OK and labelled. With --user, also the
# user's addresses at each domain and their Gmail send-as state. --table prints
# one line per domain. Non-zero when anything FILE declares is not served.
#
# user-addresses: for each USER (--all: every user in FILE's google_users), at
# each SECONDARY domain, ensures the user aliases <L>@<domain> for every local
# part L (--local, else google_users[USER].local_parts, else USER's own local
# part) — Directory users.aliases.insert, scope admin.directory.user — and at
# each ALIAS domain takes the user's addresses at the parent, which Google
# mirrors automatically. For every resulting address it ensures a Gmail send-as
# entry (users.settings.sendAs.create as USER, treatAsAlias, scope
# gmail.settings.sharing). Google marks the user's own addresses "accepted" at
# once; "pending" means a confirmation mail went to that address. Domains not
# verified on the tenant yet are skipped. Exit 0 when every address is in
# place and accepted, 2 when something is pending or was skipped.
#
# dmarc-group: lets GROUP (the DMARC/TLS-RPT report mailbox) receive mail from
# outside the organisation — Groups Settings API whoCanPostMessage =
# ANYONE_CAN_POST, and spamModerationLevel = ALLOW and messageModerationLevel =
# MODERATE_NONE so that no report waits in a moderation queue; scope
# apps.groups.settings.
#
# registrar-debris: what a domain transferred in (or a zone copied from the old
# registrar's DNS) can carry that shadows or breaks the records we publish —
#   - NS DELEGATIONS of names inside the zone to nameservers that are not the
#     zone's own: a registrar that suspends a domain (unverified WHOIS
#     contact, say) may delegate _dmarc, _domainkey, www, mail, … to its own
#     servers, and a resolver then never sees our TXT/MX records there;
#   - A/AAAA records pointing at a registrar's PARKING address.
# With a Cloudflare API token (--token-file F, or $CLOUDFLARE_API_TOKEN; a
# read-only one suffices to list) every record of the zone is examined (the
# zone is --zone-id, the data's zone_id, or looked up by name); without one,
# public DNS is probed for the names in --names (default: the apex, www, a
# random name for a wildcard, and the names mail records use). Known debris is
# marked as such: nameservers matching --debris-ns (default: the suspension
# servers *.namecheap.com) and addresses in --parking-ip (default
# 198.54.117.242, Namecheap's parking); --allow-ns PATTERN accepts an
# intentional delegation. Exit 0 when nothing is found, 2 when something is.
#
# --delete (Cloudflare source only): shows the records, asks for "yes", and
# deletes them through the API with a token that may edit DNS — the file
# --token-file names, which --unlock CMD creates (run when the file is not
# there) and --lock CMD removes again afterwards, whatever happens. Then it
# lists again. A record the consumer's Terraform declares must instead be
# removed there (or Terraform recreates it); the debris a registrar leaves is
# normally in no Terraform, which is why the API is the tool here.
# $CLOUDFLARE_API_BASE redirects the API (tests).
#
# scopes: mints a token for every scope in the list (default: every scope these
# tools use) and reports which the delegation grants; for the missing ones it
# prints the client id and the complete replacement scope line for the Admin
# console. Exit 3 while any is missing. With --guide, waits for the console
# edit and checks again until all are granted.
# shellcheck source-path=SCRIPTDIR
# jq programs are single-quoted on purpose:
# shellcheck disable=SC2016
set -euo pipefail

prog=google-workspace-domains
here="$(dirname -- "${BASH_SOURCE[0]}")"
lib="${GOOGLE_WORKSPACE_TOOLS_LIB:-$here/lib}"
# shellcheck source=lib/pr-publish.sh
. "$lib/pr-publish.sh"
# shellcheck source=lib/guide.sh
. "$lib/guide.sh"
read -r -a api_cmd <<<"${GOOGLE_WORKSPACE_DOMAINS_API:-python3 $here/google-workspace-domains-api.py}"

usage="usage: $prog onboard|status|user-addresses|dmarc-group|scopes|edit|registrar-debris ... (see the header of this script, or --help)"
cmd="${1:-}"
[ -n "$cmd" ] || die "$usage"
shift
case "$cmd" in -h | --help) set -- --help ;; esac

# Every scope these tools use, in the order the guidance lists them.
tool_scopes="admin.directory.domain,admin.directory.domain.readonly,siteverification,admin.directory.user,gmail.settings.basic,gmail.settings.sharing,gmail.send,gmail.metadata,apps.groups.settings"

domain="" parent="" kind_flag="" data="" post_edit="" base="" merge=0 no_pr=0 all=0 all_domains=0
key="${GOOGLE_WORKSPACE_KEY:-}" subject="${GOOGLE_WORKSPACE_SUBJECT:-}"
mx_spec="1:smtp.google.com" mx_explicit=0 spf_drop=() spf_replace=0 dmarc_rua="" tls_rpt_rua="" tls_rpt_given=0
dns_timeout="${GOOGLE_WORKSPACE_DOMAINS_DNS_TIMEOUT:-1800}" verify_timeout="${GOOGLE_WORKSPACE_DOMAINS_VERIFY_TIMEOUT:-900}"
user="" locals=() table=0 group="" guide=0 scope_list="$tool_scopes"
edit_phase="" edit_token="" dry_run=0
zone_id_flag="" token_file="" unlock_cmd="" lock_cmd="" parking_ips=() debris_ns=() allow_ns=() probe_names="" delete=0
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) domain="${2:?--domain needs a value}"; shift 2 ;;
    --parent) parent="${2:?--parent needs a value}"; shift 2 ;;
    --kind) kind_flag="${2:?--kind needs a value}"; shift 2 ;;
    --data) data="${2:?--data needs a value}"; shift 2 ;;
    --key) key="${2:?--key needs a value}"; shift 2 ;;
    --subject) subject="${2:?--subject needs a value}"; shift 2 ;;
    --post-edit) post_edit="${2:?--post-edit needs a value}"; shift 2 ;;
    --base) base="${2:?--base needs a value}"; shift 2 ;;
    --merge) merge=1; shift ;;
    --no-pr) no_pr=1; shift ;;
    --all) all=1; shift ;;
    --all-domains) all_domains=1; shift ;;
    --mx) mx_spec="${2:?--mx needs a value}"; mx_explicit=1; shift 2 ;;
    --spf-drop) spf_drop+=("${2:?--spf-drop needs a value}"); shift 2 ;;
    --spf-replace) spf_replace=1; shift ;;
    --dmarc-rua) dmarc_rua="${2:?--dmarc-rua needs a value}"; shift 2 ;;
    --tls-rpt-rua) tls_rpt_rua="${2:?--tls-rpt-rua needs a value}"; tls_rpt_given=1; shift 2 ;;
    --dns-timeout) dns_timeout="${2:?--dns-timeout needs a value}"; shift 2 ;;
    --verify-timeout) verify_timeout="${2:?--verify-timeout needs a value}"; shift 2 ;;
    --user) user="${2:?--user needs a value}"; shift 2 ;;
    --local) locals+=("${2:?--local needs a value}"); shift 2 ;;
    --table) table=1; shift ;;
    --group) group="${2:?--group needs a value}"; shift 2 ;;
    --guide) guide=1; shift ;;
    --scopes) scope_list="${2:?--scopes needs a value}"; shift 2 ;;
    --phase) edit_phase="${2:?--phase needs a value}"; shift 2 ;;
    --token) edit_token="${2:?--token needs a value}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --zone-id) zone_id_flag="${2:?--zone-id needs a value}"; shift 2 ;;
    --token-file) token_file="${2:?--token-file needs a value}"; shift 2 ;;
    --unlock) unlock_cmd="${2:?--unlock needs a value}"; shift 2 ;;
    --lock) lock_cmd="${2:?--lock needs a value}"; shift 2 ;;
    --parking-ip) parking_ips+=("${2:?--parking-ip needs a value}"); shift 2 ;;
    --debris-ns) debris_ns+=("${2:?--debris-ns needs a value}"); shift 2 ;;
    --allow-ns) allow_ns+=("${2:?--allow-ns needs a value}"); shift 2 ;;
    --names) probe_names="${2:?--names needs a value}"; shift 2 ;;
    --delete) delete=1; shift ;;
    -h | --help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1 ($usage)" ;;
  esac
done

read -r -a resolvers <<<"${GOOGLE_WORKSPACE_DKIM_RESOLVERS:-1.1.1.1 8.8.8.8}"
dns_interval="${GOOGLE_WORKSPACE_DKIM_DNS_INTERVAL:-30}"
verify_interval="${GOOGLE_WORKSPACE_DOMAINS_VERIFY_INTERVAL:-30}"

domain_re='^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$'
host_re='^(([a-z0-9_]|[a-z0-9_][a-z0-9_-]*[a-z0-9])\.)+[a-z]{2,63}$'
mailbox_re='^[a-z0-9._+-]+@([a-z0-9-]+\.)+[a-z]{2,63}$'
local_re='^[a-z0-9]([a-z0-9._+-]*[a-z0-9])?$'
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
case "$kind_flag" in "" | secondary | alias) ;; *) die "--kind must be secondary or alias" ;; esac
if [ -n "$user" ]; then
  user="${user,,}"
  [[ $user =~ $mailbox_re ]] || die "--user: \"$user\" is not an email address"
fi
for l in "${locals[@]}"; do
  [[ $l =~ $local_re ]] || die "--local: \"$l\" is not a lowercase local part"
done

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
  [[ $dmarc_rua =~ $mailbox_re ]] || die "--dmarc-rua: \"$dmarc_rua\" is not a mailbox"
fi
if [ -n "$tls_rpt_rua" ]; then
  tls_rpt_rua="${tls_rpt_rua#mailto:}"
  [[ $tls_rpt_rua =~ $mailbox_re ]] || die "--tls-rpt-rua: \"$tls_rpt_rua\" is not a mailbox"
fi
[ "$tls_rpt_given" = 1 ] || tls_rpt_rua="$dmarc_rua"

jqm() { jq -L "$lib" "$@"; }

# ── Google API ───────────────────────────────────────────────────────────────

need_credentials() {
  [ -n "$key" ] || die "--key (or \$GOOGLE_WORKSPACE_KEY) is required: the decrypted service-account key"
  [ -r "$key" ] || die "cannot read the service-account key $key"
  [ -n "$subject" ] || die "--subject (or \$GOOGLE_WORKSPACE_SUBJECT) is required: the super admin the service account acts as"
}
api() { "${api_cmd[@]}" --key "$key" --subject "$subject" "$@"; }

# ── data file ────────────────────────────────────────────────────────────────

is_pending() { jq -e --arg d "$1" '.domains[$d].zone_pending == true' "$2" >/dev/null 2>&1; }

require_declared() {
  local f="$1"
  jq -e '.version == 1 or .version == 2' "$f" >/dev/null 2>&1 ||
    die "$f is not a mail-auth data file (expected \"version\": 1 or 2)"
  if is_pending "$domain" "$f"; then
    die "$domain is declared with \"zone_pending\": true in $f: its DNS is not in a Cloudflare zone yet, so nothing can be published for it. Once the zone exists, replace zone_pending with its zone_id (or zone_lookup) in a reviewed change, then re-run."
  fi
  if ! jq -e --arg d "$domain" '.domains[$d] | (.zone_id // .zone_lookup) | type == "string"' "$f" >/dev/null; then
    cat >&2 <<EOF
$prog: $domain is not declared in $f.
  Declare the domain and the Cloudflare zone that holds it first, in its own
  reviewed change — a zone id (the zone's Overview page in the dashboard):

    jq --arg d $domain --arg z <ZONE_ID> \\
      '.version = 2 | .domains[\$d] = {zone_id: \$z, dkim: {}, google: {kind: "secondary"}}' $f > $f.new && mv $f.new $f

  or, for a zone the root resolves with data "cloudflare_zone" "<key>":

    jq --arg d $domain --arg k <KEY> \\
      '.version = 2 | .domains[\$d] = {zone_lookup: \$k, dkim: {}, google: {kind: "secondary"}}' $f > $f.new && mv $f.new $f

  (google.kind "alias" with google.parent for a domain alias), then re-run this command.
EOF
    exit 1
  fi
}

# The kind and parent of $domain for onboard: flags, then data, then the
# original "a --parent means an alias".
kind="" kind_parent="" kind_explicit=1
resolve_kind() {
  local f="$1" dk dp
  dk="$(jq -r --arg d "$domain" '.domains[$d].google.kind // empty' "$f")"
  dp="$(jq -r --arg d "$domain" '.domains[$d].google.parent // empty' "$f")"
  if [ -n "$kind_flag" ]; then
    kind="$kind_flag"
    [ -z "$dk" ] || [ "$dk" = "$kind_flag" ] || die "--kind $kind_flag contradicts the data's google.kind \"$dk\" for $domain"
  elif [ -n "$dk" ]; then
    kind="$dk"
  elif [ -n "$parent" ]; then
    # The original contract: an alias, unless the tenant has the domain already.
    kind="alias" kind_explicit=0
  else
    die "the kind of $domain is unknown: declare .domains[\"$domain\"].google = {kind: \"secondary\"} (or {kind: \"alias\", parent: \"<domain>\"}) in $f, or pass --kind secondary / --parent P"
  fi
  case "$kind" in
    alias)
      kind_parent="${parent:-$dp}"
      [ -n "$kind_parent" ] || die "$domain is an alias: its parent is --parent or the data's google.parent"
      [ -z "$parent" ] || [ -z "$dp" ] || [ "$parent" = "$dp" ] ||
        die "--parent $parent contradicts the data's google.parent \"$dp\" for $domain"
      [ "$kind_parent" != "$domain" ] || die "--domain and --parent are the same domain"
      ;;
    secondary | primary)
      [ -z "$parent" ] || die "--parent is only for an alias; the kind of $domain is $kind"
      ;;
  esac
}

# The edits, as jq programs over the whole file. Each is idempotent, so "the
# file already carries the change" is "the edit changes nothing".
verification_prog='.version = 2
  | .domains[$d].google_verification = (
      (.domains[$d].google_verification // []) as $l
      | if any($l[]; . == $t) then $l else $l + [$t] end)'

records_prog='.version = 2
  | .domains[$d] |= (
      ($replace or (.google.spf_replace // false)) as $replace
      | .mx = (
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
    | .dmarc = (.dmarc // ({p: "none"} + (if $rua == "" then {} else {rua: ["mailto:" + $rua]} end)))
    | if $tls == "" or .tls_rpt != null then . else .tls_rpt = {rua: ["mailto:" + $tls]} end)'

verification_token=""
apply_jq() { # FILE PROGRAM -> the edited JSON on stdout
  local f="$1" prog_text="$2" drop
  drop="$(printf '%s\n' "${spf_drop[@]}" | jq -R . | jq -sc 'map(select(. != ""))')"
  jq --indent 2 --arg d "$domain" --arg t "$verification_token" --argjson mx "${mx_list:-[]}" \
    --argjson mx_explicit "$([ "$mx_explicit" = 1 ] && echo true || echo false)" \
    --argjson drop "$drop" --argjson replace "$([ "$spf_replace" = 1 ] && echo true || echo false)" \
    --arg rua "$dmarc_rua" --arg tls "$tls_rpt_rua" "$prog_text" "$f"
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
  pr_added="$added" pr_removed="$removed" pr_known=1
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

want_mx="" want_spf="" want_dmarc="" want_tls=""
records_served() {
  local got
  got="$(lookup_mx "$domain" "$1")" || return 1
  [ "$got" = "$want_mx" ] || return 1
  got="$(lookup_txt "$domain" "$1" | grep '^v=spf1' || true)"
  [ "$got" = "$want_spf" ] || return 1
  got="$(lookup_txt "_dmarc.$domain" "$1" | grep '^v=DMARC1' || true)"
  [ "$got" = "$want_dmarc" ] || return 1
  got="$(lookup_txt "_smtp._tls.$domain" "$1" | grep '^v=TLSRPTv1' || true)"
  [ "$got" = "$want_tls" ]
}
records_answer() {
  printf 'MX %s | %s | %s | %s' "$(lookup_mx "$domain" "$1" | paste -sd, -)" \
    "$(lookup_txt "$domain" "$1" | grep '^v=spf1' | paste -sd' ' -)" \
    "$(lookup_txt "_dmarc.$domain" "$1" | grep '^v=DMARC1' | paste -sd' ' -)" \
    "$(lookup_txt "_smtp._tls.$domain" "$1" | grep '^v=TLSRPTv1' | paste -sd' ' -)"
}

# ── onboard ──────────────────────────────────────────────────────────────────

data_abs="" root="" rel=""
locate_data() {
  [ -n "$data" ] || die "--data is required (the mail-auth JSON data file)"
  [ -f "$data" ] || die "no such data file: $data"
  data_abs="$(cd "$(dirname "$data")" && pwd)/$(basename "$data")"
  if root="$(git -C "$(dirname "$data_abs")" rev-parse --show-toplevel 2>/dev/null)"; then
    :
  elif [ "$no_pr" = 1 ] || [ "$cmd" != onboard ]; then
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
  pr_subject="the $phase change for $domain"
  pr_mismatch_msg="the open PR ($branch) carries different $phase records for $domain than this run would write. Close it and delete the branch, then re-run"
  publish_pr "$root" "$rel" "$branch" "$title" "$body" "$title

$body" phase_state phase_edit
}

state_field() { jq -r ".$1" <<<"$2"; }

kind_phrase() { # the kind as a phrase for messages
  case "$kind" in
    alias) printf 'a domain alias of %s' "$kind_parent" ;;
    secondary) printf 'a secondary domain' ;;
    primary) printf "the tenant's primary domain" ;;
  esac
}

cmd_onboard() {
  [ -n "$domain" ] || die "--domain is required"
  locate_data
  require_declared "$data_abs"
  resolve_kind "$data_abs"
  need_credentials
  mx_list="$(mx_json)"

  # 1. the domain on the tenant
  local st have verified start now
  st=""
  if [ "$kind_explicit" = 0 ]; then
    # Data that declares no kind: a domain the tenant has is left as it is.
    st="$(api state "$domain" --write)" || exit 1
    [ "$(state_field kind "$st")" != absent ] || st=""
  fi
  if [ -z "$st" ]; then
    case "$kind" in
      alias) st="$(api alias "$domain" "$kind_parent")" || exit 1 ;;
      secondary) st="$(api secondary "$domain")" || exit 1 ;;
      primary) st="$(api state "$domain" --write)" || exit 1 ;;
    esac
  fi
  have="$(state_field kind "$st")"
  verified="$(state_field verified "$st")"
  if [ "$kind_explicit" = 0 ] && [ "$have" != absent ]; then
    kind="$have"
    [ "$have" != alias ] || kind_parent="$(state_field parent "$st")"
  fi
  case "$have" in
    alias) say "$domain is a domain alias of $(state_field parent "$st") (verified: $verified)" ;;
    secondary) say "$domain is a secondary domain of the tenant (verified: $verified)" ;;
    primary) say "$domain is the tenant's primary domain (verified: $verified)" ;;
    *) die "$domain was not added to the tenant (state: $st)" ;;
  esac
  if [ "$kind" = primary ] && [ "$have" != primary ]; then
    die "the data says $domain is the tenant's primary domain, but the tenant has it as $have"
  fi

  # 2-3. ownership
  if [ "$verified" != true ]; then
    verification_token="$(api token "$domain")" || exit 1
    say "verification TXT for $domain: $verification_token"
    phase=verification phase_prog="$verification_prog"
    run_phase "mail/$domain-verification" "dns: Google site verification for $domain" \
      "Publishes the TXT record that proves ownership of \`$domain\` to Google (Site Verification API, DNS_TXT), so the domain can be verified as $(kind_phrase) on the Workspace tenant.

Opened by \`google-workspace-domains onboard\`. The MX/SPF/DMARC/TLS-RPT switch follows in a separate PR once Google reports the domain verified."
    wait_until_served "$domain" "the verification TXT at $domain" token_served token_answer \
      "'$prog status --domain $domain --data $data' to see what is published"
    say "asking Google to verify $domain"
    api verify "$domain" >/dev/null || exit 1
    start="$(date +%s)"
    while :; do
      st="$(api state "$domain" --write)" || exit 1
      [ "$(state_field verified "$st")" = true ] && break
      now="$(date +%s)"
      [ $((now - start)) -lt "$verify_timeout" ] ||
        die "Google accepted the verification but the Directory API still reports $domain unverified after ${verify_timeout}s; re-run to keep waiting"
      say "  waiting for the Directory API to report $domain verified"
      sleep "$verify_interval"
    done
    say "$domain is verified"
  fi

  # An alias's addresses are its parent's users' addresses: with the parent not
  # verified there are none yet, and mail switched here would bounce.
  if [ "$kind" = alias ]; then
    st="$(api state "$kind_parent")" || exit 1
    [ "$(state_field verified "$st")" = true ] ||
      die "$domain is verified, but its parent $kind_parent is not (tenant: $(state_field kind "$st")): its mail records stay as they are. Onboard $kind_parent first, then re-run this for $domain"
  fi

  # 4. the mail records
  phase=records phase_prog="$records_prog"
  run_phase "mail/$domain-records" "dns: mail records for $domain (Google Workspace)" \
    "Switches \`$domain\`'s MX to Google Workspace ($(jq -r 'map("\(.priority) \(.host)") | join(", ")' <<<"$mx_list") unless it is on Google already) and sets its SPF, DMARC and TLS-RPT records, now that the domain is verified as $(kind_phrase).

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
  want_tls="$(jqm -r --arg d "$domain" 'include "mail-auth"; mail_auth_tls_rpt($d) // empty' <<<"$served")"
  wait_until_served "$domain" "the MX, SPF, DMARC and TLS-RPT records of $domain" records_served records_answer \
    "'$prog status --domain $domain --data $data' to see what is published"

  # 5. what has no API
  cat >&2 <<EOF

$prog: $domain is on the tenant as $(kind_phrase) and its mail records are live.
Left to do:
$( [ "$kind" = primary ] || cat <<EOT
  1. Admin console > Account > Domains > Manage domains
     (https://admin.google.com/ac/domains/manage): find $domain and, if it
     offers "Activate Gmail", click it (Google checks the MX records it now
     finds and starts accepting mail for the domain).
EOT
)
  2. DKIM, so mail sent as @$domain is signed by $domain:
       google-workspace-dkim publish --domain $domain --data $data …
     (the key is generated in the console; Google has no API for it).
  3. The users' addresses there and their Gmail send-as entries:
       $prog user-addresses --user <user> --domain $domain --data $data
Then: $prog status --domain $domain --data $data
EOF
}

# ── edit (one phase, in place, nothing else) ─────────────────────────────────

cmd_edit() {
  [ -n "$domain" ] || die "--domain is required"
  [ -n "$data" ] || die "--data is required (the mail-auth JSON data file)"
  [ -f "$data" ] || die "no such data file: $data"
  require_declared "$data"
  case "$edit_phase" in
    verification)
      [[ $edit_token =~ ^google-site-verification=[A-Za-z0-9_-]+$ ]] ||
        die "--token must be a google-site-verification=… value"
      verification_token="$edit_token" phase_prog="$verification_prog"
      ;;
    records)
      mx_list="$(mx_json)"
      phase_prog="$records_prog"
      ;;
    *) die "--phase must be verification or records" ;;
  esac
  phase="$edit_phase"
  [ "$(phase_state "$data")" != same ] || return 3
  [ "$dry_run" = 0 ] || return 0
  local tmp
  tmp="$(mktemp "$data.XXXXXX")"
  apply_jq "$data" "$phase_prog" >"$tmp"
  chmod --reference="$data" "$tmp" 2>/dev/null || true
  mv "$tmp" "$data"
  say "edited $domain's $phase in $data"
}

# ── user addresses ───────────────────────────────────────────────────────────

# Local parts for USER: --local, else the data's google_users, else USER's own.
locals_for() {
  local u="$1"
  if [ "${#locals[@]}" -gt 0 ]; then
    printf '%s\n' "${locals[@]}"
  elif jq -e --arg u "$u" '.google_users[$u].local_parts | length > 0' "$data_abs" >/dev/null 2>&1; then
    jq -r --arg u "$u" '.google_users[$u].local_parts[]' "$data_abs"
  else
    printf '%s\n' "${u%@*}"
  fi
}

data_kind() { jq -r --arg d "$1" '.domains[$d].google.kind // empty' "$data_abs"; }
data_parent() { jq -r --arg d "$1" '.domains[$d].google.parent // empty' "$data_abs"; }

# The addresses USER has (or will have) at domain D, one per line, from the
# user's directory view $2 (JSON from `api user`): local parts at a secondary
# domain, the parent's addresses mirrored at an alias domain.
addresses_at() {
  local u="$1" view="$2" d="$3" k p
  k="$(data_kind "$d")"
  case "$k" in
    secondary) locals_for "$u" | sed "s/\$/@$d/" ;;
    alias)
      p="$(data_parent "$d")"
      jq -r --arg p "$p" --arg d "$d" '
        [.primaryEmail] + .aliases | .[] | select(endswith("@" + $p)) | sub("@.*$"; "@" + $d)' <<<"$view" | LC_ALL=C sort -u
      ;;
  esac
}

ua_status=0
ensure_user() {
  local u="$1" d st view sendas addr r status addrs=() made=() k missing i
  shift
  echo "== $u"
  # Secondary domains first: an alias domain mirrors addresses its parent has.
  for d in "$@"; do
    [ "$(data_kind "$d")" = secondary ] || continue
    st="$(api state "$d")" || exit 1
    if [ "$(state_field verified "$st")" != true ] || [ "$(state_field kind "$st")" != secondary ]; then
      printf '   %-36s skipped: not a verified secondary domain of the tenant yet (%s)\n' "$d" "$(state_field kind "$st")"
      ua_status=2
      continue
    fi
    while IFS= read -r addr; do
      r="$(api user-alias "$u" "$addr")" || exit 1
      printf '   %-36s user alias: %s\n' "$addr" "$(state_field result "$r")"
      made+=("$addr")
    done < <(locals_for "$u" | sed "s/\$/@$d/")
  done
  # A just-created alias takes a while to appear in the user's directory
  # entry; wait for every one, or the send-as step below would silently skip
  # them.
  for i in $(seq 1 "${GOOGLE_ALIAS_WAIT_TRIES:-24}"); do
    view="$(api user "$u")" || exit 1
    missing=0
    for addr in "${made[@]}"; do
      jq -e --arg a "$addr" '[(.aliases // [])[] | ascii_downcase] | index($a)' <<<"$view" >/dev/null || missing=$((missing + 1))
    done
    [ "$missing" = 0 ] && break
    [ "$i" = 1 ] && echo "   (waiting for $missing new alias(es) to appear in the directory)"
    sleep "${GOOGLE_ALIAS_WAIT_SECONDS:-5}"
  done
  if [ "$missing" != 0 ]; then
    echo "   $missing alias(es) are not visible in the directory yet; re-run to add their send-as entries"
    ua_status=2
  fi
  for d in "$@"; do
    k="$(data_kind "$d")"
    case "$k" in
      secondary) ;;
      alias)
        st="$(api state "$d")" || exit 1
        if [ "$(state_field verified "$st")" != true ] || [ "$(state_field kind "$st")" != alias ]; then
          printf '   %-36s skipped: not a verified domain alias of the tenant yet (%s)\n' "$d" "$(state_field kind "$st")"
          ua_status=2
          continue
        fi
        ;;
      *) continue ;;
    esac
    while IFS= read -r addr; do
      [ -n "$addr" ] || continue
      # A secondary domain that was skipped above contributes nothing.
      if [ "$k" = secondary ] && ! jq -e --arg a "$addr" '[(.aliases // [])[] | ascii_downcase] | index($a)' <<<"$view" >/dev/null; then
        continue
      fi
      addrs+=("$addr")
    done < <(addresses_at "$u" "$view" "$d")
  done
  for addr in "${addrs[@]}"; do
    r="$(api sendas-create "$u" "$addr")" || exit 1
    status="$(state_field verificationStatus "$r")"
    printf '   %-36s send-as: %s (%s)\n' "$addr" "$status" "$(state_field result "$r")"
    if [ "$status" != accepted ]; then
      ua_status=2
      echo "      pending: Gmail mailed a confirmation link to this address;"
      echo "      open it in $u's mailbox, click it, and re-run."
    fi
  done
  if [ "${#addrs[@]}" = 0 ]; then
    echo "   (no addresses: no verified secondary or alias domain among the ones asked)"
    # Asked for addresses and got none: not done, whatever the reason.
    ua_status=2
  fi
}

cmd_user_addresses() {
  locate_data
  need_credentials
  local us=() ds=() d u
  if [ "$all" = 1 ]; then
    mapfile -t us < <(jq -r '(.google_users // {}) | keys[]' "$data_abs")
    [ "${#us[@]}" -gt 0 ] || die "--all: $data declares no google_users"
  else
    [ -n "$user" ] || die "--user USER or --all is required"
    us=("$user")
  fi
  if [ "$all_domains" = 1 ]; then
    mapfile -t ds < <(jq -r '.domains | to_entries[]
      | select((.value.zone_pending // false) | not)
      | select(.value.google.kind == "secondary" or .value.google.kind == "alias") | .key' "$data_abs")
  else
    [ -n "$domain" ] || die "--domain D or --all-domains is required"
    is_pending "$domain" "$data_abs" && die "$domain is zone_pending in $data: onboard it first, once its zone exists"
    case "$(data_kind "$domain")" in
      secondary | alias) ds=("$domain") ;;
      primary) die "$domain is the tenant's primary domain: its addresses are the users' own" ;;
      *) die "the data declares no google.kind for $domain (secondary or alias)" ;;
    esac
  fi
  for u in "${us[@]}"; do
    ensure_user "$u" "${ds[@]}"
  done
  if [ "$ua_status" = 0 ]; then
    say "OK: every address is in place and accepted for sending"
  else
    say "some addresses are pending or their domains are not verified yet (see above)"
  fi
  return "$ua_status"
}

# ── DMARC report group ───────────────────────────────────────────────────────

group_guidance() { # REASON
  guide_h1 "Let $group receive reports from outside"
  case "$1" in
    api)
      guide_text "The Groups Settings API is not enabled in the service account's project."
      guide_step 1 "Run (as someone who administers the project):"
      guide_value "gcloud services enable groupssettings.googleapis.com --project ${project_id:-<project>}"
      guide_step 2 "or open https://console.cloud.google.com/apis/library/groupssettings.googleapis.com?project=${project_id:-<project>} and click ENABLE."
      guide_text "Success looks like: 'Operation finished successfully' / the API page shows MANAGE. It can take a minute to reach the API."
      ;;
    scope)
      guide_text "The delegation lacks https://www.googleapis.com/auth/apps.groups.settings. Run the scopes step first ($prog scopes --guide)."
      ;;
    org)
      guide_text "Google refused ANYONE_CAN_POST: the organisation does not let group owners accept mail from outside."
      guide_step 1 "Open https://admin.google.com and go to Apps > Google Workspace > Groups for Business, then click 'Sharing settings'."
      guide_step 2 "Tick 'Group owners can allow incoming email from outside the organization'. Click SAVE."
      guide_text "Success looks like: the box stays ticked after a reload."
      ;;
    nogroup)
      guide_step 1 "Open https://admin.google.com/ac/groups and click 'Create group'."
      guide_step 2 "Name: DMARC reports. Group email: $group. Owner: yourself. Next."
      guide_step 3 "Access type: Custom; 'Who can post': Anyone on the web (External). Create group."
      guide_text "Success looks like: the group is listed; this tool then sets and checks its posting and moderation settings."
      ;;
  esac
}

project_id=""
cmd_dmarc_group() {
  [ -n "$group" ] || die "--group GROUP is required (the DMARC/TLS-RPT report mailbox)"
  group="${group,,}"
  [[ $group =~ $mailbox_re ]] || die "--group: \"$group\" is not an email address"
  need_credentials
  project_id="$(jq -r '.project_id // empty' "$key" 2>/dev/null || true)"
  local out err rc reason
  # Anyone may post, and nothing is held for a moderator.
  report_ready() {
    jq -e '.whoCanPostMessage == "ANYONE_CAN_POST" and .spamModerationLevel == "ALLOW"
      and .messageModerationLevel == "MODERATE_NONE"' <<<"$1" >/dev/null
  }
  while :; do
    err="$(mktemp)"
    rc=0
    out="$(api group "$group" 2>"$err")" || rc=$?
    if [ "$rc" = 0 ] && ! report_ready "$out"; then
      say "$group: whoCanPostMessage $(state_field whoCanPostMessage "$out"), spam moderation $(state_field spamModerationLevel "$out"), message moderation $(state_field messageModerationLevel "$out"); setting ANYONE_CAN_POST, ALLOW, MODERATE_NONE"
      out="$(api group "$group" --allow-external 2>"$err")" || rc=$?
    fi
    if [ "$rc" = 0 ] && report_ready "$out"; then
      rm -f "$err"
      echo "$group: whoCanPostMessage ANYONE_CAN_POST"
      echo "   spam moderation: ALLOW, message moderation: MODERATE_NONE (nothing is held)"
      say "OK: $group accepts reports from outside the organisation"
      return 0
    fi
    cat "$err" >&2
    if grep -q 'groupssettings.googleapis.com API is not enabled' "$err"; then
      reason=api
    elif grep -q 'apps.groups.settings' "$err" && grep -q unauthorized_client "$err"; then
      reason=scope
    elif grep -q 'no group ' "$err"; then
      reason=nogroup
    elif grep -q 'Groups for Business' "$err" || [ "$rc" = 0 ]; then
      reason=org
    else
      reason=""
    fi
    rm -f "$err"
    [ "$guide" = 1 ] && [ -n "$reason" ] || exit 1
    group_guidance "$reason"
    local w=0
    guide_wait "Done? This tool then checks $group again." || w=$?
    [ "$w" = 10 ] && {
      say "skipped: $group may not accept reports from outside yet"
      return 2
    }
  done
}

# ── delegation scopes ────────────────────────────────────────────────────────

full_scope() { case "$1" in https://*) printf '%s' "$1" ;; *) printf 'https://www.googleapis.com/auth/%s' "$1" ;; esac; }

cmd_scopes() {
  need_credentials
  local want=() s res client missing=() granted=() line w
  local IFS=,
  for s in $scope_list; do [ -n "$s" ] && want+=("$(full_scope "$s")"); done
  unset IFS
  [ "${#want[@]}" -gt 0 ] || die "--scopes is empty"
  while :; do
    res="$(api scopes "${want[@]}")" || exit 1
    client="$(state_field client_id "$res")"
    missing=() granted=()
    for s in "${want[@]}"; do
      case "$(jq -r --arg s "$s" '.scopes[$s]' <<<"$res")" in
        ok) granted+=("$s") ;;
        denied) missing+=("$s") ;;
        *) die "checking $s failed: $(jq -r --arg s "$s" '.scopes[$s]' <<<"$res")" ;;
      esac
    done
    guide_h1 "Domain-wide delegation scopes (client id $client)"
    for s in "${want[@]}"; do
      if [ "$(jq -r --arg s "$s" '.scopes[$s]' <<<"$res")" = ok ]; then
        printf '  ok       %s\n' "${s#https://www.googleapis.com/auth/}"
      else
        printf '  MISSING  %s\n' "${s#https://www.googleapis.com/auth/}"
      fi
    done
    if [ "${#missing[@]}" = 0 ]; then
      guide_ok "all ${#want[@]} scopes are granted to $subject's delegation"
      return 0
    fi
    line="$(
      IFS=,
      echo "${want[*]}"
    )"
    guide_h2 "What to do in the Admin console (a super admin)"
    guide_step 1 "Open https://admin.google.com/ac/owl/domainwidedelegation"
    guide_step 2 "Find the row whose Client ID is $client and click it, then 'Edit' (no row: click 'Add new' and enter that Client ID)."
    guide_step 3 "Clear the 'OAuth scopes' box and paste this ONE line (every scope these tools need: the ${#granted[@]} already granted plus the ${#missing[@]} missing):"
    guide_value "$line"
    guide_text "     (One scope per box instead, if the form shows separate boxes:)"
    for s in "${want[@]}"; do printf '      %s\n' "$s"; done
    guide_step 4 "Click 'Authorize'."
    guide_text "WARNING: the saved list REPLACES the old one. If the row lists scopes that are not in the line above, add them to it before saving, or the automation using them stops working."
    guide_text "Success looks like: the row lists every scope above. Google applies it within minutes, occasionally up to 24 hours."
    [ "$guide" = 1 ] || exit 3
    w=0
    guide_wait "Saved? This tool then mints a token for each scope again." || w=$?
    if [ "$w" = 10 ]; then
      say "skipped: ${#missing[@]} scope(s) still missing"
      return 3
    fi
  done
}

# ── status ───────────────────────────────────────────────────────────────────

# Per-field results of status_domain, for the detailed or the table form.
declare -A res=()
status_status=0

status_domain() {
  local d="$1" r="${resolvers[0]}" st got want sel t dk dp tk w n_ok n_all view sendas addr a s
  res=()
  domain="$d"
  dk="$(data_kind "$d")"
  dp="$(data_parent "$d")"
  set_res() { # field state(ok|none|diff|info) text
    res[$1]="$2|$3"
    [ "$2" != diff ] || status_status=1
  }
  set_res kind info "${dk:-<not declared>}${dp:+ of $dp}"
  if [ -n "$key" ] && [ -n "$subject" ]; then
    if st="$(api state "$d" 2>"$work_err")"; then
      tk="$(state_field kind "$st")"
      t="$tk$([ "$tk" = alias ] && echo " of $(state_field parent "$st")"), verified: $(state_field verified "$st")"
      if [ "$(state_field verified "$st")" != true ] || { [ -n "$dk" ] && [ "$dk" != "$tk" ]; }; then
        set_res tenant diff "$t$([ -n "$dk" ] && [ "$dk" != "$tk" ] && echo " (the data says $dk)")"
      else
        set_res tenant ok "$t"
      fi
    else
      set_res tenant diff "<the API call failed: $(tail -n1 "$work_err" | sed "s/^$prog: //")>"
    fi
  else
    set_res tenant info "<not asked: pass --key and --subject>"
  fi
  cmp_res() { # field want got [note-when-ok]
    if [ -z "$2" ]; then
      if [ -z "$3" ]; then set_res "$1" none "not declared, nothing served"; else set_res "$1" none "not declared (serves: $3)"; fi
    elif [ "$2" = "$3" ]; then
      set_res "$1" ok "$3${4:+ $4}"
    else
      set_res "$1" diff "declared $2, serves ${3:-<nothing>}"
    fi
  }
  want="$(jqm -r --arg d "$d" 'include "mail-auth"; mail_auth_mx($d)' "$data_abs" | LC_ALL=C sort | paste -sd, -)"
  got="$(lookup_mx "$d" "$r" | paste -sd, -)"
  if [ -n "$want" ] && [ "$want" != "$got" ] && [ -n "$got" ] &&
    [ "$(tr , '\n' <<<"$want" | mx_normalise "$d" declared)" = "$(tr , '\n' <<<"$got" | mx_normalise "$d" served)" ]; then
    set_res MX ok "$want (served as Cloudflare's proxied-MX substitute $got: the mail host's A record is proxied)"
  else
    cmp_res MX "$want" "$got"
  fi
  want="$(jqm -r --arg d "$d" 'include "mail-auth"; mail_auth_spf($d) // empty' "$data_abs")"
  got="$(lookup_txt "$d" "$r" | grep '^v=spf1' | paste -sd'|' - || true)"
  cmp_res SPF "$want" "$got"
  want="$(jqm -r --arg d "$d" 'include "mail-auth"; mail_auth_dmarc($d) // empty' "$data_abs")"
  got="$(lookup_txt "_dmarc.$d" "$r" | grep '^v=DMARC1' | paste -sd'|' - || true)"
  cmp_res DMARC "$want" "$got"
  want="$(jqm -r --arg d "$d" 'include "mail-auth"; mail_auth_tls_rpt($d) // empty' "$data_abs")"
  got="$(lookup_txt "_smtp._tls.$d" "$r" | grep '^v=TLSRPTv1' | paste -sd'|' - || true)"
  cmp_res TLS-RPT "$want" "$got"
  want="$(jqm -r --arg d "$d" 'include "mail-auth"; mail_auth_mta_sts($d) // empty' "$data_abs")"
  got="$(lookup_txt "_mta-sts.$d" "$r" | grep '^v=STSv1' | paste -sd'|' - || true)"
  if [ -n "$want" ] || [ -n "$got" ]; then cmp_res MTA-STS "$want" "$got"; fi
  n_ok=0 n_all=0
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    n_all=$((n_all + 1))
    got="$(lookup_txt "$d" "$r" || true)"
    if grep -qxF -- "$t" <<<"$got"; then n_ok=$((n_ok + 1)); fi
  done < <(jq -r --arg d "$d" '(.domains[$d].google_verification // [])[]' "$data_abs")
  if [ "$n_all" -gt 0 ]; then
    if [ "$n_ok" = "$n_all" ]; then set_res VERIFY ok "$n_ok token(s) served"; else set_res VERIFY diff "$n_ok of $n_all token(s) served"; fi
  fi
  n_ok=0 n_all=0 w=""
  while IFS= read -r sel; do
    [ -n "$sel" ] || continue
    n_all=$((n_all + 1))
    want="$(jq -r --arg d "$d" --arg s "$sel" '.domains[$d].dkim[$s]' "$data_abs")"
    got="$(lookup_txt "$sel._domainkey.$d" "$r" | paste -sd'|' - || true)"
    if [ "$want" = "$got" ]; then n_ok=$((n_ok + 1)); else w+=" $sel"; fi
  done < <(jq -r --arg d "$d" '(.domains[$d].dkim // {}) | keys[]' "$data_abs")
  if [ "$n_all" = 0 ]; then
    set_res DKIM none "no key declared"
  elif [ "$n_ok" = "$n_all" ]; then
    set_res DKIM ok "selector(s) $(jq -r --arg d "$d" '.domains[$d].dkim | keys | join(",")' "$data_abs") served"
  else
    set_res DKIM diff "not served as declared:$w"
  fi
  # The user's addresses here, with --user.
  if [ -n "$user" ] && { [ "$dk" = secondary ] || [ "$dk" = alias ]; }; then
    if [ -z "$key" ] || [ -z "$subject" ]; then
      set_res ADDR info "<not asked: pass --key and --subject>"
    elif ! view="$(api user "$user" 2>"$work_err")" || ! sendas="$(api sendas-list "$user" 2>>"$work_err")"; then
      set_res ADDR diff "<the API call failed: $(tail -n1 "$work_err" | sed "s/^$prog: //")>"
    else
      n_ok=0 n_all=0 w=""
      while IFS= read -r addr; do
        [ -n "$addr" ] || continue
        n_all=$((n_all + 1))
        if [ "$dk" = secondary ]; then
          a="$(jq -r --arg a "$addr" 'if (.aliases | index([$a])) then "alias" else "NO alias" end' <<<"$view")"
        else
          a="$(jq -r --arg a "$addr" 'if (.nonEditableAliases | index([$a])) then "mirrored" else "NOT mirrored" end' <<<"$view")"
        fi
        s="$(jq -r --arg a "$addr" '([.[] | select(.sendAsEmail == $a) | .verificationStatus] | first) // "NO send-as"' <<<"$sendas")"
        w+="${w:+; }$addr $a, send-as $s"
        [[ $a != NO* && $a != NOT* && $s == accepted ]] && n_ok=$((n_ok + 1))
      done < <(addresses_at "$user" "$view" "$d")
      if [ "$n_all" = 0 ]; then
        set_res ADDR diff "none for $user"
      elif [ "$n_ok" = "$n_all" ]; then
        set_res ADDR ok "$w"
      else
        set_res ADDR diff "$w"
      fi
    fi
  fi
}

print_detail() {
  local d="$1" f v st txt
  echo "== $d"
  for f in kind tenant MX SPF DMARC TLS-RPT MTA-STS VERIFY DKIM ADDR; do
    v="${res[$f]:-}"
    [ -n "$v" ] || continue
    st="${v%%|*}" txt="${v#*|}"
    case "$st" in
      ok) printf '   %-8s OK  %s\n' "$f" "$txt" ;;
      diff) printf '   %-8s DIFFERS: %s\n' "$f" "$txt" ;;
      *) printf '   %-8s %s\n' "$f" "$txt" ;;
    esac
  done
}

table_cell() {
  local v="${res[$1]:-}"
  case "${v%%|*}" in
    ok) printf 'ok' ;;
    diff) printf 'NO' ;;
    none) printf '%s' '--' ;;
    *) printf '?' ;;
  esac
}

print_row() {
  local d="$1" k t
  k="$(data_kind "$d")"
  case "${res[tenant]%%|*}" in ok) t=yes ;; diff) t=NO ;; *) t='?' ;; esac
  printf '%-18s %-4s %-4s %-3s %-3s %-5s %-3s %-4s %s\n' "${d:0:18}" "${k:0:4}" "$t" \
    "$(table_cell MX)" "$(table_cell SPF)" "$(table_cell DMARC)" "$(table_cell TLS-RPT)" "$(table_cell DKIM)" \
    "$([ -n "$user" ] && { [ -n "${res[ADDR]:-}" ] && table_cell ADDR || printf -- '-'; })"
}

work_err=""
cmd_status() {
  locate_data
  local ds=() d
  work_err="$(mktemp)"
  trap 'rm -f "$work_err"' EXIT
  if [ "$all" = 1 ]; then
    mapfile -t ds < <(jq -r '.domains | keys[]' "$data_abs")
  else
    [ -n "$domain" ] || die "--domain or --all is required"
    if ! is_pending "$domain" "$data_abs"; then require_declared "$data_abs"; fi
    ds=("$domain")
  fi
  say "DNS as $(printf '%s' "${resolvers[0]}") serves it, against $data"
  if [ "$table" = 1 ]; then
    printf '%-18s %-4s %-4s %-3s %-3s %-5s %-3s %-4s %s\n' DOMAIN KIND VER MX SPF DMARC TLS DKIM "$([ -n "$user" ] && echo ADDR)"
  fi
  for d in "${ds[@]}"; do
    if is_pending "$d" "$data_abs"; then
      if [ "$table" = 1 ]; then
        printf '%-18s %-4s (zone pending: not in Cloudflare yet)\n' "${d:0:18}" "$(data_kind "$d" | cut -c1-4)"
      else
        echo "== $d"
        echo "   skipped: zone_pending (its DNS is not in a Cloudflare zone yet; nothing is published for it)"
      fi
      continue
    fi
    status_domain "$d"
    if [ "$table" = 1 ]; then print_row "$d"; else print_detail "$d"; fi
  done
  if [ "$table" = 1 ]; then
    echo "ok = served as declared; NO = declared but not served, or not verified;"
    echo "-- = not declared"
  fi
  if [ "$status_status" = 0 ]; then
    say "OK: everything declared is served"
  else
    say "some declared records are not served (or a domain is not verified, or an address is missing)"
  fi
  return "$status_status"
}

# ── registrar debris ─────────────────────────────────────────────────────────

cf_api="${CLOUDFLARE_API_BASE:-https://api.cloudflare.com/client/v4}"
cf_token=""
# cf METHOD PATH: one Cloudflare API call with $cf_token; the JSON on stdout.
# The token goes to curl through a header file, never on a command line.
cf() {
  local hdr out
  hdr="$(mktemp)"
  printf 'Authorization: Bearer %s\n' "$cf_token" >"$hdr"
  out="$(curl -sS -X "$1" -H @"$hdr" -H 'Content-Type: application/json' "$cf_api$2")" || {
    rm -f "$hdr"
    return 1
  }
  rm -f "$hdr"
  jq -e '.success == true' <<<"$out" >/dev/null 2>&1 || {
    echo "$prog: Cloudflare $1 $2: $(jq -r '[.errors[]? | "\(.code) \(.message)"] | join("; ")' <<<"$out" 2>/dev/null || echo "$out" | head -c 200)" >&2
    return 1
  }
  printf '%s\n' "$out"
}

load_cf_token() {
  cf_token=""
  if [ -n "$token_file" ] && [ -r "$token_file" ]; then
    cf_token="$(tr -d '[:space:]' <"$token_file")"
  elif [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
    cf_token="$CLOUDFLARE_API_TOKEN"
  fi
  [ -n "$cf_token" ]
}

matches_any() { # VALUE PATTERN… (bash patterns)
  local v="$1" p
  shift
  for p in "$@"; do
    # shellcheck disable=SC2053 # a pattern on purpose
    [[ $v == $p ]] && return 0
  done
  return 1
}

# Findings, one per line: "<id>\t<type>\t<name>\t<content>\t<verdict>".
debris=()
classify_ns() { # NAME TARGET [ID]
  local name="$1" target="${2%.}" id="${3:--}"
  target="${target,,}"
  matches_any "$target" "${zone_ns[@]}" && return 0
  matches_any "$target" "${allow_ns[@]}" && return 0
  if matches_any "$target" "${debris_ns[@]}"; then
    debris+=("$id"$'\t'NS$'\t'"$name"$'\t'"$target"$'\t'"registrar debris: delegates $name away from the zone")
  else
    debris+=("$id"$'\t'NS$'\t'"$name"$'\t'"$target"$'\t'"delegated to a nameserver that is not the zone's (intentional? --allow-ns)")
  fi
}
classify_addr() { # TYPE NAME ADDRESS [ID]
  local ip
  for ip in "${parking_ips[@]}"; do
    [ "$3" = "$ip" ] && debris+=("${4:--}"$'\t'"$1"$'\t'"$2"$'\t'"$3"$'\t'"a registrar's parking address")
  done
  return 0
}

zone_ns=()
cmd_registrar_debris() {
  [ -n "$domain" ] || die "--domain is required"
  [ "${#parking_ips[@]}" -gt 0 ] || parking_ips=(198.54.117.242)
  [ "${#debris_ns[@]}" -gt 0 ] || debris_ns=('failed-whois-verification.namecheap.com' 'verify-contact-details.namecheap.com' '*.namecheap.com')
  local zid="$zone_id_flag" out page pages name type content id n line rc=0 names=() ans unlocked=0
  mapfile -t zone_ns < <(dig +short +time=5 +tries=2 NS "$domain" "@${resolvers[0]}" 2>/dev/null | sed 's/\.$//' | tr '[:upper:]' '[:lower:]' | sort -u)
  say "the zone's nameservers (public DNS): ${zone_ns[*]:-<none>}"
  if [ "${#zone_ns[@]}" -gt 0 ] && matches_any "${zone_ns[0]}" "${debris_ns[@]}"; then
    say "the domain ITSELF is delegated to $(printf '%s ' "${zone_ns[@]}"): the registrar has suspended its DNS (WHOIS/registrant verification, typically). Nothing published in our zone is seen until that is resolved AT THE REGISTRAR; then set the nameservers to the zone's."
    rc=2
    # Those servers are the registrar's, not the zone's.
    zone_ns=()
  fi
  if [ "$delete" = 1 ]; then
    # The deletion needs a token that may edit DNS: unlock it first (the
    # listing then uses it too), and lock it again however this ends.
    if [ -n "$lock_cmd" ]; then
      # shellcheck disable=SC2064 # expanded now, on purpose
      trap "bash -c $(printf '%q' "$lock_cmd") >&2 || true" EXIT
    fi
    if [ -n "$unlock_cmd" ] && { [ -z "$token_file" ] || [ ! -r "$token_file" ]; }; then
      say "unlocking a token that may edit DNS: $unlock_cmd"
      bash -c "$unlock_cmd" || die "the unlock command failed"
      unlocked=1
    fi
  fi
  if [ -z "$zid" ] && [ -n "$data" ] && [ -f "$data" ]; then
    zid="$(jq -r --arg d "$domain" '.domains[$d].zone_id // empty' "$data")"
  fi
  if load_cf_token; then
    if [ -z "$zid" ]; then
      out="$(cf GET "/zones?name=$domain")" || die "could not look up the zone of $domain"
      zid="$(jq -r '.result[0].id // empty' <<<"$out")"
      [ -n "$zid" ] || die "Cloudflare has no zone named $domain for this token"
    fi
    # The zone's own nameservers as Cloudflare assigned them count as "ours".
    out="$(cf GET "/zones/$zid")" || die "could not read zone $zid"
    mapfile -t -O "${#zone_ns[@]}" zone_ns < <(jq -r '.result.name_servers[]? | ascii_downcase' <<<"$out")
    say "listing every record of zone $zid through the Cloudflare API"
    page=1 pages=1
    while [ "$page" -le "$pages" ]; do
      out="$(cf GET "/zones/$zid/dns_records?per_page=500&page=$page")" || die "could not list the records of zone $zid"
      pages="$(jq -r '.result_info.total_pages // 1' <<<"$out")"
      while IFS=$'\t' read -r id type name content; do
        case "$type" in
          NS) [ "$name" = "$domain" ] || classify_ns "$name" "$content" "$id" ;;
          A | AAAA) classify_addr "$type" "$name" "$content" "$id" ;;
        esac
      done < <(jq -r '.result[] | [.id, .type, .name, .content] | @tsv' <<<"$out")
      page=$((page + 1))
    done
  else
    [ "$delete" = 0 ] || die "--delete needs a Cloudflare API token (--token-file, or \$CLOUDFLARE_API_TOKEN)"
    say "no Cloudflare API token: probing public DNS (pass --token-file for every record of the zone)"
    if [ -n "$probe_names" ]; then
      IFS=, read -r -a names <<<"$probe_names"
    else
      names=("" www "parking-probe-$RANDOM" mail _dmarc _domainkey google._domainkey _smtp._tls _mta-sts mta-sts autodiscover webmail ftp smtp imap pop)
    fi
    for n in "${names[@]}"; do
      name="${n:+$n.}$domain"
      if [ -n "$n" ]; then
        while IFS= read -r content; do
          [ -n "$content" ] && classify_ns "$name" "$content"
        done < <(dig +short +time=5 +tries=2 NS "$name" "@${resolvers[0]}" 2>/dev/null | sed 's/\.$//' | sort -u)
      fi
      for type in A AAAA; do
        while IFS= read -r content; do
          [[ $content =~ ^[0-9a-fA-F:.]+$ ]] && classify_addr "$type" "$name" "$content"
        done < <(dig +short +time=5 +tries=2 "$type" "$name" "@${resolvers[0]}" 2>/dev/null)
      done
    done
  fi
  if [ "${#debris[@]}" = 0 ]; then
    say "no registrar debris found for $domain"
    return "$rc"
  fi
  printf '%-34s %-5s %-36s %s\n' RECORD-ID TYPE NAME "CONTENT — WHY"
  for line in "${debris[@]}"; do
    IFS=$'\t' read -r id type name content n <<<"$line"
    printf '%-34s %-5s %-36s %s — %s\n' "$id" "$type" "$name" "$content" "$n"
  done
  say "${#debris[@]} record(s) above shadow or break what the zone should serve"
  [ "$delete" = 1 ] || return 2
  [ "$unlocked" = 0 ] || say "the token was unlocked for this; it is locked again when this ends${lock_cmd:+ ($lock_cmd)}"
  printf '\n>> Delete these %s record(s) of %s through the Cloudflare API? Type yes: ' "${#debris[@]}" "$domain" >&2
  IFS= read -r ans || ans=""
  [ "$ans" = yes ] || {
    say "nothing deleted"
    return 2
  }
  for line in "${debris[@]}"; do
    IFS=$'\t' read -r id type name content n <<<"$line"
    cf DELETE "/zones/$zid/dns_records/$id" >/dev/null || die "deleting $type $name ($id) failed"
    say "deleted $type $name -> $content"
  done
  debris=()
  out="$(cf GET "/zones/$zid/dns_records?per_page=500")" || die "could not list the records again"
  while IFS=$'\t' read -r id type name content; do
    case "$type" in
      NS) [ "$name" = "$domain" ] || classify_ns "$name" "$content" "$id" ;;
      A | AAAA) classify_addr "$type" "$name" "$content" "$id" ;;
    esac
  done < <(jq -r '.result[] | [.id, .type, .name, .content] | @tsv' <<<"$out")
  [ "${#debris[@]}" = 0 ] || die "${#debris[@]} record(s) still there after the deletion"
  say "OK: the zone has no registrar debris left. Public resolvers forget a cached delegation within its TTL."
}

case "$cmd" in
  onboard) cmd_onboard ;;
  status) cmd_status ;;
  user-addresses) cmd_user_addresses ;;
  dmarc-group) cmd_dmarc_group ;;
  scopes) cmd_scopes ;;
  edit) cmd_edit ;;
  registrar-debris) cmd_registrar_debris ;;
  *) die "$usage" ;;
esac
