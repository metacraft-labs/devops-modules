#!/usr/bin/env bash
# Google Workspace setup wizard: puts a tenant's domains into production mail —
# delegation scopes, the DMARC report group, each domain (secondary or alias)
# with its records, the users' addresses and send-as entries, DKIM, and the
# SMTP relay for automated sending — in a safe order, skipping what is already
# done. Built for a narrow terminal pane: guidance on stdout, wrapped at 78
# columns; every console step prints the URL, what to click, the exact value
# to paste and what success looks like.
#
#   google-workspace-setup [STEP] --data FILE [--key KEY --subject ADMIN]
#                          [--user USER] [--group GROUP] [--scopes S,S,…]
#                          [--post-edit CMD] [--dkim-post-edit CMD] [--base BRANCH]
#                          [--dmarc-rua MAILBOX] [--tls-rpt-rua MAILBOX]
#                          [--test-to ADDRESS] [--relay-user USER] [--no-merge]
#                          [--redecide] [--detach]
#
# TWO PHASES (the default, `run` then `follow`). CI and DNS are slow and the
# operator's part is not, so they are separated:
#
#   run             INTERACTIVE, minutes: the delegation scopes and the report
#                   group; the decisions the background phase needs (move the
#                   MX of a domain whose mail goes elsewhere today, once it is
#                   verified? per domain or for all); every declared domain
#                   added to the tenant (secondary domains, then aliases); the
#                   users' addresses on the domains already verified; every
#                   DKIM key the console can generate now, pasted one after the
#                   other (s skips one); then ONE commit on ONE branch with
#                   every DNS change possible now — verification tokens, DKIM
#                   keys, mail records of verified domains as decided — the
#                   consumer's hook run once, ONE PR; then it starts `follow`
#                   detached and returns, saying what happens next.
#   follow          BACKGROUND (or in the foreground when run by hand; with
#                   --detach, started detached): watches the batch PR's checks
#                   and merges it at the head it watched, waits until the zones'
#                   nameservers and then the public resolvers serve every record
#                   of the batch, asks Google to verify every domain whose token
#                   is now served and waits for it, gives the users their
#                   addresses on the newly verified domains, proves inbound mail
#                   on a domain just moved (a message sent through the Gmail API
#                   to the user's address there, found in their inbox; needs
#                   gmail.metadata), and opens the NEXT batch PR for what that
#                   made possible — until nothing is left. It ends with what
#                   still needs the operator (Activate Gmail, Start
#                   authentication, DKIM keys that can now be generated, …),
#                   kept for `status` and, with $GOOGLE_WORKSPACE_NOTIFY set,
#                   piped to that command (title in $NOTIFY_TITLE).
#   status          one line per domain (google-workspace-domains status
#                   --table), then the background phase: running or not, the
#                   batch PR in flight and its stage, the queue, the log.
#
# The answers and the batch in flight are kept in a local state file, never
# committed: ${XDG_STATE_HOME:-~/.local/state}/google-workspace-setup/
# <tenant>.json ($GOOGLE_WORKSPACE_STATE_DIR overrides the directory), with the
# follower's log beside it. Both phases re-read the data file on
# origin/<base>, the tenant and DNS every time, so they resume after any
# interruption. $GOOGLE_WORKSPACE_FOLLOW_DETACH = systemd | nohup | none picks
# how `run` starts the follower (default: a systemd user unit when the user
# manager answers, else nohup).
#
# A domain whose mail goes elsewhere today (an MX outside Google, resolving or
# not) is moved only as decided, and only after a domain already moved has
# received a test message (automatically, or confirmed by the operator at the
# next `run` when the Gmail read scope is not granted). An alias's records wait
# for its parent's verification. A domain another open PR changes (its head
# changes the domain's entry in FILE: a per-domain PR, or a batch made by hand)
# is left to it, and `follow` waits for that PR to land when the domain has
# work due ($GOOGLE_WORKSPACE_FOREIGN_PR_WAIT seconds, default 21600). When a Google API turns out to be disabled, it is enabled with gcloud
# (re-running `gcloud auth login` in the interactive phase when its
# credentials have expired); only a missing permission ends in instructions.
#
# THE STEPS ONE BY ONE (the per-domain path, one PR per change):
#   guided          all of the below in order, per domain — the original
#                   guided run, waiting for each PR
#   scopes          the service account's delegation scopes (Admin console)
#   dmarc-group     GROUP accepts the DMARC/TLS-RPT reports from outside
#   onboard-all     every declared domain onto the tenant with its records
#                   (google-workspace-domains onboard), in the order below
#   user-addresses  every google_users user's addresses and send-as entries
#   dkim-all        DKIM for every onboarded domain that has no key yet
#   smtp-relay      the Workspace SMTP relay for automated sending (console),
#                   tested by sending through it when an app password is given
#
# THE ORDER of the guided path comes from FILE and live DNS: the primary
# domain; then domains whose mail is already on Google (no routing change);
# then domains with no MX at all; then domains whose MX points elsewhere but
# does not resolve; then domains whose mail goes elsewhere today. Before the
# first domain with an MX elsewhere (resolving or not) is switched, the
# operator confirms that a test message from outside arrived at a domain
# already switched to Google; without a domain to send it to, those domains are
# left alone. A domain alias always comes after its parent. Domains declared
# "zone_pending" are listed and skipped.
#
# Answers are read from stdin: Enter = done, verify now; s = skip; q = quit.
# (Loops here read their lists on fd 3, so stdin stays the operator's.)
# Re-running resumes: every step checks the live state first.
#
# Tools: $GOOGLE_WORKSPACE_DOMAINS_CMD (default google-workspace-domains) and
# $GOOGLE_WORKSPACE_DKIM_CMD (default google-workspace-dkim); the API helper
# is $GOOGLE_WORKSPACE_DOMAINS_API as for google-workspace-domains.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # jq programs
set -euo pipefail

