# shellcheck shell=bash
# The globals below are the caller's (see "The caller sets"):
# shellcheck disable=SC2154
# Shared by the tools that publish a DNS change through a consumer repository's
# Terraform data file (google-workspace-dkim, google-workspace-domains): edit
# the file in a temporary worktree, open a PR, wait for every check and workflow
# run of its exact head, merge at that head, then wait until the zone's own
# nameservers and then the public resolvers serve the result.
#
# Sourced, not executed. The caller sets, before calling anything here:
#
#   prog          the tool's name, for messages
#   resolvers     array of public resolvers (phase 2 of the DNS wait)
#   dns_timeout   seconds per DNS phase
#   dns_interval  seconds between DNS polls
#   base          the base branch, or empty for the repository's default
#   merge         1 to merge when every check passed
#
# and $GOOGLE_WORKSPACE_DKIM_CHECK_INTERVAL may shorten the re-watch interval
# (tests). Every function either returns or exits through `die`.
#
# THE MERGE GATE. Without configuration a PR is merged once EVERY check and
# workflow run of its head passed. A consumer whose CI always fails a check on
# a DNS change (an import gate that refuses creates, say), or runs checks that
# have nothing to do with DNS data, names the checks that matter instead, in
# the environment (so the background follower inherits them):
#
#   $GOOGLE_WORKSPACE_REQUIRED_CHECKS  ";"-separated check names (bash
#                     patterns) as `gh pr checks` lists them. The PR is merged
#                     once EACH is present AND passed — not once nothing is
#                     pending: checks register late (a job that `needs:`
#                     another appears only when that one finishes), so "nothing
#                     pending" can come before the check exists. Other checks
#                     are ignored. A required check that failed, was cancelled,
#                     or was skipped because a job it needs failed (a runner
#                     timeout, a full disk, a cache 401) has its workflow run's
#                     failed jobs re-run, up to $GOOGLE_WORKSPACE_RERUNS times
#                     per run (default 3), before the tool gives up.
#   $GOOGLE_WORKSPACE_PR_LABELS        labels every PR is opened with (comma-
#                     or space-separated), e.g. the one that unlocks a
#                     credentialed plan.
#   $GOOGLE_WORKSPACE_DESTROY_LABEL    a label added when the edit REMOVES
#                     records (RECORD_ADDRESSES_REMOVED not empty), e.g. the
#                     one that lets the apply destroy.
#   $GOOGLE_WORKSPACE_PLAN_CHECK       a command run in the repository root
#                     once the required checks passed, with PR, HEAD_SHA,
#                     RECORD_ADDRESSES_ADDED / _REMOVED and
#                     RECORD_ADDRESSES_KNOWN (1 when this process made the
#                     edit, 0 when it resumed a PR) exported: exit 0 when the
#                     PR's plan matches the change, 2 when the plan for HEAD_SHA
#                     is not there yet (asked again), anything else to stop.
#   $GOOGLE_WORKSPACE_APPLY_WORKFLOW   the workflow whose run on the merge
#                     commit applies the change: after the merge the tool
#                     waits for that run and re-runs it when it was cancelled
#                     or failed (same limit), before waiting for DNS.
#   $GOOGLE_WORKSPACE_CHECKS_TIMEOUT   seconds the gate and the apply wait
#                     each take at most (default 14400); then it stops, and a
#                     re-run resumes the same PR.
#   $GOOGLE_WORKSPACE_CHECKS_INTERVAL  seconds between looks (default 30).

die() {
  echo "$prog: $*" >&2
  exit 1
}
say() { echo "$prog: $*" >&2; }

# ── DNS ──────────────────────────────────────────────────────────────────────

# Concatenate the "…" character-strings of one line, the way a resolver hands
# a TXT record back (dig +short) and the way consoles sometimes show a long
# value. Backslash escapes (\" \\ \DDD) are decoded. Fails if anything but
# whitespace sits outside the quotes, or a quote is left open.
concat_strings() {
  awk '{
    out = ""; n = length($0); inq = 0; bad = 0; i = 1
    while (i <= n) {
      c = substr($0, i, 1)
      if (inq) {
        if (c == "\\") {
          d = substr($0, i + 1, 3)
          if (d ~ /^[0-9][0-9][0-9]$/) { out = out sprintf("%c", d + 0); i += 4; continue }
          out = out substr($0, i + 1, 1); i += 2; continue
        }
        if (c == "\"") { inq = 0; i++; continue }
        out = out c; i++; continue
      }
      if (c == "\"") { inq = 1; i++; continue }
      if (c != " " && c != "\t") bad = 1
      i++
    }
    if (inq || bad) exit 3
    print out
  }'
}

