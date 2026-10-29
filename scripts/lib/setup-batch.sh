# shellcheck shell=bash
# The setup wizard's globals (data, view, base, key, …) are the caller's:
# shellcheck disable=SC2154
# shellcheck disable=SC2016 # jq programs
# The batched setup of google-workspace-setup: an INTERACTIVE phase (`run`)
# that does every instant step and collects every console-only input in one
# sitting, then opens ONE PR with the DNS changes that are due now; and a
# BACKGROUND phase (`follow`) that lands that PR, waits for DNS, asks Google to
# verify, and opens the next batch PR for what has become possible — until
# nothing is left that the operator does not have to do by hand.
#
# THE BATCHES. Every batch PR carries ONE kind of change, and the kinds come
# in this order (a later kind waits while an earlier one is due):
#
#   1. verification   the Site Verification TXT token of every declared domain
#                     that is not verified yet — aliases included, even before
#                     the tenant has them (a token needs no tenant)
#   (Google verifies: webResource.insert for each domain on the tenant whose
#    token is served, then the Directory is polled. An ALIAS is added to the
#    tenant only once its parent is verified — Google refuses it before, HTTP
#    409 — and Site Verification is asked again once the alias exists. Its
#    Workspace verification can lag hours behind; the follower keeps asking.)
#   2. records        MX/SPF/DMARC/TLS-RPT of verified domains whose mail goes
#                     nowhere else today (no MX, or already Google). A no-mail
#                     alias may go once its parent is verified and Site
#                     Verification accepted its token, even while Workspace
#                     still reports it unverified (the Admin console shows
#                     "setup incomplete" for an alias until its MX is Google's)
#   (the inbound test: the operator sends a message from a mailbox OUTSIDE the
#    tenant to a domain already moved; the tool finds it in the inbox)
#   3. records-live   the same for domains whose mail goes elsewhere today, as
#                     the operator decided, only after the inbound test passed
#   (the users' addresses and send-as, on every verified domain whose MX is
#    Google's)
#   4. dkim           the DKIM keys pasted in one sitting (Activate Gmail first:
#                     the console offers a key only after it), then the
#                     reminder to click Start authentication once DNS serves
#                     them
#
# Sourced by google-workspace-setup after lib/pr-publish.sh and lib/guide.sh.
#
# STATE. Everything the background phase needs that is neither in the data
# file, nor on the tenant, nor in DNS lives in a local JSON file that is never
# committed: $GOOGLE_WORKSPACE_STATE_DIR, default
# ${XDG_STATE_HOME:-~/.local/state}/google-workspace-setup/<tenant>.json:
#
#   decisions  {domain: "switch"|"hold"}   the operator's answer, per domain
#              whose mail goes elsewhere today, to "move its MX once verified?"
#   dkim       {domain: value}             DKIM values pasted but not yet on
#              the base branch (public keys)
#   inbound    {ok, via, domain, at}       the proof that a domain moved to
#              Google receives mail from outside (gmail-api | operator)
#   site_ok    {domain: true}              Site Verification accepted the
#              domain's token (webResource.insert succeeded)
#   verify_wait {domain: epoch}            since when the follower waits for
#              Google to report the domain verified
#   batch      {n, stage, branch, pr, items, added, removed}  the batch PR in
#              flight
#   follower   {pid | unit, log, started}  the background process
#   todo       {activate_gmail: [d], start_auth: [d]}  console steps the
#              batches made due, shown and confirmed at the next `run`
#   summary    [line]                      what the last follower left
#
# Everything else is re-read every time (the data file on origin/<base>, the
# tenant, DNS), so both phases are idempotent and resume after interruption.

state_dir="${GOOGLE_WORKSPACE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/google-workspace-setup}"
# The DNS wait's settings, read by lib/pr-publish.sh.
# shellcheck disable=SC2034
dns_timeout="${GOOGLE_WORKSPACE_DOMAINS_DNS_TIMEOUT:-1800}"
# shellcheck disable=SC2034
dns_interval="${GOOGLE_WORKSPACE_DKIM_DNS_INTERVAL:-30}"
verify_timeout="${GOOGLE_WORKSPACE_DOMAINS_VERIFY_TIMEOUT:-900}"
verify_interval="${GOOGLE_WORKSPACE_DOMAINS_VERIFY_INTERVAL:-30}"
# Set, it bounds each round's wait by that many Directory reads rather than
# by $verify_timeout (see google-workspace-domains.sh).
verify_tries="${GOOGLE_WORKSPACE_DOMAINS_VERIFY_TRIES:-}"
interactive=0
state_file="" log_file="" lockd=""

tenant_name() {
  local p
  p="$(v '[.domains | to_entries[] | select(.value.google.kind == "primary") | .key] | first // empty')"
  printf '%s' "${p:-${subject#*@}}"
}

state_init() {
  local t
  t="$(tenant_name)"
  mkdir -p "$state_dir"
  state_file="$state_dir/$t.json" log_file="$state_dir/$t.log" lockd="$state_dir/$t.lock"
  [ -s "$state_file" ] || printf '{"version": 1}\n' >"$state_file"
}

# st JQ [ARGS…]: read the state.
st() { jq -r "$@" "$state_file"; }

# The state is written by both phases; every write holds a lock (a directory,
# which mkdir creates atomically everywhere).
st_lock() {
  local i=0
  until mkdir "$lockd" 2>/dev/null; do
    i=$((i + 1))
    # A lock older than a minute is a crashed writer's.
    [ "$i" -lt 600 ] || rm -rf "$lockd"
    sleep 0.1
  done
}
st_unlock() { rmdir "$lockd" 2>/dev/null || true; }
st_write() { # JQ [ARGS…], the lock held
  local tmp
  tmp="$(mktemp "$state_file.XXXXXX")"
  if jq "$@" "$state_file" >"$tmp"; then
    mv "$tmp" "$state_file"
  else
    rm -f "$tmp"
    st_unlock
    die "could not update $state_file"
  fi
}
# st_set JQ [ARGS…]: update the state.
st_set() {
  st_lock
  st_write "$@"
  st_unlock
}

# claim_batch BATCH_JSON: records the batch unless one is in flight already
# (the other phase opened it meanwhile); 1 then.
claim_batch() {
  st_lock
  if [ -n "$(st '.batch.n // empty')" ]; then
    st_unlock
    return 1
  fi
  st_write --argjson b "$1" '.batches = $b.n | .batch = $b'
  st_unlock
}