prog=google-workspace-setup
here="$(dirname -- "${BASH_SOURCE[0]}")"
lib="${GOOGLE_WORKSPACE_TOOLS_LIB:-$here/lib}"
# shellcheck source=lib/pr-publish.sh
. "$lib/pr-publish.sh"
# shellcheck source=lib/guide.sh
. "$lib/guide.sh"
# shellcheck source=lib/setup-batch.sh
. "$lib/setup-batch.sh"
self="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
read -r -a domains_cmd <<<"${GOOGLE_WORKSPACE_DOMAINS_CMD:-google-workspace-domains}"
read -r -a dkim_cmd <<<"${GOOGLE_WORKSPACE_DKIM_CMD:-google-workspace-dkim}"
read -r -a api_cmd <<<"${GOOGLE_WORKSPACE_DOMAINS_API:-python3 $here/google-workspace-domains-api.py}"

step="run"
case "${1:-}" in
  run | follow | guided | scopes | dmarc-group | onboard-all | user-addresses | dkim-all | smtp-relay | status) step="$1"; shift ;;
  -h | --help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
esac

data="" key="${GOOGLE_WORKSPACE_KEY:-}" subject="${GOOGLE_WORKSPACE_SUBJECT:-}" user="" group="" scopes=""
post_edit="" dkim_post_edit="" base="" dmarc_rua="" tls_rpt_rua="" test_to="" relay_user="" merge=1
redecide=0 detach=0
# The options as given, for the follower `run` starts (it takes the same ones).
setup_args=()
for a in "$@"; do
  case "$a" in --detach | --redecide) ;; *) setup_args+=("$a") ;; esac
done
while [ $# -gt 0 ]; do
  case "$1" in
    --data) data="${2:?}"; shift 2 ;;
    --key) key="${2:?}"; shift 2 ;;
    --subject) subject="${2:?}"; shift 2 ;;
    --user) user="${2:?}"; shift 2 ;;
    --group) group="${2:?}"; shift 2 ;;
    --scopes) scopes="${2:?}"; shift 2 ;;
    --post-edit) post_edit="${2:?}"; shift 2 ;;
    --dkim-post-edit) dkim_post_edit="${2:?}"; shift 2 ;;
    --base) base="${2:?}"; shift 2 ;;
    --dmarc-rua) dmarc_rua="${2:?}"; shift 2 ;;
    --tls-rpt-rua) tls_rpt_rua="${2:?}"; shift 2 ;;
    --test-to) test_to="${2:?}"; shift 2 ;;
    --relay-user) relay_user="${2:?}"; shift 2 ;;
    --no-merge) merge=0; shift ;;
    --redecide) redecide=1; shift ;;
    --detach) detach=1; shift ;;
    -h | --help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument $1 (see --help)" ;;
  esac