# Extra dig flags for the current phase (+norecurse when asking a zone's own
# nameservers).
dig_extra=""

# Every TXT record at $1 on resolver $2, one reassembled value per line.
lookup_txt() {
  local name="$1" resolver="$2" out line
  out="$(dig +short +time=5 +tries=2 ${dig_extra:+"$dig_extra"} TXT "$name" "@$resolver" 2>/dev/null)" || return 2
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [[ $line == '"'* ]] || continue # a CNAME target or a comment line
    printf '%s\n' "$line" | concat_strings || return 2
  done <<<"$out"
}

# Every MX record at $1 on resolver $2 as "<priority> <host>" lines, host
# lowercased without the trailing dot, sorted bytewise (LC_ALL=C: a locale's
# collation ignores the space, and "10 a" vs "1 b" would then compare
# differently from the jq-sorted expectation).
lookup_mx() {
  local name="$1" resolver="$2" out
  out="$(dig +short +time=5 +tries=2 ${dig_extra:+"$dig_extra"} MX "$name" "@$resolver" 2>/dev/null)" || return 2
  printf '%s\n' "$out" | awk 'NF == 2 && $1 ~ /^[0-9]+$/ { h = tolower($2); sub(/\.$/, "", h); print $1, h }' | LC_ALL=C sort
}

# The nameservers of the zone holding $1: the NS set of the closest enclosing
# name that has one, looked up through the first resolver. Empty if none.
authoritative_servers() {
  local n="$1" ns
  while [[ $n == *.* ]]; do
    ns="$(dig +short +time=5 +tries=2 NS "$n" "@${resolvers[0]}" 2>/dev/null | sed -n 's/\.$//; /^[A-Za-z0-9.-]*$/p' | sort -u)" || ns=""
    if [ -n "$ns" ]; then
      printf '%s\n' "$ns"
      return 0
    fi
    n="${n#*.}"
  done
}

# Cloudflare serves an MX whose target is a PROXIED name in the zone as
# "_dc-mx.<hex>.<zone>" (a DNS-only name it maintains for the purpose, since a
# proxied address cannot receive SMTP). Both sides normalised the same way, the
# substitute and the in-zone host it stands for compare equal.
mx_normalise() { # DOMAIN SIDE(declared|served) < "<prio> <host>" lines
  awk -v d="$1" -v side="$2" '
    function inzone(h) { return h == d || substr(h, length(h) - length(d)) == "." d }
    {
      h = $2
      if (side == "served" && h ~ /^_dc-mx\.[0-9a-f]+\./ && inzone(h)) h = "<proxied host in " d ">"
      else if (side == "declared" && inzone(h)) h = "<proxied host in " d ">"
      print $1, h
    }' | LC_ALL=C sort
}

# wait_until_served DOMAIN WHAT MATCH_FN DESCRIBE_FN [HINT]
#
# Two phases. Public resolvers cache a negative answer for the zone's SOA
# minimum (1800 s on Cloudflare), so asking them before the record exists would
# make them keep answering "no such name" for that long after the apply lands.
# Phase 1 therefore asks the zone's own nameservers, non-recursively, until they
# serve the value — that is the CI apply having run. Only then are the public
# resolvers asked. Each phase is bounded by $dns_timeout.
#
# MATCH_FN SERVER returns 0 when SERVER serves what is wanted; DESCRIBE_FN
# SERVER prints what it serves (one line, or nothing). Both run with $dig_extra
# set for the phase. WHAT names the record(s) in messages; HINT is appended to
# the timeout error.
wait_until_served() {
  local zone_name="$1" what="$2" match_fn="$3" describe_fn="$4" hint="${5:-}" ns=()
  mapfile -t ns < <(authoritative_servers "$zone_name")
  if [ "${#ns[@]}" -gt 0 ]; then
    dig_extra="+norecurse" poll_served "$what" "the zone's nameservers (the apply has run)" "$match_fn" "$describe_fn" "$hint" "${ns[@]}"
  else
    say "could not find the nameservers of $zone_name; asking the public resolvers directly"
  fi
  poll_served "$what" "the public resolvers" "$match_fn" "$describe_fn" "$hint" "${resolvers[@]}"
}