# claim_follower: this process becomes the follower unless a live one is.
claim_follower() {
  local pid
  st_lock
  pid="$(st '.follower.pid // empty')"
  if [ -n "$pid" ] && [ "$pid" != "$$" ] && kill -0 "$pid" 2>/dev/null; then
    st_unlock
    return 1
  fi
  st_write --argjson p "$$" --arg t "$(now_utc)" --arg l "$log_file" \
    '.follower = ((.follower // {}) | del(.state) + {pid: $p, started: $t, log: $l, state: "running"})'
  st_unlock
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# log MSG: a timestamped progress line on stderr (the follower's log), also
# kept as the follower's current stage for `status`.
log() {
  if [ "$interactive" = 1 ]; then
    say "$*"
    return 0
  fi
  printf '[%s] %s\n' "$(now_utc)" "$*" >&2
  st_set --arg m "$*" --arg t "$(now_utc)" '.follower.last = {at: $t, msg: $m}'
}

notify() { # TITLE BODY
  [ -n "${GOOGLE_WORKSPACE_NOTIFY:-}" ] || return 0
  printf '%s\n' "$2" | NOTIFY_TITLE="$1" bash -c "$GOOGLE_WORKSPACE_NOTIFY" >/dev/null 2>&1 || true
}

# ── gcloud: enable an API, re-authenticating when needed ─────────────────────

project_id() { jq -r '.project_id // empty' "$key" 2>/dev/null || true; }

# ensure_api SERVICE: `gcloud services enable SERVICE` in the key's project
# (gcloud_run: a fresh `gcloud auth login` first when needed, interactive phase
# only). Prints the manual steps only when the account lacks the permission.
ensure_api() {
  local svc="$1" p out
  p="$(project_id)"
  guide_text "The $svc API is not enabled in project ${p:-<project>}; enabling it."
  if ! command -v gcloud >/dev/null; then
    guide_bad "gcloud is not on PATH. Enable it at https://console.cloud.google.com/apis/library/$svc?project=$p (ENABLE), then re-run."
    return 1
  fi
  if out="$(gcloud_run services enable "$svc" --project "$p" 2>&1)"; then
    guide_ok "enabled $svc in $p (it can take a minute to reach the API)"
    sleep "${GOOGLE_WORKSPACE_API_ENABLE_WAIT:-20}"
    return 0
  fi
  printf '%s\n' "$out" | sed 's/^/   /' >&2
  if grep -qiE 'reauth|re-authenticat|refreshing your current auth tokens|no credentialed accounts|gcloud auth login' <<<"$out"; then
    todo_line "gcloud needs a fresh login to enable $svc: run the interactive setup again (it logs in)"
  elif grep -qiE 'PERMISSION_DENIED|does not have permission|AUTH_PERMISSION_DENIED|forbidden' <<<"$out"; then
    guide_bad "your gcloud account ($(gcloud config get-value account 2>/dev/null || echo '?')) may not enable APIs in $p. Someone with roles/serviceusage.serviceUsageAdmin there enables $svc (https://console.cloud.google.com/apis/library/$svc?project=$p)."
  fi
  return 1
}

# with_api CMD…: runs CMD; when it fails because a Google API is disabled (the
# helper's message carries "gcloud services enable X --project P"), enables X
# and runs CMD once more. stdout is CMD's; its stderr is passed on.
with_api() {
  local err rc=0 svc
  err="$(mktemp)"
  "$@" 2>"$err" || rc=$?
  if [ "$rc" != 0 ] && svc="$(sed -n 's/.*gcloud services enable \([a-z0-9.-]*\) --project.*/\1/p' "$err" | head -n1)" && [ -n "$svc" ]; then
    cat "$err" >&2
    rm -f "$err"
    ensure_api "$svc" >&2 || return "$rc"
    "$@"
    return
  fi
  cat "$err" >&2
  rm -f "$err"
  return "$rc"
}

# gcloud_run ARGS…: gcloud ARGS, with a `gcloud auth login` first when its
# credentials have expired (the organisation's reauthentication policy) or
# there are none — in the interactive phase only; the operator is never asked
# to type a gcloud command this tool can run. Output on stdout; 1 on failure.
gcloud_run() {
  local out try
  for try in 1 2; do
    if out="$(gcloud "$@" 2>&1)"; then
      printf '%s\n' "$out"
      return 0
    fi
    if grep -qiE 'reauth|re-authenticat|refreshing your current auth tokens|no credentialed accounts|do not currently have an active account|gcloud auth login' <<<"$out" &&
      [ "$interactive" = 1 ] && [ "$try" = 1 ]; then
      guide_text "gcloud's credentials have expired (or there are none); running 'gcloud auth login' here — it opens a browser or prints a URL to open."
      gcloud auth login >&2 || true
      continue
    fi
    printf '%s\n' "$out" >&2
    return 1
  done
  return 1
}

# The Google APIs the tools call, enabled in the service account's project
# before anything else ($GOOGLE_WORKSPACE_APIS overrides the list): the Admin
# SDK, Gmail, Site Verification, Groups Settings, and the Org Policy API (the
# key's creation and rotation check the organisation's key policy).
workspace_apis="${GOOGLE_WORKSPACE_APIS:-admin.googleapis.com gmail.googleapis.com siteverification.googleapis.com groupssettings.googleapis.com orgpolicy.googleapis.com}"

# preflight_apis: every API of $workspace_apis enabled, through gcloud.
preflight_apis() {
  local p enabled missing=() a
  command -v gcloud >/dev/null || {
    guide_text "gcloud is not on PATH: not checking the project's APIs (a call to a disabled one says which to enable)."
    return 0
  }
  p="$(project_id)"
  [ -n "$p" ] || return 0
  if ! enabled="$(gcloud_run services list --enabled --project "$p" --format 'value(config.name)')"; then
    guide_bad "could not list the APIs enabled in $p (above); a call to a disabled one will name it"
    return 0
  fi
  for a in $workspace_apis; do
    grep -qxF "$a" <<<"$enabled" || missing+=("$a")
  done
  if [ "${#missing[@]}" = 0 ]; then
    guide_ok "the APIs the tools call are enabled in $p"
    return 0
  fi
  guide_text "Enabling in project $p: ${missing[*]}"
  if gcloud_run services enable "${missing[@]}" --project "$p" >/dev/null; then
    guide_ok "enabled ${missing[*]} (it can take a minute to reach the APIs)"
    sleep "${GOOGLE_WORKSPACE_API_ENABLE_WAIT:-20}"
  else
    guide_bad "your gcloud account ($(gcloud config get-value account 2>/dev/null || echo '?')) could not enable them (above). Someone with roles/serviceusage.serviceUsageAdmin on $p enables them; the steps that need one stop and name it."
  fi
}

# ── what the tenant and GitHub say ───────────────────────────────────────────

declare -A tstate=()
# ts_load DOMAIN: the API helper's state JSON for DOMAIN into ${tstate[DOMAIN]},
# once per round (not in a subshell, so the cache survives).
ts_load() {
  [ -n "${tstate[$1]:-}" ] && return 0
  tstate[$1]="$(with_api api state "$1")" || {
    unset "tstate[$1]"
    return 1
  }
}
forget_tenant() { tstate=(); }
verified_on_tenant() { ts_load "$1" && [ "$(jq -r .verified <<<"${tstate[$1]}")" = true ]; }
on_tenant() { ts_load "$1" && [ "$(jq -r .kind <<<"${tstate[$1]}")" != absent ]; }
tenant_kind() { ts_load "$1" && jq -r .kind <<<"${tstate[$1]}"; }

# Domains another open PR changes — a per-domain one (google-workspace-domains
# onboard, google-workspace-dkim publish) or one made by hand: a batch leaves
# them to it rather than conflict with it. An open PR claims every domain whose
# entry in the data file its head changes against origin/<base>; a PR whose
# head cannot be fetched claims the domain its branch name says
# (mail/<d>-verification, mail/<d>-records, dkim/<d>-<selector>).
declare -A legacy_pr=()
load_legacy_prs() {
  local n b d theirs
  legacy_pr=()
  [ -n "$root" ] || return 0
  while read -r n b; do
    [ -n "$b" ] || continue
    case "$b" in mail/google-batch-*) continue ;; esac
    if git -C "$root" fetch --quiet origin "$b" 2>/dev/null &&
      theirs="$(git -C "$root" show "FETCH_HEAD:$rel" 2>/dev/null)"; then
      while IFS= read -r d; do
        [ -n "$d" ] && legacy_pr[$d]="#$n ($b)"
      done < <(jq -rn --argjson a "$view" --argjson b "$theirs" \
        '($a.domains // {}) as $x | ($b.domains // {}) as $y
         | [($x + $y) | keys[] | select($x[.] != $y[.])] | .[]' 2>/dev/null)
      continue
    fi
    case "$b" in
      mail/*-verification) d="${b#mail/}" d="${d%-verification}" ;;
      mail/*-records) d="${b#mail/}" d="${d%-records}" ;;
      dkim/*-*) d="${b#dkim/}" d="${d%-*}" ;;
      *) continue ;;
    esac
    legacy_pr[$d]="#$n ($b)"
  done < <(cd "$root" && gh pr list --base "$base" --state open --limit 100 --json number,headRefName -q '.[] | "\(.number) \(.headRefName)"' 2>/dev/null || true)
}

declared_domains() { # every domain with a kind, not zone_pending
  v '.domains | to_entries[] | select((.value.zone_pending // false) | not) | select(.value.google.kind != null) | .key'
}

rec_flags() {
  local a=()
  [ -n "$dmarc_rua" ] && a+=(--dmarc-rua "$dmarc_rua")
  [ -n "$tls_rpt_rua" ] && a+=(--tls-rpt-rua "$tls_rpt_rua")
  printf '%s\0' "${a[@]}"
}

records_due() { # DOMAIN: the data on origin/<base> lacks its mail records
  local flags=()
  mapfile -d '' -t flags < <(rec_flags)
  gwd edit --phase records --domain "$1" --data "$view_file" --dry-run "${flags[@]}" >/dev/null 2>&1
}

moves_mail() { # DOMAIN: its MX names a host outside Google today
  [ -n "$(mx_hosts "$1")" ] && ! mx_on_google "$1"
}

# The domain an inbound test can go to: a secondary or alias domain whose MX
# is smtp.google.com alone on the base branch, verified on the tenant.
probe_domain() {
  local d
  while IFS= read -r d <&3; do
    case "$(kind_of "$d")" in secondary | alias) ;; *) continue ;; esac
    [ "$(mx_hosts "$d")" = smtp.google.com ] || continue
    verified_on_tenant "$d" || continue
    printf '%s' "$d"
    return 0
  done 3< <(declared_domains)
  return 1
}

inbound_ok() { [ "$(st '.inbound.ok // false')" = true ]; }

# Site Verification accepted DOMAIN's token (webResource.insert succeeded),
# whatever the Directory says yet.
site_ok() { [ "$(st --arg d "$1" '.site_ok[$d] // false')" = true ]; }

# The key is still there: a host restart empties $XDG_RUNTIME_DIR, where an
# unlocked key usually lives.
key_present() { [ -r "$key" ]; }
key_gone_msg() {
  printf 'the service-account key %s is gone (a restart empties $XDG_RUNTIME_DIR, where it was unlocked)%s' \
    "$key" "${GOOGLE_WORKSPACE_KEY_UNLOCK:+; unlock it again: $GOOGLE_WORKSPACE_KEY_UNLOCK}"
}

# ── the plan: every DNS change that can be made now ──────────────────────────

notes=()
note() { notes+=("$*"); }

# plan_batch: sets $plan_items to the JSON list of changes for the next batch
# PR, and $notes to what is held back and why.
plan_items="[]"
foreign_due=()
# plan_batch: sets $plan_items to the JSON list of changes for the next batch
# PR — every change of the FIRST kind that has any due, in the order
# verification, records, records-live, dkim — $plan_stage to that kind, and
# $notes to what is held back and why.
plan_items="[]"
plan_stage=""
foreign_due=()
plan_batch() {
  local d k tok par dec queued item
  local -A by=([verification]="[]" [records]="[]" [records-live]="[]" [dkim]="[]")
  notes=() foreign_due=()
  load_legacy_prs
  add_item() { by[$1]="$(jq -c --argjson i "$2" '. + [$i]' <<<"${by[$1]}")"; }
  while IFS= read -r d <&3; do
    k="$(kind_of "$d")"
    if [ -n "${legacy_pr[$d]:-}" ]; then
      note "$d: left to the open PR ${legacy_pr[$d]}"
      # Work is due for it once that PR lands: the follower waits for it.
      if ! verified_on_tenant "$d" || records_due "$d"; then foreign_due+=("$d"); fi
      continue
    fi
    if ! verified_on_tenant "$d"; then
      # The token does not need the tenant to have the domain: an alias's is
      # published with everyone's, before Google lets the alias be added.
      tok="$(with_api api token "$d")" || {
        note "$d: no verification token (above)"
        continue
      }
      if ! v --arg d "$d" --arg t "$tok" '(.domains[$d].google_verification // []) | index([$t])' | grep -q '^[0-9]'; then
        add_item verification "$(jq -cn --arg d "$d" --arg t "$tok" '{domain: $d, change: "verification", token: $t}')"
        continue
      fi
      if [ "$k" = alias ]; then
        par="$(parent_of "$d")"
        if ! verified_on_tenant "$par"; then
          note "$d: waits for its parent $par to be verified (Google adds an alias only to a verified parent)"
          continue
        fi
        if ! on_tenant "$d"; then
          note "$d: not on the tenant yet (added as an alias of $par next)"
          continue
        fi
        # A no-mail alias whose token Site Verification accepted goes on:
        # Workspace's own verification of an alias lags, sometimes by hours.
        if site_ok "$d" && records_due "$d" && ! moves_mail "$d"; then
          add_item records "$(jq -cn --arg d "$d" --arg c "$(class_of "$d")" '{domain: $d, change: "records", class: $c}')"
          note "$d: Site Verification accepted its token; Workspace does not report it verified yet (an alias's verification lags), its mail records go ahead"
          continue
        fi
      fi
      note "$d: not verified yet"
      continue
    fi
    if [ "$k" = alias ]; then
      par="$(parent_of "$d")"
      if ! verified_on_tenant "$par"; then
        note "$d: waits for its parent $par to be verified"
        continue
      fi
    fi
    if records_due "$d"; then
      item="$(jq -cn --arg d "$d" --arg c "$(class_of "$d")" '{domain: $d, change: "records", class: $c}')"
      if moves_mail "$d"; then
        dec="$(st --arg d "$d" '.decisions[$d] // empty')"
        if [ "$dec" != switch ]; then
          note "$d: mail stays at $(mx_hosts "$d" | paste -sd, -) (${dec:-no decision yet}: answer in the interactive setup)"
        elif ! inbound_ok; then
          note "$d: switches once a message from OUTSIDE the tenant has reached a domain already moved (the inbound test)"
        else
          add_item records-live "$item"
        fi
      else
        add_item records "$item"
      fi
    fi
    queued="$(st --arg d "$d" '.dkim[$d] // empty')"
    if [ -n "$queued" ] && [ "$(v --arg d "$d" '(.domains[$d].dkim // {}).google // empty')" != "$queued" ]; then
      add_item dkim "$(jq -cn --arg d "$d" --arg v "$queued" '{domain: $d, change: "dkim", value: $v}')"
    fi
  done 3< <(declared_domains)
  plan_items="[]" plan_stage=""
  for k in verification records records-live dkim; do
    [ "${by[$k]}" = "[]" ] && continue
    if [ -z "$plan_stage" ]; then
      plan_stage="$k" plan_items="${by[$k]}"
    else
      note "next, once batch '$plan_stage' has landed: $(describe_items "${by[$k]}" | paste -sd';' -)"
    fi
  done
}

describe_items() { # ITEMS -> one line per kind of change
  jq -r '
    def names(f): [.[] | select(f) | .domain] | join(", ");
    (if names(.change == "verification") != "" then "verification TXT for " + names(.change == "verification") else empty end),
    (if names(.change == "records" and ((.class // "") | IN("live", "broken") | not)) != "" then "mail records (MX, SPF, DMARC, TLS-RPT) for " + names(.change == "records" and ((.class // "") | IN("live", "broken") | not)) else empty end),
    (if names(.change == "records" and ((.class // "") | IN("live", "broken"))) != "" then "mail records, MOVING mail that goes elsewhere today, for " + names(.change == "records" and ((.class // "") | IN("live", "broken"))) else empty end),
    (if names(.change == "dkim") != "" then "DKIM key (selector google) for " + names(.change == "dkim") else empty end)' <<<"$1"
}

# ── the batch PR ─────────────────────────────────────────────────────────────

batch_items=""
# EDIT_FN for pr_commit_branch: every change of $batch_items, then the hook once.
batch_edit() {
  local f="$1" wt="$2" before after added removed item d ch rc changed=0 hook ff=() tmp
  mapfile -d '' -t ff < <(rec_flags)
  before="$(jq -L "$lib" -r 'include "mail-auth"; mail_auth_addresses' "$f" | sort)"
  while IFS= read -r item <&3; do
    d="$(jq -r .domain <<<"$item")" ch="$(jq -r .change <<<"$item")"
    rc=0
    case "$ch" in
      verification) gwd edit --phase verification --domain "$d" --token "$(jq -r .token <<<"$item")" --data "$f" || rc=$? ;;
      records) gwd edit --phase records --domain "$d" --data "$f" "${ff[@]}" || rc=$? ;;
      dkim)
        tmp="$(mktemp "$f.XXXXXX")"
        jq --indent 2 --arg d "$d" --arg v "$(jq -r .value <<<"$item")" \
          'if ((.domains[$d].dkim // {}).google == $v) then . else .domains[$d].dkim = ((.domains[$d].dkim // {}) + {google: $v}) end' "$f" >"$tmp"
        if cmp -s "$tmp" "$f" || [ "$(jq -S . "$tmp")" = "$(jq -S . "$f")" ]; then rm -f "$tmp"; rc=3; else mv "$tmp" "$f"; fi
        ;;
    esac
    case "$rc" in 0) changed=1 ;; 3) ;; *) die "editing $ch for $d failed" ;; esac
  done 3< <(jq -c '.[]' <<<"$batch_items")
  [ "$changed" = 1 ] || return 3
  after="$(jq -L "$lib" -r 'include "mail-auth"; mail_auth_addresses' "$f" | sort)"
  added="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed '/^$/d')"
  removed="$(comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed '/^$/d')"
  pr_added="$added" pr_removed="$removed" pr_known=1
  hook="${post_edit:-$dkim_post_edit}"
  if [ -n "$hook" ]; then
    say "running the post-edit hook once for the batch: $hook"
    (cd "$wt" && DOMAIN="$(jq -r '[.[].domain] | unique | join(",")' <<<"$batch_items")" PHASE=batch DATA_FILE="$f" \
      RECORD_ADDRESSES_ADDED="$added" RECORD_ADDRESSES_REMOVED="$removed" bash -c "$hook") ||
      die "the post-edit hook failed"
  fi
}

# open_batch ITEMS: one branch, one commit, one PR; recorded in the state.
# 0 opened, 3 nothing to change after all, 2 another batch is in flight.
open_batch() {
  local items="$1" n branch title body desc pr rc=0 stage="${plan_stage:-mixed}" what
  [ -n "$root" ] || die "$data is not inside a git repository: the batched setup publishes through PRs"
  n="$(($(st '.batches // 0') + 1))"
  branch="mail/google-batch-$(date -u +%Y%m%d-%H%M%S)"
  desc="$(describe_items "$items")"
  case "$stage" in
    verification) what="verification tokens" ;;
    records) what="mail records" ;;
    records-live) what="mail records, moving live mail" ;;
    dkim) what="DKIM keys" ;;
    *) what="$stage" ;;
  esac
  title="dns: Google Workspace batch $n — $what ($(jq -r '[.[].domain] | unique | length' <<<"$items") domains)"
  claim_batch "$(jq -cn --argjson n "$n" --arg b "$branch" --argjson i "$items" --arg t "$(now_utc)" --arg s "$stage" \
    '{n: $n, stage: "opening", kind: $s, branch: $b, items: $i, opened: $t}')" || {
    say "a batch was opened meanwhile (batch $(st .batch.n)); this one waits for it"
    return 2
  }
  pr_base "$root"
  batch_items="$items"
  pr_commit_branch "$root" "$rel" "$branch" "$title

$desc" batch_edit || rc=$?
  if [ "$rc" = 3 ]; then
    st_set 'del(.batch)'
    say "origin/$base already carries every change of the batch"
    return 3
  fi
  body="Google Workspace batch $n ($what), opened by \`google-workspace-setup\`:

$(while IFS= read -r l; do printf -- '- %s\n' "$l"; done <<<"$desc")
$([ -z "$pr_removed" ] || printf '\nIt REMOVES these records:\n\n    %s\n' "${pr_removed//$'\n'/$'\n'    }")
The background phase (\`google-workspace-setup follow\`) merges this at the head whose required checks it saw pass, waits until DNS serves every record, asks Google to verify the domains whose token this publishes, and opens the next batch for what that makes possible. Each batch carries one kind of change, in the order verification tokens, mail records of domains that receive no mail elsewhere, mail records moving live mail (only as the operator decided, and only after a message from outside reached a domain already moved), DKIM keys."
  st_set --arg a "$pr_added" --arg r "$pr_removed" '.batch.added = $a | .batch.removed = $r'
  pr="$(pr_open_for "$root" "$branch")"
  [ -n "$pr" ] || pr="$(pr_create "$root" "$branch" "$title" "$body")"
  st_set --argjson p "$pr" '.batch.pr = $p | .batch.stage = "checks"'
  log "batch $n ($what): PR #$pr ($branch): $(paste -sd';' <<<"$desc")"
}

# ── DNS for a landed batch ───────────────────────────────────────────────────

cur_domain="" cur_items="" want_mx="" want_spf="" want_dmarc="" want_tls=""
jqv() { jq -L "$lib" -r "$@" "$view_file"; }

batch_served() { # SERVER: every record of $cur_items for $cur_domain served
  local r="$1" item ch got
  while IFS= read -r item; do
    ch="$(jq -r .change <<<"$item")"
    case "$ch" in
      verification)
        got="$(lookup_txt "$cur_domain" "$r")" || return 1
        grep -qxF -- "$(jq -r .token <<<"$item")" <<<"$got" || return 1
        ;;
      dkim)
        got="$(lookup_txt "google._domainkey.$cur_domain" "$r")" || return 1
        [ "$got" = "$(jq -r .value <<<"$item")" ] || return 1
        ;;
      records)
        got="$(lookup_mx "$cur_domain" "$r")" || return 1
        [ "$(mx_normalise "$cur_domain" served <<<"$got")" = "$(mx_normalise "$cur_domain" declared <<<"$want_mx")" ] || return 1
        got="$(lookup_txt "$cur_domain" "$r" | grep '^v=spf1' || true)"
        [ "$got" = "$want_spf" ] || return 1
        got="$(lookup_txt "_dmarc.$cur_domain" "$r" | grep '^v=DMARC1' || true)"
        [ "$got" = "$want_dmarc" ] || return 1
        got="$(lookup_txt "_smtp._tls.$cur_domain" "$r" | grep '^v=TLSRPTv1' || true)"
        [ "$got" = "$want_tls" ] || return 1
        ;;
    esac
  done < <(jq -c --arg d "$cur_domain" '.[] | select(.domain == $d)' <<<"$cur_items")
}
batch_answer() {
  printf 'TXT %s | MX %s' "$(lookup_txt "$cur_domain" "$1" | paste -sd' ' - | cut -c1-60)" "$(lookup_mx "$cur_domain" "$1" | paste -sd, -)"
}

wait_batch_dns() { # ITEMS: one domain after another, each NS first, then public
  local items="$1" d
  cur_items="$items"
  while IFS= read -r d; do
    cur_domain="$d"
    want_mx="$(jqv --arg d "$d" 'include "mail-auth"; mail_auth_mx($d)' | LC_ALL=C sort)"
    want_spf="$(jqv --arg d "$d" 'include "mail-auth"; mail_auth_spf($d) // empty')"
    want_dmarc="$(jqv --arg d "$d" 'include "mail-auth"; mail_auth_dmarc($d) // empty')"
    want_tls="$(jqv --arg d "$d" 'include "mail-auth"; mail_auth_tls_rpt($d) // empty')"
    wait_until_served "$d" "the batch's records for $d" batch_served batch_answer
  done < <(jq -r '[.[].domain] | unique | .[]' <<<"$items")
}

# land_batch: the batch PR in the state, merged at its watched head, then its
# records waited for in DNS. 0 landed (or nothing in flight), 1 dropped.
land_batch() {
  local pr n items prs stage
  pr="$(st '.batch.pr // empty')"
  n="$(st '.batch.n // empty')"
  stage="$(st '.batch.stage // empty')"
  [ -n "$n" ] || return 0
  if [ -z "$pr" ]; then
    # Interrupted between the push and the PR: adopt the PR, or start over.
    pr="$(pr_open_for "$root" "$(st .batch.branch)")"
    if [ -z "$pr" ]; then
      log "batch $n was never opened as a PR; planning it again"
      st_set 'del(.batch)'
      return 1
    fi
    st_set --argjson p "$pr" '.batch.pr = $p | .batch.stage = "checks"'
  fi
  items="$(st -c '.batch.items')"
  # What the batch's edit added and removed, for the plan check (recorded when
  # it was opened, possibly by another process).
  pr_added="$(st '.batch.added // ""')" pr_removed="$(st '.batch.removed // ""')"
  # shellcheck disable=SC2034 # read by plan_check (lib/pr-publish.sh)
  if [ "$(st '.batch | has("added")')" = true ]; then pr_known=1; else pr_known=0; fi
  prs="$(cd "$root" && gh pr view "$pr" --json state -q .state)"
  case "$prs" in
    OPEN)
      log "batch $n: watching the checks of PR #$pr"
      pr_land "$root" "$pr"
      st_set '.batch.stage = "merged"'
      log "batch $n: PR #$pr merged"
      ;;
    MERGED) [ "$stage" = dns ] || st_set '.batch.stage = "merged"' ;;
    *)
      log "batch $n: PR #$pr was closed without merging; planning again"
      st_set 'del(.batch)'
      return 1
      ;;
  esac
  st_set '.batch.stage = "dns"'
  refresh_view
  log "batch $n: waiting for DNS: $(describe_items "$items" | paste -sd';' -)"
  wait_batch_dns "$items"
  # What the merged batch makes due in the console.
  st_set --argjson i "$items" --arg t "$(now_utc)" '
    .todo.activate_gmail = ((.todo.activate_gmail // []) + [$i[] | select(.change == "records" and (.class == "none" or .class == "broken" or .class == "live")) | .domain] | unique)
    | .todo.start_auth = ((.todo.start_auth // []) + [$i[] | select(.change == "dkim") | .domain] | unique)
    | .dkim = ((.dkim // {}) | with_entries(select(.key as $k | [$i[] | select(.change == "dkim") | .domain] | index([$k]) | not)))
    | .history = ((.history // []) + [.batch + {landed: $t}])
    | del(.batch)'
  log "batch $n: DNS serves every record"
}

# ── verification, addresses, the inbound test ────────────────────────────────

# verify_served: every domain on the tenant, unverified, whose token origin/
# <base> publishes: webResource.insert, then wait until the Directory says so.
newly_verified=()
# verify_served: every domain on the tenant, unverified, whose token origin/
# <base> publishes: webResource.insert (again each round: for an alias it
# counts only once the alias exists), then wait — at most $verify_timeout this
# round — until the Directory says so. Sets $newly_verified, and
# $verify_pending to the domains still waited for (the follower keeps asking
# for up to $GOOGLE_WORKSPACE_VERIFY_WAIT seconds per domain, default 6 h: an
# alias's verification has lagged hours behind Site Verification).
newly_verified=()
verify_pending=()
verify_served() {
  local d waiting=() left start out rounds=0
  newly_verified=() verify_pending=()
  forget_tenant
  while IFS= read -r d <&3; do
    on_tenant "$d" || continue
    verified_on_tenant "$d" && continue
    [ "$(v --arg d "$d" '(.domains[$d].google_verification // []) | length')" -gt 0 ] || continue
    waiting+=("$d")
    [ -n "$(st --arg d "$d" '.verify_wait[$d] // empty')" ] ||
      st_set --arg d "$d" --argjson t "$(date +%s)" '.verify_wait[$d] = $t'
  done 3< <(declared_domains)
  [ "${#waiting[@]}" -gt 0 ] || return 0
  log "asking Google to verify: ${waiting[*]}"
  start="$(date +%s)"
  while :; do
    left=()
    for d in "${waiting[@]}"; do
      unset "tstate[$d]"
      if ! verified_on_tenant "$d"; then
        if out="$(with_api api verify "$d" 2>&1)"; then
          site_ok "$d" || {
            st_set --arg d "$d" '.site_ok[$d] = true'
            log "$d: Site Verification accepted its token"
          }
        else
          log "$d: ${out##*: }"
        fi
        unset "tstate[$d]"
      fi
      if verified_on_tenant "$d"; then
        newly_verified+=("$d")
        st_set --arg d "$d" 'del(.verify_wait[$d])'
        log "$d is verified"
      else
        left+=("$d")
      fi
    done
    waiting=("${left[@]}")
    [ "${#waiting[@]}" -gt 0 ] || return 0
    rounds=$((rounds + 1))
    if [ -n "$verify_tries" ]; then
      if [ "$rounds" -ge "$verify_tries" ]; then
        verify_pending=("${waiting[@]}")
        log "not verified yet after $rounds read(s): ${waiting[*]} (asked again later)"
        return 0
      fi
    elif [ $(($(date +%s) - start)) -ge "$verify_timeout" ]; then
      verify_pending=("${waiting[@]}")
      log "not verified yet after ${verify_timeout}s: ${waiting[*]} (asked again later)"
      return 0
    fi
    sleep "$verify_interval"
  done
}

# verify_waiting: the domains of $verify_pending still within
# $GOOGLE_WORKSPACE_VERIFY_WAIT of when the follower began waiting for them.
verify_waiting() {
  local d since now
  now="$(date +%s)"
  for d in "${verify_pending[@]}"; do
    since="$(st --arg d "$d" '.verify_wait[$d] // empty')"
    [ -n "$since" ] || continue
    [ $((now - since)) -lt "${GOOGLE_WORKSPACE_VERIFY_WAIT:-21600}" ] && printf '%s\n' "$d"
  done
}

# The users' addresses and send-as entries on every verified secondary or
# alias domain whose mail is on Google on the base branch (user-addresses, one
# domain at a time).
addresses_now() {
  local u d rc ds=()
  [ -n "$(users)" ] || return 0
  while IFS= read -r d <&3; do
    case "$(kind_of "$d")" in secondary | alias) ;; *) continue ;; esac
    mx_on_google "$d" || continue
    verified_on_tenant "$d" && ds+=("$d")
  done 3< <(declared_domains)
  if [ "${#ds[@]}" = 0 ]; then
    log "no secondary or alias domain is verified with its mail on Google yet: the addresses come then"
    return 0
  fi
  while IFS= read -r u <&3; do
    for d in "${ds[@]}"; do
      rc=0
      with_api gwd user-addresses --user "$u" --domain "$d" --data "$view_file" || rc=$?
      case "$rc" in
        0) ;;
        2) log "$u on $d: something is pending (above)" ;;
        *) log "$u on $d: the addresses step failed (above)" ;;
      esac
    done
  done 3< <(users)
}

# Needed: a domain whose mail goes elsewhere is decided "switch", verified, and
# its records are due — and no inbound proof yet.
inbound_needed() {
  local d
  inbound_ok && return 1
  while IFS= read -r d <&3; do
    moves_mail "$d" || continue
    [ "$(st --arg d "$d" '.decisions[$d] // empty')" = switch ] || continue
    verified_on_tenant "$d" || continue
    records_due "$d" && return 0
  done 3< <(declared_domains)
  return 1
}

# ── the summary the follower leaves ──────────────────────────────────────────

todo_line() { summary_extra+=("$*"); }
summary_extra=()

follow_summary() {
  local lines=() d ready=() held=() unverified=() ag sa gmail_first=()
  forget_tenant
  ag="$(st '(.todo.activate_gmail // []) | join(", ")')"
  sa="$(st '(.todo.start_auth // []) | join(", ")')"
  [ -z "$ag" ] || lines+=("Activate Gmail (https://admin.google.com/ac/domains/manage) for: $ag")
  [ -z "$sa" ] || lines+=("Start authentication (https://admin.google.com/ac/apps/gmail/authenticateemail) for: $sa — DNS serves their DKIM keys now")
  while IFS= read -r d <&3; do
    on_tenant "$d" 2>/dev/null || continue
    if ! verified_on_tenant "$d" 2>/dev/null; then
      unverified+=("$d")
      continue
    fi
    if mx_on_google "$d" && ! has_dkim "$d" && [ -z "$(st --arg d "$d" '.dkim[$d] // empty')" ]; then
      if st --arg d "$d" '(.todo.activate_gmail // []) | index([$d])' | grep -q '^[0-9]'; then
        gmail_first+=("$d")
      else
        ready+=("$d")
      fi
    fi
    if moves_mail "$d" && [ "$(st --arg d "$d" '.decisions[$d] // empty')" != switch ]; then
      held+=("$d")
    fi
  done 3< <(declared_domains)
  [ "${#ready[@]}" = 0 ] || lines+=("DKIM keys can now be generated for ${ready[*]}: $prog dkim-collect (one sitting, one PR)")
  [ "${#gmail_first[@]}" = 0 ] || lines+=("DKIM for ${gmail_first[*]} after Activate Gmail (the console offers no key before)")
  [ "${#held[@]}" = 0 ] || lines+=("mail stays where it is, as decided (or undecided), for ${held[*]}: the interactive setup asks")
  [ "${#unverified[@]}" = 0 ] || lines+=("not verified yet: ${unverified[*]} (Site Verification asked again whenever the follower runs; an alias's verification can lag hours)")
  if inbound_needed 2>/dev/null; then
    lines+=("the inbound test: send a message from a mailbox OUTSIDE the tenant — $prog inbound-test shows the address and finds it; then mail decided 'move' switches")
  fi
  [ "$(v '[.domains[] | select(.zone_pending == true)] | length')" = 0 ] ||
    lines+=("zone pending (skipped): $(v '[.domains | to_entries[] | select(.value.zone_pending == true) | .key] | join(", ")')")
  for d in "${notes[@]}"; do
    case "$d" in *"left to the open PR"*) lines+=("$d") ;; esac
  done
  lines+=("${summary_extra[@]}")
  [ "${#lines[@]}" -gt 0 ] || lines=("nothing left to do")
  printf '%s\n' "${lines[@]}"
}

# ── the background phase ─────────────────────────────────────────────────────

follower_alive() {
  local pid unit
  unit="$(st '.follower.unit // empty')"
  if [ -n "$unit" ] && command -v systemctl >/dev/null && systemctl --user is-active --quiet "$unit" 2>/dev/null; then
    return 0
  fi
  pid="$(st '.follower.pid // empty')"
  [ -n "$pid" ] && [ "$pid" != "$$" ] && kill -0 "$pid" 2>/dev/null
}

follow_done=0
follow_start=0
follow_exit() {
  local rc=$? s s_lines=()
  trap - EXIT
  s="$(follow_summary 2>/dev/null || echo "(the summary could not be computed)")"
  mapfile -t s_lines <<<"$s"
  if [ "$follow_done" = 1 ]; then
    st_set --arg s "$s" --arg t "$(now_utc)" '.summary = ($s | split("\n")) | .summary_at = $t | del(.follower.pid) | .follower.state = "finished"' || true
    if [ -n "$(st '.batch.n // empty')" ]; then
      # The interactive phase opened a batch after this follower's last plan,
      # while it still counted as running: land that one too.
      log "batch $(st .batch.n) was opened meanwhile; following it"
      setup_cleanup
      exec "$BASH" "$self" follow "${setup_args[@]}"
    fi
    printf '\n== what still needs you\n' >&2
    printf '  - %s\n' "${s_lines[@]}" >&2
    notify "Google Workspace setup: background phase finished" "$s"
  else
    st_set --arg s "$s" --arg t "$(now_utc)" --arg rc "$rc" \
      '.summary = (["the follower stopped (exit " + $rc + "); see its log, fix, then run the follower again"] + ($s | split("\n"))) | .summary_at = $t | del(.follower.pid) | .follower.state = "stopped"' || true
    printf '\n== the follower STOPPED (exit %s); fix the cause above and run it again: it resumes\n' "$rc" >&2
    printf '  - %s\n' "${s_lines[@]}" >&2
    notify "Google Workspace setup: background phase stopped" "exit $rc; see $log_file"
  fi
  setup_cleanup
  exit "$rc"
}

cmd_follow() {
  local prev="" items waiting prev_notes="" n
  if ! claim_follower; then
    say "a follower is already running (pid $(st '.follower.pid // "?"')); its log: $log_file"
    return 0
  fi
  # Read by pr_commit_branch (lib/pr-publish.sh):
  # shellcheck disable=SC2034
  pr_exit_trap=follow_exit
  trap follow_exit EXIT
  # A signal ends the run through the EXIT trap, which records it.
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP
  log "follower started (pid $$) for $(basename "$data")"
  follow_start="$(date +%s)"
  local rounds=0
  while [ "$rounds" -lt "${GOOGLE_WORKSPACE_FOLLOW_ROUNDS:-12}" ]; do
    key_present || die "$(key_gone_msg); then run the follower again: it resumes"
    refresh_view
    forget_tenant
    land_batch || continue
    # (a batch can take hours to land: the key may be gone by now)
    key_present || die "$(key_gone_msg); then run the follower again: it resumes"
    refresh_view
    add_domains >&2
    verify_served
    if [ "${#newly_verified[@]}" -gt 0 ]; then
      # A parent verified just now lets its aliases be added, and asked for.
      forget_tenant
      add_domains >&2
      verify_served
    fi
    addresses_now >&2
    forget_tenant
    plan_batch
    items="$plan_items"
    # What is held back, when it changed since the last round.
    if [ "$(printf '%s\n' "${notes[@]}")" != "$prev_notes" ]; then
      for n in "${notes[@]}"; do log "  held back: $n"; done
      prev_notes="$(printf '%s\n' "${notes[@]}")"
    fi
    if [ "$items" = "[]" ] && [ "${#foreign_due[@]}" -gt 0 ] &&
      [ $(($(date +%s) - follow_start)) -lt "${GOOGLE_WORKSPACE_FOREIGN_PR_WAIT:-21600}" ]; then
      # Another open PR carries these domains' next change (a per-domain PR,
      # or a batch made by hand): wait for it to land, then carry on from
      # what it published.
      log "waiting for the open PR(s) that carry ${foreign_due[*]}: $(for d in "${foreign_due[@]}"; do printf '%s ' "${legacy_pr[$d]}"; done | tr ' ' '\n' | grep '^#' | sort -u | paste -sd' ' -)"
      sleep "${GOOGLE_WORKSPACE_FOREIGN_PR_INTERVAL:-60}"
      continue
    fi
    waiting="$(verify_waiting | paste -sd' ' -)"
    if [ "$items" = "[]" ] && [ -n "$waiting" ]; then
      # Nothing to publish, but Google has not reported a domain verified yet
      # (an alias, typically): ask again until it does, or until the wait is
      # over.
      log "waiting for Google to report verified: $waiting (asked again every ${GOOGLE_WORKSPACE_VERIFY_RETRY:-600}s)"
      sleep "${GOOGLE_WORKSPACE_VERIFY_RETRY:-600}"
      continue
    fi
    if [ "$items" = "[]" ]; then
      log "nothing more can be published now"
      break
    fi
    if [ "$items" = "$prev" ]; then
      die "the same changes are due again after a batch landed ($(describe_items "$items" | paste -sd';' -)); stopping rather than loop"
    fi
    prev="$items"
    rounds=$((rounds + 1))
    open_batch "$items" || true
  done
  [ -z "$(st '.batch.n // empty')" ] || die "batches are still due after ${GOOGLE_WORKSPACE_FOLLOW_ROUNDS:-12} rounds; run the follower again"
  follow_done=1
}

# start_follower: the background phase, detached — a transient systemd user
# unit when the user manager answers, nohup otherwise — logging to $log_file.
# $GOOGLE_WORKSPACE_FOLLOW_DETACH = systemd | nohup | none forces a mode.
start_follower() {
  local mode="${GOOGLE_WORKSPACE_FOLLOW_DETACH:-auto}" cmd unit envs=() name pid
  if follower_alive; then
    guide_ok "the background phase is already running; it picks up what was queued here"
    return 0
  fi
  cmd=("$BASH" "$self" follow "${setup_args[@]}")
  if [ "$mode" = auto ]; then
    if command -v systemd-run >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then mode="systemd"; else mode="nohup"; fi
  fi
  : >>"$log_file"
  # The previous run's record goes first: the new follower may finish before
  # this function does.
  [ "$mode" = none ] || st_set --arg l "$log_file" '.follower = {state: "starting", log: $l}'
  case "$mode" in
    none)
      guide_text "Not starting the background phase (GOOGLE_WORKSPACE_FOLLOW_DETACH=none). Run it yourself: the 'follow' step with the same options."
      return 0
      ;;
    systemd)
      unit="google-workspace-follow-$(tenant_name | tr '.' '-')-$(date +%s)"
      # A user unit starts from the user manager's environment, not this
      # shell's: pass what the tools need (PATH, gh's and git's credentials,
      # the key's path) and the names in $GOOGLE_WORKSPACE_FOLLOW_ENV.
      for name in $(compgen -e); do
        case " ${GOOGLE_WORKSPACE_FOLLOW_ENV:-} " in *" $name "*) envs+=("--setenv=$name=${!name}"); continue ;; esac
        case "$name" in
          PATH | HOME | USER | LOGNAME | LANG | LC_* | TZ | TMPDIR | XDG_* | DBUS_SESSION_BUS_ADDRESS | SSH_AUTH_SOCK | GH_* | GITHUB_TOKEN | GIT_* | NIX_* | GOOGLE_* | GUIDE_WIDTH | SSL_CERT_FILE)
            envs+=("--setenv=$name=${!name}")
            ;;
        esac
      done
      systemd-run --user --quiet --collect --same-dir --unit "$unit" "${envs[@]}" \
        bash -c 'exec >>"$1" 2>&1 </dev/null; shift; exec "$@"' _ "$log_file" "${cmd[@]}" ||
        die "systemd-run could not start the follower; run it yourself: google-workspace-setup follow …"
      st_set --arg u "$unit" '.follower.unit = $u'
      guide_ok "the background phase runs as the systemd user unit $unit"
      ;;
    *)
      nohup bash -c 'exec >>"$1" 2>&1 </dev/null; shift; exec "$@"' _ "$log_file" "${cmd[@]}" >/dev/null 2>&1 &
      pid=$!
      disown "$pid" 2>/dev/null || true
      # (the follower records its own pid too; whichever writes first)
      st_set --argjson p "$pid" '.follower.pid = (.follower.pid // $p)'
      guide_ok "the background phase runs as pid $pid (nohup)"
      ;;
  esac
  guide_text "Its log: $log_file"
}

# ── the interactive phase ────────────────────────────────────────────────────

confirm_todo() { # the console steps the last batches made due
  local ag sa ans
  ag="$(st '(.todo.activate_gmail // []) | join(", ")')"
  sa="$(st '(.todo.start_auth // []) | join(", ")')"
  [ -n "$ag$sa" ] || return 0
  guide_h1 "Console steps the background phase left for you"
  if [ -n "$ag" ]; then
    guide_step 1 "Open https://admin.google.com/ac/domains/manage. For each of: $ag — if its row offers 'Activate Gmail', click it and follow it to the end (Google checks the MX it now finds)."
    ans="$(guide_ask "Done for all of them? (n keeps the reminder)" y n)" || exit $?
    [ "$ans" = y ] && st_set '.todo.activate_gmail = []'
  fi
  if [ -n "$sa" ]; then
    guide_step 2 "Open https://admin.google.com/ac/apps/gmail/authenticateemail. For each of: $sa — pick it under 'Selected domain' and click 'START AUTHENTICATION'. Success: 'Authenticating email with DKIM'."
    ans="$(guide_ask "Done for all of them? (n keeps the reminder)" y n)" || exit $?
    [ "$ans" = y ] && st_set '.todo.start_auth = []'
  fi
}

collect_decisions() {
  local d list=() ans dec
  while IFS= read -r d <&3; do
    moves_mail "$d" || continue
    if [ "$redecide" = 0 ] && [ -n "$(st --arg d "$d" '.decisions[$d] // empty')" ]; then continue; fi
    list+=("$d")
  done 3< <(declared_domains)
  [ "${#list[@]}" -gt 0 ] || return 0
  guide_h1 "Decide now: domains whose mail goes elsewhere today"
  for d in "${list[@]}"; do
    printf '   %-20s MX %s (%s)\n' "$d" "$(mx_hosts "$d" | paste -sd, -)" "$(describe_class "$(class_of "$d")")"
  done
  guide_text "Moving a domain's MX to Google sends ALL its mail to Google from then on: the old server stops receiving. Before saying yes: export what matters from the old mailboxes, and make sure every address in use there exists on the tenant (a user alias, a group, or google_users) — an address that exists nowhere bounces."
  guide_text "With 'yes', the background phase moves the domain by itself once Google reports it verified AND a domain already moved has received a test message; otherwise it leaves the domain alone. Your answers are kept in $state_file (re-run with --redecide to change them)."
  ans="$(guide_ask "Move them automatically once verified? a = all, n = none, e = each" a n e)" || exit $?
  for d in "${list[@]}"; do
    case "$ans" in
      a) dec=switch ;;
      n) dec=hold ;;
      e)
        dec="$(guide_ask "Move $d's mail ($(mx_hosts "$d" | paste -sd, -)) to Google once verified?" y n)" || exit $?
        [ "$dec" = y ] && dec=switch || dec=hold
        ;;
    esac
    st_set --arg d "$d" --arg x "$dec" '.decisions[$d] = $x'
  done
  guide_ok "decisions recorded: $(st '.decisions | to_entries | map(.key + " " + .value) | join(", ")')"
}

# Every declared domain onto the tenant: secondary domains, then aliases whose
# parent is VERIFIED (Google refuses an alias of an unverified parent with HTTP
# 409; a later round of the follower adds it once the parent is verified).
add_domains() {
  local d k par out rc
  [ "$interactive" = 0 ] || guide_h1 "Domains on the tenant"
  for k in secondary alias; do
    while IFS= read -r d <&3; do
      [ "$(kind_of "$d")" = "$k" ] || continue
      if on_tenant "$d"; then
        [ "$interactive" = 0 ] ||
          printf '   %-20s on the tenant (%s, verified: %s)\n' "$d" "$(jq -r .kind <<<"${tstate[$d]}")" "$(jq -r .verified <<<"${tstate[$d]}")"
        continue
      fi
      if [ "$k" = alias ]; then
        par="$(parent_of "$d")"
        if ! verified_on_tenant "$par"; then
          if [ "$interactive" = 1 ]; then
            printf '   %-20s waits for its parent %s to be verified\n' "$d" "$par"
          fi
          continue
        fi
        rc=0
        out="$(with_api api alias "$d" "$par")" || rc=$?
        if [ "$rc" = 4 ]; then
          [ "$interactive" = 0 ] || printf '   %-20s waits: Google says %s is not verified\n' "$d" "$par"
          continue
        elif [ "$rc" != 0 ]; then
          guide_bad "$d not added as an alias of $par (above); the background phase tries again"
          continue
        fi
      else
        out="$(with_api api secondary "$d")" || { guide_bad "$d not added (above)"; continue; }
      fi
      tstate[$d]="$out"
      if [ "$interactive" = 1 ]; then
        printf '   %-20s ADDED as %s%s\n' "$d" "$k" "$([ "$k" = alias ] && echo " of $par")"
      else
        log "added $d to the tenant as $k$([ "$k" = alias ] && echo " of $par")"
      fi
      # An alias's token may have been published (and even accepted by Site
      # Verification) before the alias existed: that verification only counts
      # once it is asked for again, which the next verify does.
      [ "$k" != alias ] || st_set --arg d "$d" 'del(.site_ok[$d])'
    done 3< <(declared_domains)
  done
}

read_dkim_value() { # prints the validated value, or nothing on "s"
  local d="$1" line acc out
  while :; do
    printf '\n>> Paste the TXT record value for %s, then an empty line (s = skip this domain): ' "$d" >&2
    acc=""
    while IFS= read -r line; do
      line="${line//$'\r'/}"
      if [ -z "$acc" ] && [ "${line,,}" = s ]; then return 0; fi
      if [ -z "$acc" ] && [ "${line,,}" = q ]; then
        echo "$prog: stopped by the operator. Re-run to resume." >&2
        exit 3
      fi
      [ -z "${line//[[:space:]]/}" ] && [ -n "$acc" ] && break
      acc+="$line"
    done
    [ -n "$acc" ] || {
      echo "$prog: no more input; stopping here. Re-run to resume." >&2
      exit 4
    }
    if out="$("${dkim_cmd[@]}" validate --value "$acc" 2>/dev/null)"; then
      printf '%s' "$out"
      return 0
    fi
    "${dkim_cmd[@]}" validate --value "$acc" 2>&1 >/dev/null | sed 's/^/   /' >&2 || true
    # (on stderr: stdout is the value, captured by the caller)
    guide_bad "that is not a usable DKIM value (above); paste it again" >&2
  done
}

# The DKIM keys for every verified domain whose mail is on Google and that has
# none: pasted one after the other, queued in the state for one batch. A
# domain whose Activate Gmail is not confirmed yet is left out: the console
# offers a key only after it.
collect_dkim() {
  local d due=() later=() val i=0
  load_legacy_prs
  while IFS= read -r d <&3; do
    [ -z "${legacy_pr[$d]:-}" ] || continue
    has_dkim "$d" && continue
    [ -z "$(st --arg d "$d" '.dkim[$d] // empty')" ] || continue
    mx_on_google "$d" || continue
    verified_on_tenant "$d" || continue
    if st --arg d "$d" '(.todo.activate_gmail // []) | index([$d])' | grep -q '^[0-9]'; then
      later+=("$d")
      continue
    fi
    due+=("$d")
  done 3< <(declared_domains)
  [ "${#later[@]}" = 0 ] ||
    guide_text "DKIM after Activate Gmail (the console offers no key before it): ${later[*]}"
  if [ "${#due[@]}" = 0 ]; then
    [ "$step" != dkim-collect ] || guide_ok "no domain needs a DKIM key now"
    return 0
  fi
  guide_h1 "DKIM keys: ${due[*]}"
  guide_text "Google has no API for generating a DKIM key: it is made in the Admin console, and only once Gmail is active for the domain (sometimes 24-48 hours after). Paste each value; every one is validated, and all of them go out in ONE PR. s skips a domain (the next run asks again)."
  guide_step 1 "Open https://admin.google.com/ac/apps/gmail/authenticateemail"
  for d in "${due[@]}"; do
    i=$((i + 1))
    guide_h2 "DKIM $i/${#due[@]}: $d"
    guide_step 2 "Under 'Selected domain' pick $d. Click 'GENERATE NEW RECORD'. DKIM key bit length: 2048. Prefix selector: google. Click GENERATE."
    guide_step 3 "Copy the whole 'TXT record value' (v=DKIM1; k=rsa; p=…). Do NOT click 'Start authentication' yet: Google refuses it until DNS serves the key; the background phase tells you when."
    val="$(read_dkim_value "$d")"
    if [ -z "$val" ]; then
      guide_bad "skipped $d"
      continue
    fi
    st_set --arg d "$d" --arg v "$val" '.dkim[$d] = $v'
    guide_ok "$d's key is queued for the batch"
  done
}

# The inbound test, before mail that goes elsewhere today is moved: the
# operator sends a message from a mailbox OUTSIDE the tenant (a message from
# inside is delivered internally and proves nothing about the MX) to the
# first user's address on a domain already moved; the tool finds it in the
# inbox through the Gmail API (gmail.metadata), or asks when it cannot read.
confirm_inbound() {
  local probe u to marker out rc w ans from
  inbound_needed || {
    [ "$step" != inbound-test ] || guide_ok "no inbound test is needed now (none is waiting for one, or one passed: $(st '.inbound.via // "-"'))"
    return 0
  }
  probe="$(probe_domain)" || {
    guide_bad "no secondary or alias domain is on smtp.google.com and verified yet: nothing to send the test to. The no-mail domains' batch comes first."
    return 0
  }
  u="$(first_user)"
  [ -n "$u" ] || u="$subject"
  to="$(first_local "$u" "$probe")"
  marker="inbound-test-$(date +%s)-$RANDOM"
  guide_h1 "The inbound test (before mail that goes elsewhere today is moved)"
  guide_step 1 "From a mailbox OUTSIDE this tenant (a personal account, another company's), send a message to:"
  guide_value "$to"
  guide_step 2 "with this exact text in its subject:"
  guide_value "$marker"
  guide_text "This tool then looks for it in $u's mailbox (headers only). A message sent from inside the tenant would be delivered internally, without the MX, and prove nothing."
  while :; do
    w=0
    guide_wait "Sent it?" || w=$?
    [ "$w" = 10 ] && { guide_bad "no inbound test: mail decided 'move' stays where it is"; return 0; }
    rc=0
    out="$(with_api api inbound-wait "$u" "$marker" 2>&1)" || rc=$?
    case "$rc" in
      0)
        from="$(jq -r '.from // ""' <<<"$out" | sed 's/.*<//; s/>.*//' | tr '[:upper:]' '[:lower:]')"
        if [ -n "$(kind_of "${from#*@}")" ]; then
          guide_bad "it came from $from, an address of this tenant: delivered internally, it proves nothing. Send it from OUTSIDE."
          marker="inbound-test-$(date +%s)-$RANDOM"
          guide_value "$marker"
          continue
        fi
        st_set --arg d "$probe" --arg t "$(now_utc)" --arg f "$from" '.inbound = {ok: true, via: "gmail-api", domain: $d, from: $f, at: $t}'
        guide_ok "the message from $from reached $to's inbox: mail decided 'move' switches in the next batch"
        return 0
        ;;
      3)
        guide_text "The delegation grants neither gmail.metadata nor gmail.readonly, so this tool cannot look. Check $u's inbox (also Spam) yourself."
        ans="$(guide_ask "Did the message with '$marker' arrive in the inbox?" y n s)" || exit $?
        case "$ans" in
          y)
            st_set --arg d "$probe" --arg t "$(now_utc)" '.inbound = {ok: true, via: "operator", domain: $d, at: $t}'
            guide_ok "recorded: mail decided 'move' switches in the next batch"
            return 0
            ;;
          s) return 0 ;;
        esac
        ;;
      *) guide_bad "${out##*: }" ;;
    esac
    guide_text "Not there. Check, for $probe: its MX is smtp.google.com in public DNS, Activate Gmail was clicked, the address exists (the addresses step). Send another, then press Enter."
  done
}