done

[ -n "$data" ] || die "--data FILE is required (the mail-auth JSON data file)"
[ -f "$data" ] || die "no such data file: $data"
[ -n "$key" ] && [ -r "$key" ] || die "--key (or \$GOOGLE_WORKSPACE_KEY): the decrypted service-account key is required and must be readable"
[ -n "$subject" ] || die "--subject (or \$GOOGLE_WORKSPACE_SUBJECT): the super admin the service account acts as"
export GOOGLE_WORKSPACE_KEY="$key" GOOGLE_WORKSPACE_SUBJECT="$subject"

read -r -a resolvers <<<"${GOOGLE_WORKSPACE_DKIM_RESOLVERS:-1.1.1.1 8.8.8.8}"

gwd() { "${domains_cmd[@]}" "$@"; }
api() { "${api_cmd[@]}" --key "$key" --subject "$subject" "$@"; }

# ── the data, as the base branch has it ──────────────────────────────────────

data_abs="$(cd "$(dirname "$data")" && pwd)/$(basename "$data")"
root="" rel="" view=""
if root="$(git -C "$(dirname "$data_abs")" rev-parse --show-toplevel 2>/dev/null)"; then
  rel="${data_abs#"$root"/}"
fi
# The data file as origin/<base> has it (what is or will be applied), falling
# back to the working copy; $view_file holds the same for the tools' read-only
# commands (status, user-addresses), which must not see a stale working copy.
view_file="$(mktemp "${TMPDIR:-/tmp}/$prog.view.XXXXXX")"
setup_cleanup() {
  rm -f "$view_file"
  pr_cleanup_worktrees
}
pr_exit_trap=setup_cleanup
trap setup_cleanup EXIT
refresh_view() {
  view=""
  if [ -n "$root" ] && git -C "$root" remote get-url origin >/dev/null 2>&1; then
    if [ -z "$base" ]; then
      base="$(cd "$root" && gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)" || base=""
    fi
    if [ -n "$base" ] && git -C "$root" fetch --quiet origin "$base" 2>/dev/null; then
      view="$(git -C "$root" show "origin/$base:$rel" 2>/dev/null)" || view=""
    fi
  fi
  [ -n "$view" ] || view="$(cat "$data_abs")"
  printf '%s\n' "$view" >"$view_file"
}
refresh_view

v() { jq -r "$@" <<<"$view"; }
kind_of() { v --arg d "$1" '.domains[$d].google.kind // empty'; }
parent_of() { v --arg d "$1" '.domains[$d].google.parent // empty'; }
pending() { [ "$(v --arg d "$1" '.domains[$d].zone_pending // false')" = true ]; }
has_dkim() { [ "$(v --arg d "$1" '(.domains[$d].dkim // {}) | has("google")')" = true ]; }
mx_hosts() { v --arg d "$1" '(.domains[$d].mx // [])[].host'; }
mx_on_google() {
  local h
  h="$(mx_hosts "$1")"
  [ -n "$h" ] && ! grep -qvE '(^|\.)google\.com$' <<<"$h"
}
users() { if [ -n "$user" ]; then echo "$user"; else v '(.google_users // {}) | keys[]'; fi; }
first_user() {
  local all
  all="$(users)"
  printf '%s' "${all%%$'\n'*}"
}
first_local() { # USER DOMAIN -> the first address of USER there
  local u="$1" l
  l="$(v --arg u "$u" '(.google_users[$u].local_parts // [])[0] // empty')"
  printf '%s@%s' "${l:-${u%@*}}" "$2"
}