poll_served() {
  local what="$1" where="$2" match_fn="$3" describe_fn="$4" hint="$5" start now r got ok
  shift 5
  start="$(date +%s)"
  say "waiting up to ${dns_timeout}s for $what to resolve to the value on $where: $*"
  while :; do
    ok=1
    for r in "$@"; do
      "$match_fn" "$r" || {
        ok=0
        break
      }
    done
    if [ "$ok" = 1 ]; then
      say "$what resolves to the published value on every one of $where"
      return 0
    fi
    now="$(date +%s)"
    if [ $((now - start)) -ge "$dns_timeout" ]; then
      for r in "$@"; do
        got="$("$describe_fn" "$r" 2>/dev/null || true)"
        say "  @$r answers: ${got:-<nothing>}"
      done
      die "$what did not resolve to the value on $where within ${dns_timeout}s (if the nameservers lag, check the Terraform apply run on the base branch; if only public resolvers lag, a cached negative answer expires within the zone's SOA minimum). Re-run to keep waiting${hint:+, or $hint}"
    fi
    for r in "$@"; do
      got="$("$describe_fn" "$r" 2>/dev/null || true)"
      if [ -z "$got" ]; then
        say "  [$((now - start))s] @$r: no record yet"
      else
        say "  [$((now - start))s] @$r: a different value (${got:0:40}…)"
      fi
    done
    sleep "$dns_interval"
  done
}

# ── PR flow ──────────────────────────────────────────────────────────────────

