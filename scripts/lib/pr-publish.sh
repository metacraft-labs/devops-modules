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
# lowercased without the trailing dot, sorted.
lookup_mx() {
  local name="$1" resolver="$2" out
  out="$(dig +short +time=5 +tries=2 ${dig_extra:+"$dig_extra"} MX "$name" "@$resolver" 2>/dev/null)" || return 2
  printf '%s\n' "$out" | awk 'NF == 2 && $1 ~ /^[0-9]+$/ { h = tolower($2); sub(/\.$/, "", h); print $1, h }' | sort
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
publish_pr() {
  local root="$1" rel="$2" branch="$3" title="$4" body="$5" msg="$6" state_fn="$7" edit_fn="$8"
  local pr wt before after paths=() p head state subject="${pr_subject:-the change}"
  command -v gh >/dev/null || die "gh is required for the PR flow (or pass --no-pr)"
  if [ -z "$base" ]; then
    base="$(cd "$root" && gh repo view --json defaultBranchRef -q .defaultBranchRef.name)" ||
      die "could not determine the default branch; pass --base"
  fi
  say "fetching origin/$base"
  git -C "$root" fetch --quiet origin "$base"

  if git -C "$root" show "origin/$base:$rel" >/dev/null 2>&1 &&
    [ "$(git -C "$root" show "origin/$base:$rel" | "$state_fn" /dev/stdin)" = same ]; then
    say "origin/$base already publishes $subject; skipping to the DNS wait"
    return 0
  fi

  pr="$(cd "$root" && gh pr list --head "$branch" --base "$base" --state open --json number -q '.[0].number // empty')"
  if [ -n "$pr" ]; then
    git -C "$root" fetch --quiet origin "$branch" ||
      die "PR #$pr is open but origin/$branch could not be fetched"
    [ "$(git -C "$root" show "FETCH_HEAD:$rel" | "$state_fn" /dev/stdin)" = same ] ||
      die "${pr_mismatch_msg:-PR #$pr ($branch) carries a different change than $subject. Close it and delete the branch, then re-run}"
    say "PR #$pr for $branch is already open with $subject; resuming it"
  else
    wt="$(mktemp -d "${TMPDIR:-/tmp}/$prog.XXXXXX")"
    pr_worktrees+=("$root" "$wt")
    trap pr_cleanup_worktrees EXIT
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
    local rc=0
    "$edit_fn" "$wt/$rel" "$wt" || rc=$?
    [ "$rc" = 0 ] || die "nothing to commit on $branch ($subject is already there)"
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
    pr="$(cd "$wt" && gh pr create --base "$base" --head "$branch" --title "$title" --body "$body")"
    say "opened $pr"
    pr="${pr##*/}"
  fi

  # The head is fixed before watching, so the merge below can only land the
  # commit whose checks were watched.
  head="$(cd "$root" && gh pr view "$pr" --json headRefOid -q .headRefOid)"
  [ -n "$head" ] || die "could not read the head commit of PR #$pr"
  watch_checks "$root" "$pr" "$head"
  if [ "$merge" != 1 ]; then
    say "checks passed on PR #$pr. Merge it, then re-run this command: it will skip to the DNS wait."
    exit 0
  fi
  state="$(cd "$root" && gh pr checks "$pr" --json bucket -q '[.[].bucket] | map(select(. != "pass" and . != "skipping")) | length')"
  [ "$state" = 0 ] || die "PR #$pr has checks that did not pass; not merging"
  say "merging PR #$pr at ${head:0:12}"
  (cd "$root" && gh pr merge "$pr" --merge --match-head-commit "$head") ||
    die "gh pr merge refused (review required, or the head moved); merge PR #$pr by hand and re-run"
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