# A host that resolves (A or AAAA) on the first resolver.
resolves() {
  local out
  out="$(dig +short +time=5 +tries=2 A "$1" "@${resolvers[0]}" 2>/dev/null; dig +short +time=5 +tries=2 AAAA "$1" "@${resolvers[0]}" 2>/dev/null)" || true
  grep -qE '^[0-9a-fA-F:.]+$' <<<"$out"
}

# class: primary | google | none (no MX) | broken (an MX elsewhere that does
# not resolve) | live. Both broken and live name a mail host outside Google, so
# both wait for the inbound test: the host may only be down for now.
class_of() {
  local d="$1" h
  [ "$(kind_of "$d")" = primary ] && { echo primary; return; }
  if [ -z "$(mx_hosts "$d")" ]; then echo none; return; fi
  if mx_on_google "$d"; then echo google; return; fi
  while IFS= read -r h <&3; do
    [[ $h =~ (^|\.)google\.com$ ]] && continue
    if resolves "$h"; then echo live; return; fi
  done 3< <(mx_hosts "$d")
  echo broken
}
phase_of() { case "$1" in primary) echo 0 ;; google) echo 1 ;; none) echo 2 ;; broken) echo 3 ;; live) echo 4 ;; esac; }

# "<phase> <depth> <domain> <class>" lines in the order to work through.
plan() {
  local d c p k par pp lines=()
  declare -A ph=() cl=()
  while IFS= read -r d <&3; do
    pending "$d" && continue
    k="$(kind_of "$d")"
    [ -n "$k" ] || continue
    c="$(class_of "$d")"
    cl[$d]="$c" ph[$d]="$(phase_of "$c")"
  done 3< <(v '.domains | keys[]')
  for d in "${!ph[@]}"; do
    p="${ph[$d]}"
    par="$(parent_of "$d")"
    if [ -n "$par" ]; then
      pp="${ph[$par]:-0}"
      [ "$pp" -gt "$p" ] && p="$pp"
      lines+=("$p 1 $d ${cl[$d]}")
    else
      lines+=("$p 0 $d ${cl[$d]}")
    fi
  done
  printf '%s\n' "${lines[@]}" | LC_ALL=C sort -k1,1n -k2,2n -k3,3
}
pending_domains() { v '.domains | to_entries[] | select(.value.zone_pending == true) | .key'; }

describe_class() {
  case "$1" in
    primary) echo "the tenant's own" ;;
    google) echo "mail already on Google" ;;
    none) echo "no MX today" ;;
    broken) echo "MX elsewhere, not resolving" ;;
    live) echo "LIVE mail elsewhere" ;;
  esac
}

kind_phrase() {
  case "$(kind_of "$1")" in
    alias) echo "alias of $(parent_of "$1")" ;;
    secondary) echo "secondary" ;;
    primary) echo "primary" ;;
  esac
}

onboard_args() {
  local a=(--data "$data")
  [ -n "$post_edit" ] && a+=(--post-edit "$post_edit")
  [ -n "$base" ] && a+=(--base "$base")
  [ -n "$dmarc_rua" ] && a+=(--dmarc-rua "$dmarc_rua")
  [ -n "$tls_rpt_rua" ] && a+=(--tls-rpt-rua "$tls_rpt_rua")
  [ "$merge" = 1 ] && a+=(--merge)
  printf '%s\0' "${a[@]}"
}

# Runs CMD…; while it fails, says so and offers retry/skip. 0 done, 10 skipped.
retry_loop() {
  local what="$1" w
  shift
  while :; do
    if "$@"; then return 0; fi
    guide_bad "$what stopped (the reason is printed above). Fix it, then retry."
    w=0
    guide_wait "Retry $what?" || w=$?
    [ "$w" = 10 ] && return 10
  done
}

# ── steps ────────────────────────────────────────────────────────────────────

step_scopes() {
  local a=(scopes --guide)
  [ -n "$scopes" ] && a+=(--scopes "$scopes")
  local rc=0
  gwd "${a[@]}" || rc=$?
  [ "$rc" = 0 ] || guide_bad "some delegation scopes are still missing; the steps that need them will stop and name them."
}