# Every temporary worktree publish_pr made, as (repository root, worktree)
# pairs; removed on exit. A tool that opens two PRs in one run keeps both.
pr_worktrees=()
pr_cleanup_worktrees() {
  local i
  for ((i = 0; i + 1 < ${#pr_worktrees[@]}; i += 2)); do
    git -C "${pr_worktrees[i]}" worktree remove --force "${pr_worktrees[i + 1]}" >/dev/null 2>&1 || true
    rm -rf "${pr_worktrees[i + 1]}"
  done
}

# publish_pr ROOT REL BRANCH TITLE BODY MESSAGE STATE_FN EDIT_FN
#
# Branch, commit, push, PR, checks, merge. Returns once the change is on
# <base>, or exits when it is not going to be (no --merge, or a check failed).
#
#   STATE_FN FILE   prints "same" when FILE (the data file as some revision has
#                   it) already carries the change, anything else otherwise.
#                   Used against origin/<base> (skip everything) and against an
#                   open PR's branch (resume it only if it carries the change).
#   EDIT_FN FILE ROOT
#                   makes the change in FILE inside the worktree ROOT, runs the
#                   consumer's hook there, and returns 0 (changed) or 3
#                   (nothing to change).
#
# $pr_mismatch_msg, when set, is the error for an open PR whose branch carries
# a different change; $pr_subject names the change in messages.
#
# It is pr_base, pr_commit_branch, pr_create and pr_land in sequence; the
# batched setup calls those separately, opening a PR in one process and
# landing it in another.
publish_pr() {
  local root="$1" rel="$2" branch="$3" title="$4" body="$5" msg="$6" state_fn="$7" edit_fn="$8"
  local pr subject="${pr_subject:-the change}"
  pr_base "$root"

  if git -C "$root" show "origin/$base:$rel" >/dev/null 2>&1 &&
    [ "$(git -C "$root" show "origin/$base:$rel" | "$state_fn" /dev/stdin)" = same ]; then
    say "origin/$base already publishes $subject; skipping to the DNS wait"
    return 0
  fi

  pr="$(pr_open_for "$root" "$branch")"
  if [ -n "$pr" ]; then
    git -C "$root" fetch --quiet origin "$branch" ||
      die "PR #$pr is open but origin/$branch could not be fetched"
    [ "$(git -C "$root" show "FETCH_HEAD:$rel" | "$state_fn" /dev/stdin)" = same ] ||
      die "${pr_mismatch_msg:-PR #$pr ($branch) carries a different change than $subject. Close it and delete the branch, then re-run}"
    say "PR #$pr for $branch is already open with $subject; resuming it"
  else
    local rc=0
    pr_commit_branch "$root" "$rel" "$branch" "$msg" "$edit_fn" || rc=$?
    [ "$rc" = 0 ] || die "nothing to commit on $branch ($subject is already there)"
    pr="$(pr_create "$root" "$branch" "$title" "$body")"
  fi
  pr_land "$root" "$pr"
}

# pr_base ROOT: resolves $base (the repository's default branch when empty)
# and fetches origin/$base.
pr_base() {
  local root="$1"
  command -v gh >/dev/null || die "gh is required for the PR flow (or pass --no-pr)"
  if [ -z "$base" ]; then
    base="$(cd "$root" && gh repo view --json defaultBranchRef -q .defaultBranchRef.name)" ||
      die "could not determine the default branch; pass --base"
  fi
  say "fetching origin/$base"
  git -C "$root" fetch --quiet origin "$base"
}

# pr_open_for ROOT BRANCH: the number of the open PR from BRANCH into $base,
# or nothing.
pr_open_for() {
  (cd "$1" && gh pr list --head "$2" --base "$base" --state open --json number -q '.[0].number // empty')
}

# pr_commit_branch ROOT REL BRANCH MESSAGE EDIT_FN
#
# In a temporary worktree on BRANCH from origin/$base: EDIT_FN FILE WORKTREE,
# then a commit of the data file and exactly the paths the hook changed, pushed
# to origin. 0 when pushed, 3 when EDIT_FN changed nothing (nothing is pushed).
# The operator's own checkout is never touched.
pr_commit_branch() {
  local root="$1" rel="$2" branch="$3" msg="$4" edit_fn="$5" wt before after paths=() p rc=0
  wt="$(mktemp -d "${TMPDIR:-/tmp}/$prog.XXXXXX")"
  pr_worktrees+=("$root" "$wt")
  # A caller with an EXIT trap of its own names it in $pr_exit_trap (and
  # calls pr_cleanup_worktrees from it). Expanded now, on purpose:
  # shellcheck disable=SC2064
  trap "${pr_exit_trap:-pr_cleanup_worktrees}" EXIT
  git -C "$root" worktree add --quiet -B "$branch" "$wt" "origin/$base"
  # Dev shells often generate the commit-hook configuration as an untracked,
  # ignored file (a .pre-commit-config.yaml symlink into the Nix store). A
  # fresh worktree does not have it, and the hook then refuses the commit, so
  # link the operator's copy in. Only an ignored file is linked, so it can
  # never be staged.
  # shellcheck disable=SC2043 # a list of one, for now
  for f in .pre-commit-config.yaml; do
    if [ -e "$root/$f" ] && [ ! -e "$wt/$f" ] && git -C "$root" check-ignore -q -- "$f"; then
      ln -s "$(readlink -f "$root/$f")" "$wt/$f"
    fi
  done
  before="$(git -C "$wt" status --porcelain=v1 --untracked-files=all)"
  "$edit_fn" "$wt/$rel" "$wt" || rc=$?
  [ "$rc" = 0 ] || return 3
  after="$(git -C "$wt" status --porcelain=v1 --untracked-files=all)"
  # Stage the data file and exactly the paths the hook changed.
  paths=("$rel")
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    p="${p:3}"
    p="${p##* -> }"
    [ "$p" = "$rel" ] || paths+=("$p")
  done < <(comm -13 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort))
  say "staging: ${paths[*]}"
  git -C "$wt" add -- "${paths[@]}"
  if ! git -C "$wt" commit --quiet -m "$msg"; then
    # A formatting hook may have rewritten the staged files; take its result once.
    say "the commit hooks changed files; re-staging and committing again"
    git -C "$wt" add -- "${paths[@]}"
    git -C "$wt" commit --quiet -m "$msg" || die "commit failed in $wt"
  fi
  git -C "$wt" push --quiet --force-with-lease -u origin "$branch"
}

# What the edit of this process added and removed (cloudflare_dns_record
# addresses, newline-separated), set by the EDIT_FN; for the labels and the
# plan check. pr_known=1 once an edit of this process set them.
pr_added="" pr_removed="" pr_known=0

# pr_create ROOT BRANCH TITLE BODY: opens the PR into $base with the
# configured labels; prints its number.
pr_create() {
  local pr l labels=()
  for l in ${GOOGLE_WORKSPACE_PR_LABELS:+${GOOGLE_WORKSPACE_PR_LABELS//,/ }}; do labels+=(--label "$l"); done
  if [ -n "$pr_removed" ] && [ -n "${GOOGLE_WORKSPACE_DESTROY_LABEL:-}" ]; then
    say "the change removes records; labelling the PR ${GOOGLE_WORKSPACE_DESTROY_LABEL}"
    labels+=(--label "$GOOGLE_WORKSPACE_DESTROY_LABEL")
  fi
  pr="$(cd "$1" && gh pr create --base "$base" --head "$2" --title "$3" --body "$4" "${labels[@]}")"
  say "opened $pr"
  printf '%s\n' "${pr##*/}"
}

# pr_land ROOT PR: fixes PR's head, waits for every check and workflow run of
# it, and (with $merge = 1) merges at exactly that head. Exits otherwise. The
# head is fixed before watching, so the merge can only land the commit whose
# checks were watched; a head that moves meanwhile makes the merge refuse.
pr_land() {
  local root="$1" pr="$2" head state
  head="$(cd "$root" && gh pr view "$pr" --json headRefOid -q .headRefOid)"
  [ -n "$head" ] || die "could not read the head commit of PR #$pr"
  if [ -n "${GOOGLE_WORKSPACE_REQUIRED_CHECKS:-}" ]; then
    gate_checks "$root" "$pr" "$head"
  else
    watch_checks "$root" "$pr" "$head"
  fi
  if [ "$merge" != 1 ]; then
    say "checks passed on PR #$pr. Merge it, then re-run this command: it will skip to the DNS wait."
    exit 0
  fi
  if [ -z "${GOOGLE_WORKSPACE_REQUIRED_CHECKS:-}" ]; then
    state="$(cd "$root" && gh pr checks "$pr" --json bucket -q '[.[].bucket] | map(select(. != "pass" and . != "skipping")) | length')"
    [ "$state" = 0 ] || die "PR #$pr has checks that did not pass; not merging"
  fi
  plan_check "$root" "$pr" "$head"
  say "merging PR #$pr at ${head:0:12}"
  (cd "$root" && gh pr merge "$pr" --merge --match-head-commit "$head") ||
    die "gh pr merge refused (review required, or the head moved); merge PR #$pr by hand and re-run"
  wait_apply "$root" "$pr"
}

checks_interval() { printf '%s' "${GOOGLE_WORKSPACE_CHECKS_INTERVAL:-30}"; }
checks_timeout() { printf '%s' "${GOOGLE_WORKSPACE_CHECKS_TIMEOUT:-14400}"; }

# rerun_failed ROOT RUN WHAT: re-runs RUN's failed jobs (and the jobs that
# need them) unless it was re-run $GOOGLE_WORKSPACE_RERUNS times already by
# this process; exits then. WHAT names the check for messages.
declare -A pr_reruns=()
rerun_failed() {
  local root="$1" run="$2" what="$3" n
  n="${pr_reruns[$run]:-0}"
  [ "$n" -lt "${GOOGLE_WORKSPACE_RERUNS:-3}" ] ||
    die "$what still fails after $n re-run(s) of workflow run $run; look at it (a real failure, not a flaky runner?), fix, and re-run this command"
  pr_reruns[$run]=$((n + 1))
  say "$what did not pass (workflow run $run); re-running its failed jobs ($((n + 1))/${GOOGLE_WORKSPACE_RERUNS:-3})"
  (cd "$root" && gh run rerun "$run" --failed >/dev/null 2>&1) ||
    die "could not re-run workflow run $run for $what (skipped because a label is missing? nothing failed in it?); fix it and re-run this command"
}

# gate_checks ROOT PR HEAD: returns once every check named in
# $GOOGLE_WORKSPACE_REQUIRED_CHECKS is present and passed on PR (see THE MERGE
# GATE above); re-runs failed ones; exits on a lasting failure or the timeout.
gate_checks() {
  local root="$1" pr="$2" head="$3" start now json pat pats=() line b n l missing pending failed ok runs rerun_done last=""
  IFS=';' read -r -a pats <<<"$GOOGLE_WORKSPACE_REQUIRED_CHECKS"
  start="$(date +%s)"
  say "PR #$pr at ${head:0:12}: waiting until each required check is present and passed: $(printf '%s; ' "${pats[@]}" | sed 's/; $//')"
  while :; do
    json="$(cd "$root" && gh pr checks "$pr" --json name,bucket,link 2>/dev/null)" || true
    jq -e 'type == "array"' <<<"$json" >/dev/null 2>&1 || json='[]'
    missing=() pending=() failed=() ok=0 rerun_done=0
    declare -A runs=()
    for pat in "${pats[@]}"; do
      pat="${pat#"${pat%%[![:space:]]*}"}" pat="${pat%"${pat##*[![:space:]]}"}"
      [ -n "$pat" ] || continue
      local seen=0 st="pass"
      while IFS=$'\t' read -r b n l; do
        # shellcheck disable=SC2053 # a pattern on purpose
        [[ $n == $pat ]] || continue
        seen=1
        case "$b" in
          pass) ;;
          pending) [ "$st" = fail ] || st=pending ;;
          *)
            st=fail
            if [[ $l =~ /actions/runs/([0-9]+) ]]; then runs[${BASH_REMATCH[1]}]="$n"; fi
            ;;
        esac
      done < <(jq -r '.[] | [.bucket, .name, (.link // "")] | @tsv' <<<"$json")
      if [ "$seen" = 0 ]; then
        missing+=("$pat")
      else
        case "$st" in
          pass) ok=$((ok + 1)) ;;
          pending) pending+=("$pat") ;;
          fail) failed+=("$pat") ;;
        esac
      fi
    done
    if [ "${#missing[@]}" = 0 ] && [ "${#pending[@]}" = 0 ] && [ "${#failed[@]}" = 0 ]; then
      say "PR #$pr: every required check is present and passed ($ok)"
      return 0
    fi
    if [ "${#failed[@]}" -gt 0 ]; then
      [ "${#runs[@]}" -gt 0 ] || die "PR #$pr: required check(s) did not pass and name no workflow run to re-run: ${failed[*]}"
      for r in "${!runs[@]}"; do
        rerun_failed "$root" "$r" "PR #$pr's check '${runs[$r]}'"
        rerun_done=1
      done
    fi
    now="$(date +%s)"
    [ $((now - start)) -lt "$(checks_timeout)" ] ||
      die "PR #$pr: required checks not all passed after $(checks_timeout)s (missing: ${missing[*]:-none}; pending: ${pending[*]:-none}); re-run this command to keep waiting"
    l="missing: ${missing[*]:-none}; running: ${pending[*]:-none}"
    [ "$l" = "$last" ] || say "  [$((now - start))s] PR #$pr: $l"
    last="$l"
    unset runs
    [ "$rerun_done" = 1 ] && sleep "${GOOGLE_WORKSPACE_RERUN_SETTLE:-90}"
    sleep "$(checks_interval)"
  done
}