# preflight: the API project ready (gcloud logged in, every API enabled), the
# delegation scopes and the report group.
preflight() {
  guide_h1 "The Google project, the delegation scopes and the report group"
  preflight_apis
  step_scopes
  step_dmarc_group
}

# publish_and_handoff: the batch due now, as ONE PR (unless one is in
# flight), then the background phase.
publish_and_handoff() {
  local items rc=0 inflight
  guide_h1 "The batch"
  inflight="$(st '.batch.pr // empty')"
  if [ -n "$(st '.batch.n // empty')" ]; then
    guide_text "Batch $(st .batch.n) is in flight (PR #${inflight:-?}, stage $(st .batch.stage)). What was collected here is queued in $state_file: the background phase adds it to a later batch."
  else
    plan_batch
    items="$plan_items"
    if [ "$items" = "[]" ]; then
      guide_text "No DNS change can be made now."
    else
      describe_items "$items" | sed 's/^/   /' | guide_wrap "$guide_width"
      open_batch "$items" || rc=$?
      case "$rc" in
        0) guide_ok "opened PR #$(st .batch.pr) ($(st .batch.branch)) with all of it" ;;
        2) guide_text "The background phase opened batch $(st .batch.n) meanwhile; what was collected here is queued for the next one." ;;
      esac
    fi
    if [ "${#notes[@]}" -gt 0 ]; then
      guide_text "Held back:"
      printf '   %s\n' "${notes[@]}" | guide_wrap "$guide_width"
    fi
  fi
  guide_h1 "Handing off to the background phase"
  start_follower
  guide_text "What happens next, without you: it waits until the PR's required checks are present and passed (re-running failed jobs), merges it at that head, waits for the apply and until DNS serves every record, asks Google to verify the domains (adding each alias once its parent is verified), gives the users their addresses, and opens the next batch PR — until nothing more can be done. It ends with the list of what still needs you (also in the status)."
  guide_text "Check on it: $prog status … (shows the follower, the batch PR and its stage, and the log). Re-running this interactive phase is always safe."
}