report_group() {
  [ -n "$group" ] && { echo "$group"; return; }
  [ -n "$dmarc_rua" ] && { echo "${dmarc_rua#mailto:}"; return; }
  v '[.domains[].dmarc.rua // [] | .[]] | map(sub("^mailto:"; "") | sub("!.*$"; "")) | group_by(.) | max_by(length) | .[0] // empty'
}

step_dmarc_group() {
  local g rc=0
  g="$(report_group)"
  if [ -z "$g" ]; then
    guide_bad "no DMARC report mailbox is known (pass --group); skipping"
    return 0
  fi
  guide_text "The DMARC and TLS-RPT reports go to $g. Receivers outside the organisation send them, so the group must accept external mail."
  # A disabled Groups Settings API is enabled here with gcloud; the guided
  # loop is for what only the console can fix.
  if with_api gwd dmarc-group --group "$g"; then return 0; fi
  gwd dmarc-group --group "$g" --guide || rc=$?
  [ "$rc" = 0 ] || guide_bad "$g may still refuse reports from outside."
}

activate_gmail() {
  local d="$1" w
  guide_h2 "Activate Gmail for $d"
  guide_step 1 "Open https://admin.google.com/ac/domains/manage"
  guide_step 2 "Find $d in the list. If its row offers 'Activate Gmail' (or 'Set up Gmail'), click it and follow it to the end; Google checks the MX record it now finds (smtp.google.com)."
  guide_step 3 "If the row shows no such link, Gmail is already active for $d: nothing to do."
  guide_text "Success looks like: the row shows 'Gmail activated' or no Gmail action. This tool then checks that $d is verified and public DNS serves its records."
  while :; do
    w=0
    guide_wait "Done with $d in the console?" || w=$?
    [ "$w" = 10 ] && return 10
    if gwd status --domain "$d" --data "$view_file" >/dev/null 2>&1; then
      guide_ok "$d is verified and every record of it is served"
      return 0
    fi
    gwd status --domain "$d" --data "$view_file" 2>&1 | sed 's/^/   /' || true
    guide_bad "$d does not look ready yet (above). Records can take a few minutes to appear on every resolver; Activate Gmail can take up to an hour."
  done
}

addresses_for() { # DOMAIN
  local d="$1" u rc=0 w a=()
  [ -n "$(users)" ] || { guide_text "No users to give addresses (no google_users in the data, no --user)."; return 0; }
  case "$(kind_of "$d")" in secondary | alias) ;; *) return 0 ;; esac
  guide_h2 "Addresses and send-as on $d"
  while :; do
    rc=0
    while IFS= read -r u <&3; do
      a=(user-addresses --user "$u" --domain "$d" --data "$view_file")
      gwd "${a[@]}" || rc=$?
    done 3< <(users)
    [ "$rc" = 0 ] && { guide_ok "every address on $d is in place and can send"; return 0; }
    [ "$rc" = 2 ] || guide_bad "the addresses step failed (above)"
    guide_text "A 'pending' send-as means Gmail mailed a confirmation link to that address: open the user's Gmail, find the message 'Gmail Confirmation - Send Mail as …', click the link. A 'skipped' domain is not verified on the tenant yet."
    w=0
    guide_wait "Re-check the addresses on $d?" || w=$?
    [ "$w" = 10 ] && return 10
  done
}