# plan_check ROOT PR HEAD: the consumer's $GOOGLE_WORKSPACE_PLAN_CHECK, until
# it answers (see THE MERGE GATE above).
plan_check() {
  local root="$1" pr="$2" head="$3" rc start
  [ -n "${GOOGLE_WORKSPACE_PLAN_CHECK:-}" ] || return 0
  start="$(date +%s)"
  while :; do
    rc=0
    (cd "$root" && PR="$pr" HEAD_SHA="$head" RECORD_ADDRESSES_ADDED="$pr_added" RECORD_ADDRESSES_REMOVED="$pr_removed" \
      RECORD_ADDRESSES_KNOWN="$pr_known" bash -c "$GOOGLE_WORKSPACE_PLAN_CHECK") >&2 || rc=$?
    case "$rc" in
      0) say "PR #$pr: the plan matches the change"; return 0 ;;
      2) ;;
      *) die "PR #$pr: the plan does not match the change (above); not merging. Look at the PR's plan, fix, and re-run" ;;
    esac
    [ $(($(date +%s) - start)) -lt "$(checks_timeout)" ] ||
      die "PR #$pr: no plan for ${head:0:12} after $(checks_timeout)s; re-run this command to keep waiting"
    say "  PR #$pr: no plan for ${head:0:12} yet; asking again"
    sleep "$(checks_interval)"
  done
}