cmd_run() {
  interactive=1
  guide_h1 "Google Workspace setup: $(basename "$data") (tenant $(tenant_name))"
  guide_text "Two phases. Now, interactively and without waiting for CI: the API steps for every domain, the decisions and console values the background phase needs, and ONE PR with the DNS changes due now. Then a background process lands it, waits for DNS, has Google verify the domains, and opens the next batch for what that makes possible. Answers: Enter = done; s = skip; q = quit (re-run to resume)."
  confirm_todo
  preflight
  collect_decisions
  add_domains
  if [ -n "$(users)" ]; then
    guide_h1 "Addresses and send-as on the verified domains"
    addresses_now 2>&1 | sed 's/^google-workspace-[a-z]*: //; s/^/   /' | guide_wrap "$guide_width"
  fi
  collect_dkim
  confirm_inbound
  publish_and_handoff
}

# dkim-collect: one sitting for every DKIM key the console can generate now,
# then ONE PR with all of them (the dkim batch), and the background phase,
# which says when to click Start authentication.
cmd_dkim_collect() {
  interactive=1
  guide_h1 "DKIM keys for every domain that can have one now (tenant $(tenant_name))"
  confirm_todo
  collect_dkim
  publish_and_handoff
}

# inbound-test: the inbound test alone, then the background phase (which
# moves the mail decided 'move').
cmd_inbound_test() {
  interactive=1
  confirm_inbound
  if inbound_ok; then publish_and_handoff; fi
}