# Before mail that goes elsewhere today is moved: proof that a domain already
# switched to Google receives mail from outside.
gate_passed=0
inbound_gate() {
  local probe="" d u ans
  [ "$gate_passed" = 1 ] && return 0
  while IFS= read -r d <&3; do
    case "$(kind_of "$d")" in secondary | alias) ;; *) continue ;; esac
    [ "$(mx_hosts "$d")" = smtp.google.com ] || continue
    probe="$d"
    break
  done 3< <(v '.domains | keys[]')
  u="$(first_user)"
  guide_h2 "Before switching a domain that receives mail today"
  if [ -z "$probe" ]; then
    guide_text "No secondary or alias domain of this tenant has been switched to smtp.google.com yet, so nothing proves that Google accepts mail for a newly added domain. Onboard a domain with no MX first (its turn comes earlier), send the test there, then re-run."
    return 10
  fi
  guide_step 1 "From a mailbox OUTSIDE this tenant (a personal account), send a message to $(first_local "${u:-postmaster@x}" "$probe")."
  guide_step 2 "Wait a minute, then look for it in ${u:-the user}'s Gmail inbox (also Spam)."
  while :; do
    ans="$(guide_ask "Did a test message from outside arrive at a domain already on smtp.google.com?" y n s)" || exit $?
    case "$ans" in
      y) gate_passed=1; return 0 ;;
      s) return 10 ;;
      n)
        guide_text "Then do not switch more mail yet. Check, for $probe: Activate Gmail was clicked; 'google-workspace-domains status --domain $probe' is OK; the address exists (the user-addresses step). Send another test, then answer y."
        ;;
    esac
  done
}

dkim_for() { # DOMAIN
  local d="$1" ans w a sender u
  has_dkim "$d" && { guide_ok "$d already publishes a DKIM key (selector google)"; return 0; }
  guide_h2 "DKIM for $d"
  guide_text "Google signs mail from $d with $d's own key only once the key is published and authentication is started. The key is generated in the Admin console (Google has no API for it); Google may offer it only 24-48 hours after Gmail is activated for the domain."
  ans="$(guide_ask "Generate and publish $d's DKIM key now? (s = later; the dkim-all step resumes it)" y s)" || exit $?
  [ "$ans" = y ] || return 10
  a=(publish --domain "$d" --data "$data" --no-open)
  [ -n "$dkim_post_edit" ] && a+=(--post-edit "$dkim_post_edit")
  [ -n "$base" ] && a+=(--base "$base")
  [ "$merge" = 1 ] && a+=(--merge)
  guide_step 1 "Open https://admin.google.com/ac/apps/gmail/authenticateemail"
  guide_step 2 "Under 'Selected domain' pick $d."
  guide_step 3 "Click 'GENERATE NEW RECORD'. DKIM key bit length: 2048. Prefix selector: google. Click GENERATE."
  guide_step 4 "Copy the whole 'TXT record value' (v=DKIM1; k=rsa; p=…) and paste it below, then press Enter on an empty line. Do NOT click 'Start authentication' yet."
  retry_loop "publishing DKIM for $d" "${dkim_cmd[@]}" "${a[@]}" || return 10
  refresh_view
  guide_h2 "Start DKIM authentication for $d"
  guide_step 1 "Back at https://admin.google.com/ac/apps/gmail/authenticateemail, with $d selected, click 'START AUTHENTICATION'."
  guide_text "Success looks like: the status reads 'Authenticating email with DKIM'."
  w=0
  guide_wait "Clicked 'Start authentication' for $d?" || w=$?
  [ "$w" = 10 ] && return 10
  u="$(first_user)"
  if [ -n "$test_to" ] && [ -n "$u" ] && [ "$(kind_of "$d")" != primary ]; then
    sender="$(first_local "$u" "$d")"
    if api send-test "$u" "$sender" "$test_to" >/dev/null; then
      guide_text "Sent a test message from $sender to $test_to through the Gmail API. Open it there and show the original (Gmail: More > Show original)."
      while :; do
        ans="$(guide_ask "Does it say DKIM 'PASS' with domain $d (DKIM-Signature d=$d)?" y n s)" || exit $?
        case "$ans" in
          y) guide_ok "DKIM signs mail from $d"; return 0 ;;
          s) return 10 ;;
          n) guide_text "Signing starts up to 48 hours after 'Start authentication' (usually within an hour). 'd=…gappssmtp.com' means Google does not sign with $d's key yet. Send another test later: google-workspace-setup dkim-all." ;;
        esac
      done
    fi
  else
    guide_text "To check: send a message from an address at $d to an outside mailbox and look for 'DKIM: PASS with domain $d' in the original."
  fi
}