# wait_apply ROOT PR: once PR is merged, the $GOOGLE_WORKSPACE_APPLY_WORKFLOW
# run on its merge commit, until it succeeded; a cancelled or failed one is
# re-run. Nothing to do without the setting.
wait_apply() {
  local root="$1" pr="$2" wf="${GOOGLE_WORKSPACE_APPLY_WORKFLOW:-}" sha json id st c start
  [ -n "$wf" ] || return 0
  sha="$(cd "$root" && gh pr view "$pr" --json mergeCommit -q '.mergeCommit.oid // empty')"
  [ -n "$sha" ] || die "PR #$pr: no merge commit to follow the '$wf' run of"
  start="$(date +%s)"
  say "waiting for the '$wf' run on ${sha:0:12} (the apply)"
  while :; do
    json="$(cd "$root" && gh run list --commit "$sha" --workflow "$wf" --json databaseId,status,conclusion --limit 20 2>/dev/null)" || json='[]'
    id="$(jq -r 'first(.[] | .databaseId) // empty' <<<"$json" 2>/dev/null)" || id=""
    st="$(jq -r 'first(.[] | .status) // empty' <<<"$json" 2>/dev/null)" || st=""
    c="$(jq -r 'first(.[] | .conclusion) // empty' <<<"$json" 2>/dev/null)" || c=""
    if [ -n "$id" ] && [ "$st" = completed ]; then
      case "$c" in
        success | skipped | neutral)
          say "the '$wf' run $id on ${sha:0:12} succeeded"
          return 0
          ;;
        *) rerun_failed "$root" "$id" "the '$wf' run on ${sha:0:12} ($c)" ;;
      esac
    fi
    [ $(($(date +%s) - start)) -lt "$(checks_timeout)" ] ||
      die "the '$wf' run on ${sha:0:12} did not succeed within $(checks_timeout)s; look at it, then re-run this command"
    sleep "$(checks_interval)"
  done
}