# ── status ───────────────────────────────────────────────────────────────────

follower_status() {
  local out
  out="$(
    if follower_alive; then
      printf '   running: %s, since %s\n' "$(st '(.follower.unit // empty | "unit " + .) // ("pid " + (.follower.pid | tostring))')" "$(st '.follower.started // "?"')"
    else
      printf '   not running%s\n' "$(st '.follower.state // empty | " (last run " + . + ")"')"
    fi
    [ -z "$(st '.follower.last.msg // empty')" ] || printf '   last: %s %s\n' "$(st .follower.last.at)" "$(st .follower.last.msg)"
    if [ -n "$(st '.batch.n // empty')" ]; then
      printf '   batch %s: PR #%s (%s), stage %s\n' "$(st .batch.n)" "$(st '.batch.pr // "?"')" "$(st .batch.branch)" "$(st .batch.stage)"
      describe_items "$(st -c .batch.items)" | sed 's/^/     /'
    else
      printf '   no batch in flight (%s landed so far)\n' "$(st '.history // [] | length')"
    fi
    [ "$(st '.dkim // {} | length')" = 0 ] || printf '   queued DKIM: %s\n' "$(st '.dkim | keys | join(", ")')"
    [ "$(st '.decisions // {} | length')" = 0 ] || printf '   decisions: %s\n' "$(st '.decisions | to_entries | map(.key + " " + .value) | join(", ")')"
    printf '   inbound proof: %s\n' "$(st 'if .inbound.ok then "yes (" + .inbound.via + ", " + .inbound.domain + ")" elif .inbound.via then "no (" + .inbound.via + ")" else "not yet" end')"
    if [ "$(st '.summary // [] | length')" != 0 ]; then
      printf '   left for you (%s):\n' "$(st '.summary_at // "?"')"
      st '.summary[]' | sed 's/^/     - /'
    fi
    printf '   state: %s\n' "$state_file"
  )"
  guide_h2 "Background phase"
  printf '%s\n' "$out" | guide_wrap "$guide_width"
  if [ -s "$log_file" ]; then
    printf '   log, last lines:\n     %s\n' "$log_file"
    tail -n 5 "$log_file" | cut -c1-$((guide_width - 5)) | sed 's/^/     /'
  fi
}