domain_flow() { # DOMAIN CLASS N TOTAL WITH_DKIM
  local d="$1" c="$2" n="$3" total="$4" with_dkim="$5" ans a=() w
  guide_h1 "Domain $n/$total: $d ($(kind_phrase "$d"); $(describe_class "$c"))"
  if { [ "$c" = live ] || [ "$c" = broken ]; } && ! mx_on_google "$d"; then
    if [ "$c" = live ]; then
      guide_text "$d receives mail at $(mx_hosts "$d" | paste -sd, -) today. Onboarding switches its MX to Google: from then on ALL mail for $d goes to Google, and the old server stops receiving."
    else
      guide_text "$d's MX names $(mx_hosts "$d" | paste -sd, -), which does not resolve now (no mail arrives). Onboarding switches its MX to Google: from then on ALL mail for $d goes to Google, even once that host is back."
    fi
    guide_step 1 "Export what matters from the old mailboxes."
    guide_step 2 "Make sure every address in use there exists on the tenant (a user alias, a group, or the user-addresses step) — an address that exists nowhere bounces."
    w=0
    inbound_gate || w=$?
    if [ "$w" = 10 ]; then
      guide_bad "skipping $d: no inbound test confirmed yet"
      return 0
    fi
    ans="$(guide_ask "Switch $d's mail to Google now?" yes s)" || exit $?
    [ "$ans" = yes ] || { guide_bad "skipped $d; re-run to come back to it"; return 0; }
  fi
  mapfile -d '' -t a < <(onboard_args)
  retry_loop "onboarding $d" gwd onboard --domain "$d" "${a[@]}" || { guide_bad "skipped $d"; return 0; }
  refresh_view
  if [ "$c" != primary ] && [ "$c" != google ]; then
    activate_gmail "$d" || guide_bad "Activate Gmail for $d not confirmed"
  fi
  addresses_for "$d" || guide_bad "addresses on $d not finished"
  if [ "$with_dkim" = 1 ]; then
    dkim_for "$d" || guide_bad "DKIM for $d left for later"
  fi
}

step_domains() { # WITH_DKIM
  local with_dkim="$1" lines=() line p _depth d c i=0 skipped
  mapfile -t lines < <(plan)
  guide_text "The domains, in the order they are taken:"
  for line in "${lines[@]}"; do
    read -r p _depth d c <<<"$line"
    printf '   %-20s %s; %s\n' "$d" "$(kind_phrase "$d")" "$(describe_class "$c")"
  done
  while IFS= read -r skipped <&3; do
    [ -n "$skipped" ] && printf '   %-20s %s; SKIPPED: zone pending\n' "$skipped" "$(kind_phrase "$skipped")"
  done 3< <(pending_domains)
  for line in "${lines[@]}"; do
    i=$((i + 1))
    read -r p _depth d c <<<"$line"
    domain_flow "$d" "$c" "$i" "${#lines[@]}" "$with_dkim"
  done
}

step_user_addresses() {
  local u rc w
  while :; do
    rc=0
    while IFS= read -r u <&3; do
      gwd user-addresses --user "$u" --all-domains --data "$view_file" || rc=$?
    done 3< <(users)
    [ "$rc" = 0 ] && { guide_ok "every address is in place and can send"; return 0; }
    guide_text "'pending': open the user's Gmail, find 'Gmail Confirmation - Send Mail as …' and click the link. 'skipped': the domain is not verified on the tenant yet (onboard-all)."
    w=0
    guide_wait "Re-check the addresses?" || w=$?
    [ "$w" = 10 ] && return 0
  done
}

step_dkim_all() {
  local d any=0
  while IFS= read -r d <&3; do
    pending "$d" && continue
    [ -n "$(kind_of "$d")" ] || continue
    has_dkim "$d" && continue
    # Only a domain whose mail is on Google can have a Google DKIM key.
    mx_on_google "$d" || { guide_text "$d: mail not on Google yet; DKIM comes after onboarding."; continue; }
    any=1
    dkim_for "$d" || guide_bad "DKIM for $d left for later"
  done 3< <(v '.domains | keys[]')
  [ "$any" = 1 ] || guide_ok "every onboarded domain publishes a DKIM key"
}