# Summarises the GitHub Actions workflow runs for commit $2: "ok" when every
# run completed as success/skipped/neutral (or there are none), "bad" when one
# concluded otherwise, "pending" while any is still running.
runs_state() {
  (cd "$1" && gh run list --commit "$2" --limit 200 --json status,conclusion -q '
    [.[] | if .status != "completed" then "pending"
           elif (.conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral") then "ok"
           else "bad" end]
    | if any(. == "bad") then "bad" elif any(. == "pending") then "pending" else "ok" end')
}

# Returns once every check of PR $2 passed and every workflow run for its head
# $3 completed successfully; exits otherwise. `gh pr checks --watch` alone is
# not enough: a job that `needs:` another, or a matrix computed by one, only
# registers its check once that job finishes, so the watch can see "all passed"
# while part of the pipeline does not exist yet. A workflow run stays
# in_progress until all of its jobs have finished, so it closes that window.
watch_checks() {
  local root="$1" pr="$2" head="$3" tries=0 rounds=0 out rc runs
  say "watching the checks of PR #$pr at ${head:0:12}"
  while :; do
    rc=0
    out="$(cd "$root" && gh pr checks "$pr" --watch --interval 20 2>&1)" || rc=$?
    if [ "$rc" = 0 ]; then
      runs="$(runs_state "$root" "$head")" || die "could not list the workflow runs of ${head:0:12}"
      case "$runs" in
        ok)
          say "all checks passed on PR #$pr, and every workflow run for ${head:0:12} completed"
          return 0
          ;;
        bad) die "PR #$pr: a workflow run for ${head:0:12} did not succeed; fix it and re-run (the open PR is resumed)" ;;
        *)
          rounds=$((rounds + 1))
          [ "$rounds" -le 180 ] || die "PR #$pr: workflow runs for ${head:0:12} still running after the checks passed; re-run to keep waiting"
          say "the reported checks passed but workflow runs for ${head:0:12} are still running; watching again"
          sleep "${GOOGLE_WORKSPACE_DKIM_CHECK_INTERVAL:-20}"
          continue
          ;;
      esac
    fi
    if [[ $out == *"no checks reported"* ]] && [ "$tries" -lt 30 ]; then
      tries=$((tries + 1))
      sleep 10
      continue
    fi
    printf '%s\n' "$out" >&2
    die "PR #$pr: checks did not pass; fix it and re-run (the open PR is resumed)"
  done
}