step_smtp_relay() {
  local w ru from pw out
  ru="${relay_user:-$(first_user)}"
  ru="${ru:-$subject}"
  guide_text "Two ways to send automated mail through Google:"
  guide_text "  a) the Gmail API, as a user, through this service account (scope gmail.send) — no console step; the DKIM step's test message goes this way;"
  guide_text "  b) the SMTP relay smtp-relay.gmail.com for servers and apps — console only, set up here."
  guide_step 1 "Open https://admin.google.com/ac/apps/gmail/routing"
  guide_step 2 "Find 'SMTP relay service' and click CONFIGURE (or ADD ANOTHER RULE if one exists)."
  guide_step 3 "Description: automated sending"
  guide_step 4 "'1. Allowed senders': Only addresses in my domains."
  guide_step 5 "'2. Authentication': tick 'Require SMTP Authentication'. Leave 'Only accept mail from the specified IP addresses' unticked (or tick it and add your servers' IPs)."
  guide_step 6 "'3. Encryption': tick 'Require TLS encryption'."
  guide_step 7 "Click SAVE, then SAVE at the bottom of the Routing page."
  guide_text "Success looks like: an 'automated sending' rule under SMTP relay service. Changes take effect within an hour (rarely 24)."
  guide_text "Senders then use: smtp-relay.gmail.com, port 587, STARTTLS, a Workspace user's address and an APP password (https://myaccount.google.com/apppasswords; needs 2-Step Verification). Limits: 10,000 recipients per user per day; 'Only addresses in my domains' means From: must be in a tenant domain."
  while :; do
    w=0
    guide_wait "Saved the SMTP relay rule?" || w=$?
    [ "$w" = 10 ] && return 0
    if [ -z "$test_to" ]; then
      guide_text "No --test-to address: not testing. Re-run this step with --test-to <an address outside the tenant> to send a test through the relay."
      return 0
    fi
    from="$ru"
    printf '\n>> To test, type an app password for %s (hidden), or s to skip: ' "$ru" >&2
    pw=""
    if [ -t 0 ]; then IFS= read -rs pw || true; else IFS= read -r pw || true; fi
    printf '\n' >&2
    if [ -z "$pw" ] || [ "$pw" = s ]; then
      guide_text "Not tested."
      return 0
    fi
    if out="$(SMTP_RELAY_PASSWORD="$pw" api smtp-test "$ru" "$from" "$test_to" 2>&1)"; then
      pw=""
      guide_ok "the relay accepted a message from $from to $test_to; check that it arrived"
      return 0
    fi
    pw=""
    guide_bad "${out#*: }"
  done
}

step_status() {
  local u
  u="$(first_user)"
  refresh_view
  gwd status --all --table --data "$view_file" ${u:+--user "$u"} || true
  follower_status
}

steps_total=6
n_step=0
header() {
  n_step=$((n_step + 1))
  guide_h1 "Step $n_step of $steps_total: $*"
}

state_init
[ "$step" = follow ] || interactive=1

case "$step" in
  run) cmd_run ;;
  follow)
    if [ "$detach" = 1 ]; then
      start_follower
    else
      cmd_follow
    fi
    ;;
  guided)
    guide_h1 "Google Workspace setup: $(basename "$data")"
    guide_text "Everything below is checked live first; finished steps are skipped. Answers: Enter = done, verify now; s = skip; q = quit (re-run to resume)."
    header "delegation scopes" && step_scopes
    header "DMARC report group" && step_dmarc_group
    header "domains (onboard, addresses, DKIM)" && step_domains 1
    header "every user's addresses" && step_user_addresses
    header "SMTP relay for automated sending" && step_smtp_relay
    header "status" && step_status
    ;;
  scopes) step_scopes ;;
  dmarc-group) step_dmarc_group ;;
  onboard-all) step_domains 0 ;;
  user-addresses) step_user_addresses ;;
  dkim-all) step_dkim_all ;;
  smtp-relay) step_smtp_relay ;;
  status) step_status ;;
esac
