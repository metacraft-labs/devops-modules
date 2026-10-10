#!/usr/bin/env bash
# Offline test of scripts/google-workspace-dkim.sh: no network, no GitHub, no
# credentials. `dig` and `gh` are stubs on PATH; keys are generated here with
# openssl; "origin" is a local bare repository.
#
#   bash scripts/tests/test-google-workspace-dkim.sh
#   (also run by `nix build .#checks.<system>.google-workspace-dkim-test`)
#
# Needs bash, coreutils, gawk, git, jq, openssl on PATH.
# The `bash -c '…"$1"…' _ args` assertions expand their arguments inside, on purpose.
# shellcheck disable=SC2016
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tool="${GOOGLE_WORKSPACE_DKIM_SCRIPT:-$here/../google-workspace-dkim.sh}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
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
  fails=$((fails + 1))
}
expect() { # $1 description, rest: command that must succeed
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}
expect_not() {
  local d="$1"
  shift
  if "$@"; then bad "$d"; else ok "$d"; fi
}
run() { bash "$tool" "$@" 2>"$work/stderr"; }
runq() { run "$@" >/dev/null; }
stderr_has() { grep -qF -- "$1" "$work/stderr"; }

# ── stubs ────────────────────────────────────────────────────────────────────
# dig: answers from $work/dns/<name>@<resolver>, falling back to $work/dns/<name>.
# (The interpreter is spelled out: a build sandbox has no /usr/bin/env.)
printf '#!%s\n' "$(command -v bash)" | tee "$work/bin/dig" >"$work/bin/gh"
cat >>"$work/bin/dig" <<'EOF'
# NS queries answer from $work/dns/<name>.NS. Every query is logged.
name="" resolver="" type=TXT
for a in "$@"; do
  case "$a" in
    @*) resolver="${a#@}" ;;
    +*) ;;
    TXT | NS) type="$a" ;;
    *) name="$a" ;;
  esac
done
echo "dig $*" >>"$STUB_DIG_LOG"
if [ "$type" = NS ]; then
  [ -f "$STUB_DNS/$name.NS" ] && cat "$STUB_DNS/$name.NS"
  exit 0
fi
f="$STUB_DNS/$name@$resolver"
[ -f "$f" ] || f="$STUB_DNS/$name"
[ -f "$f" ] && cat "$f"
exit 0
EOF
# gh: logs every call; answers the few queries the tool makes.
cat >>"$work/bin/gh" <<'EOF'
echo "gh $*" >>"$STUB_GH_LOG"
case "$1 $2" in
  "pr list") echo "${STUB_GH_OPEN_PR:-}" ;;
  "pr create") echo "https://github.invalid/o/r/pull/7" ;;
  "pr checks")
    if [[ " $* " == *" --watch "* ]]; then exit "${STUB_GH_CHECKS_RC:-0}"; fi
    echo 0 ;;
  "pr view") git -C "$STUB_ORIGIN" rev-parse "refs/heads/$STUB_BRANCH" ;;
  "pr merge") exit 0 ;;
  "run list") # one state per call from $STUB_GH_RUNS_FILE, then "ok"
    if [ -s "${STUB_GH_RUNS_FILE:-/nonexistent}" ]; then
      head -n1 "$STUB_GH_RUNS_FILE"
      sed -i 1d "$STUB_GH_RUNS_FILE"
    else
      echo ok
    fi ;;
  "repo view") echo main ;;
  *) echo "gh stub: unexpected $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$work/bin/dig" "$work/bin/gh"
export PATH="$work/bin:$PATH" STUB_DNS="$work/dns" STUB_GH_LOG="$work/gh.log" STUB_DIG_LOG="$work/dig.log"
export STUB_GH_RUNS_FILE="$work/gh-runs"
export GOOGLE_WORKSPACE_DKIM_DNS_INTERVAL=1 GOOGLE_WORKSPACE_DKIM_RESOLVERS="192.0.2.1 192.0.2.2"
export GOOGLE_WORKSPACE_DKIM_CHECK_INTERVAL=0

# ── keys ─────────────────────────────────────────────────────────────────────
pubkey() { openssl genrsa "$1" 2>/dev/null | openssl rsa -pubout -outform DER 2>/dev/null | base64 -w0; }
v2048="v=DKIM1; k=rsa; p=$(pubkey 2048)"
v2048b="v=DKIM1; k=rsa; p=$(pubkey 2048)"
v1024="v=DKIM1; k=rsa; p=$(pubkey 1024)"
ec="v=DKIM1; k=rsa; p=$(openssl ecparam -name prime256v1 -genkey 2>/dev/null | openssl ec -pubout -outform DER 2>/dev/null | base64 -w0)"
# The multi-string form a resolver (or a console) shows for a long value.
split="\"${v2048:0:255}\" \"${v2048:255}\""

# ── 1. value parsing and validation ──────────────────────────────────────────
expect "a plain 2048-bit value is accepted unchanged" \
  test "$(run validate --value "$v2048")" = "$v2048"
expect "a quoted value is unquoted" \
  test "$(run validate --value "\"$v2048\"")" = "$v2048"
expect "the multi-string form is reassembled" \
  test "$(run validate --value "$split")" = "$v2048"
expect "a pasted multi-string value on stdin, ended by an empty line, is reassembled" \
  test "$(printf '  %s\r\n\n' "$split" | bash "$tool" validate 2>/dev/null)" = "$v2048"
expect "the bit length is reported" bash -c 'bash "$1" validate --value "$2" 2>&1 >/dev/null | grep -q "2048-bit RSA"' _ "$tool" "$v2048"
expect_not "a 1024-bit key is refused" run validate --value "$v1024"
expect "... with a message naming the size" stderr_has "is 1024 bits"
expect "a 1024-bit key passes with --allow-1024" runq validate --allow-1024 --value "$v1024"
expect_not "a value without v=DKIM1 is refused" run validate --value "${v2048#v=DKIM1; }"
expect_not "k=ed25519 is refused" run validate --value "${v2048/k=rsa/k=ed25519}"
expect_not "p= that is not base64 is refused" run validate --value "v=DKIM1; k=rsa; p=@@@@"
expect_not "an EC public key is refused" run validate --value "$ec"
expect_not "text outside the quotes is refused" run validate --value "$split junk"

# ── 2. the data file edit ────────────────────────────────────────────────────
repo="$work/repo"
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
    }
  }
}
EOF
printf 'census line\n' >"$repo/census.expected"
git -C "$repo" add -A && git -C "$repo" commit --quiet -m init
cp "$data" "$work/data.orig"
# The hook appends the record key to a census and logs its environment.
hook='printf "%s\n" "$RECORD_KEY" >>census.expected; echo "$DOMAIN $SELECTOR $RECORD_NAME" >>"'"$work"'/hook.log"'

expect_not "publish refuses a domain the data file does not declare" \
  run publish --no-pr --no-open --domain example.org --data "$data" --value "$v2048"
expect "... and says how to declare it" stderr_has ".domains[\$d] = {zone_id: \$z, dkim: {}}"
expect "... and leaves the file byte-identical" cmp -s "$data" "$work/data.orig"

expect "publish --no-pr sets the value for a declared domain" \
  run publish --no-pr --no-open --domain example.com --data "$data" --value "$split" --post-edit "$hook"
expect "... at .domains[D].dkim[selector], reassembled" \
  test "$(jq -r '.domains["example.com"].dkim.google' "$data")" = "$v2048"
expect "... leaving the zone id alone" \
  test "$(jq -r '.domains["example.com"].zone_id' "$data")" = 0123456789abcdef0123456789abcdef
expect "... and runs the hook with DOMAIN/SELECTOR/RECORD_NAME" \
  test "$(cat "$work/hook.log")" = "example.com google google._domainkey.example.com"
expect "... in the repository root (RECORD_KEY reached its census)" \
  grep -qxF 'google._domainkey.example.com|TXT' "$repo/census.expected"

cp "$data" "$work/data.after"
expect "re-running with the same value succeeds" \
  run publish --no-pr --no-open --domain example.com --data "$data" --value "$v2048" --post-edit "$hook"
expect "... says the value is already there" stderr_has "already holds this value"
expect "... leaves the file byte-identical" cmp -s "$data" "$work/data.after"
expect "... and does not run the hook again" test "$(wc -l <"$work/hook.log")" = 1

expect_not "a different value for the same selector is refused" \
  run publish --no-pr --no-open --domain example.com --data "$data" --value "$v2048b"
expect "... pointing at a new selector" stderr_has "use a new selector"
expect "... and leaves the file byte-identical" cmp -s "$data" "$work/data.after"
expect "a second selector is added next to the first" \
  run publish --no-pr --no-open --domain example.com --selector google2026 --data "$data" --value "$v2048b"
expect "... both present" \
  test "$(jq -r '.domains["example.com"].dkim | keys | join(",")' "$data")" = "google,google2026"

# ── 3. check: lookup, reassembly, comparison ─────────────────────────────────
name=google._domainkey.example.com
printf '%s\n' "$split" >"$work/dns/$name"
printf '"v=spf1 include:_spf.google.com ~all"\n"some-verification=abc"\n' >"$work/dns/example.com"
printf '"v=DMARC1; p=none"\n' >"$work/dns/_dmarc.example.com"
expect "check passes when every resolver answers the split value equal to the data" \
  runq check --domain example.com --expect-file "$data"
expect "... printing the reassembled value" bash -c 'bash "$1" check --domain example.com 2>/dev/null | grep -qxF "google._domainkey.example.com @192.0.2.1: $2"' _ "$tool" "$v2048"
expect "... and the SPF and DMARC records" bash -c 'out="$(bash "$1" check --domain example.com 2>/dev/null)"; grep -q "^SPF   example.com: v=spf1 include:_spf.google.com ~all$" <<<"$out" && grep -q "^DMARC _dmarc.example.com: v=DMARC1; p=none$" <<<"$out"' _ "$tool"
printf '"%s"\n' "$v2048b" >"$work/dns/$name"
expect_not "check fails when the published value differs from the data" \
  runq check --domain example.com --expect-file "$data"
printf '%s\n' "$split" >"$work/dns/$name"
printf '"%s"\n' "$v2048b" >"$work/dns/$name@192.0.2.2"
expect_not "check fails when the resolvers disagree" runq check --domain example.com
rm -f "$work/dns/$name@192.0.2.2" "$work/dns/$name"
expect_not "check fails when there is no record" runq check --domain example.com
printf '%s\n"%s"\n' "$split" "$v2048b" >"$work/dns/$name"
expect_not "check fails when a selector holds two TXT records" runq check --domain example.com

# ── 4. the PR flow (stub gh, local bare origin) ──────────────────────────────
origin="$work/origin.git"
git init --quiet --bare "$origin"
git -C "$origin" symbolic-ref HEAD refs/heads/main
git -C "$repo" checkout --quiet -- "$data" 2>/dev/null || true
git -C "$repo" reset --quiet --hard
# Like a dev shell: an ignored, generated .pre-commit-config.yaml and a commit
# hook that refuses without it. The PR flow commits in a fresh worktree.
echo '.pre-commit-config.yaml' >>"$repo/.gitignore"
git -C "$repo" add .gitignore
git -C "$repo" commit --quiet -m "ignore the generated hook config"
echo 'repos: []' >"$work/generated-pre-commit-config.yaml"
ln -s "$work/generated-pre-commit-config.yaml" "$repo/.pre-commit-config.yaml"
cat >"$repo/.git/hooks/pre-commit" <<'HOOK'
#!/bin/sh
[ -e .pre-commit-config.yaml ] || { echo "error: config file not found: .pre-commit-config.yaml" >&2; exit 1; }
HOOK
chmod +x "$repo/.git/hooks/pre-commit"
git -C "$repo" remote add origin "$origin"
git -C "$repo" push --quiet origin HEAD:main
# Unrelated local work in the operator's checkout must not reach the commit.
echo dirty >"$repo/unrelated.txt"
echo edited >>"$repo/census.expected"
export STUB_ORIGIN="$origin" STUB_BRANCH="dkim/example.com-google"
printf '%s\n' "$split" >"$work/dns/$name"
: >"$STUB_GH_LOG"

expect "publish (no --merge) opens a PR and stops after the checks" \
  run publish --no-open --base main --domain example.com --data "$data" --value "$v2048" --post-edit "$hook"
pushed="$(git -C "$origin" rev-parse --verify --quiet "refs/heads/$STUB_BRANCH" || true)"
expect "... pushed branch dkim/<domain>-<selector>" test -n "$pushed"
expect "... committing exactly the data file and the file the hook changed" \
  test "$(git -C "$origin" diff --name-only "main" "$pushed" | sort | tr '\n' ' ')" = "census.expected dns/mail-auth.json "
expect "... with the value in the committed data" \
  test "$(git -C "$origin" show "$pushed:dns/mail-auth.json" | jq -r '.domains["example.com"].dkim.google')" = "$v2048"
expect "... without the operator's unrelated edit to the census" \
  bash -c '! git -C "$1" show "$2:census.expected" | grep -qx edited' _ "$origin" "$pushed"
expect "... committing although the hook needs the ignored, generated config" test -n "$pushed"
expect "... which is not part of the commit" \
  bash -c '! git -C "$1" show "$2:.pre-commit-config.yaml" >/dev/null 2>&1' _ "$origin" "$pushed"
expect "... and leaves the operator's checkout as it was" \
  test "$(git -C "$repo" status --porcelain | tr '\n' ' ')" = " M census.expected ?? unrelated.txt "
expect "... created the PR against the base" grep -q "^gh pr create --base main --head $STUB_BRANCH" "$STUB_GH_LOG"
expect "... and did not merge" bash -c '! grep -q "pr merge" "$1"' _ "$STUB_GH_LOG"
expect "... telling the operator to merge and re-run" stderr_has "Merge it, then re-run"

: >"$STUB_GH_LOG"
export STUB_GH_OPEN_PR=7
expect "re-running with --merge resumes the open PR and merges it" \
  run publish --no-open --merge --dns-timeout 5 --base main --domain example.com --data "$data" --value "$v2048"
expect "... without opening a second PR" bash -c '! grep -q "pr create" "$1"' _ "$STUB_GH_LOG"
expect "... merging only at the watched head commit" \
  grep -qx "gh pr merge 7 --merge --match-head-commit $pushed" "$STUB_GH_LOG"
expect "... (the final message names Start authentication)" stderr_has '"Start authentication"'
unset STUB_GH_OPEN_PR

: >"$STUB_GH_LOG"
export STUB_GH_CHECKS_RC=1 STUB_GH_OPEN_PR=7
expect_not "a failed check stops publish before any merge" \
  run publish --no-open --merge --dns-timeout 0 --base main --domain example.com --data "$data" --value "$v2048"
expect "... no merge was attempted" bash -c '! grep -q "pr merge" "$1"' _ "$STUB_GH_LOG"
unset STUB_GH_CHECKS_RC STUB_GH_OPEN_PR

# The reported checks pass while a workflow run is still going (a job that
# `needs:` another has not registered its check yet), then one fails.
: >"$STUB_GH_LOG"
printf 'pending\nbad\n' >"$STUB_GH_RUNS_FILE"
export STUB_GH_OPEN_PR=7
expect_not "a workflow run that fails after the reported checks passed stops the merge" \
  run publish --no-open --merge --dns-timeout 0 --base main --domain example.com --data "$data" --value "$v2048"
expect "... after watching the checks again while the run was pending" \
  test "$(grep -c -- "pr checks 7 --watch" "$STUB_GH_LOG")" = 2
expect "... and no merge was attempted" bash -c '! grep -q "pr merge" "$1"' _ "$STUB_GH_LOG"
: >"$STUB_GH_RUNS_FILE"

# An open PR whose branch carries another value (the key was regenerated in
# the console since) must not be resumed.
: >"$STUB_GH_LOG"
expect_not "an open PR carrying a different value is not resumed" \
  run publish --no-open --merge --dns-timeout 0 --base main --domain example.com --data "$data" --value "$v2048b"
expect "... saying the key may have been regenerated" stderr_has "was the key regenerated?"
expect "... and nothing was watched or merged" bash -c '! grep -qE "pr (checks|merge)" "$1"' _ "$STUB_GH_LOG"
unset STUB_GH_OPEN_PR

# The PR merged: origin/main now carries the value.
git -C "$origin" update-ref refs/heads/main "$pushed"
: >"$STUB_GH_LOG"
expect "once the value is on the base, a re-run skips straight to the DNS wait" \
  run publish --no-open --dns-timeout 5 --base main --domain example.com --data "$data" --value "$v2048"
expect "... without any PR call" bash -c '! grep -q "gh pr" "$1"' _ "$STUB_GH_LOG"
expect "... and reports the record live" stderr_has "resolves to the published value on every one of the public resolvers"
# With the zone's nameservers known, they are asked first (non-recursively),
# and the public resolvers only once the nameservers serve the value.
printf 'ns1.example.invalid.\n' >"$work/dns/example.com.NS"
printf '"%s"\n' "$v2048b" >"$work/dns/$name@ns1.example.invalid"
: >"$STUB_DIG_LOG"
expect_not "the DNS wait does not finish while the zone's nameservers serve another value" \
  run publish --no-open --dns-timeout 0 --base main --domain example.com --data "$data" --value "$v2048"
expect "... naming the nameservers" stderr_has "on the zone's nameservers"
expect "... asking them without recursion" grep -q -- "+norecurse TXT $name @ns1.example.invalid" "$STUB_DIG_LOG"
expect "... and never asking a public resolver for the record" bash -c '! grep -q "TXT $2 @192.0.2" "$1"' _ "$STUB_DIG_LOG" "$name"
rm -f "$work/dns/$name@ns1.example.invalid"
: >"$STUB_DIG_LOG"
expect "once the nameservers serve the value, the public resolvers are asked and the wait ends" \
  run publish --no-open --dns-timeout 5 --base main --domain example.com --data "$data" --value "$v2048"
expect "... in that order" bash -c 'grep -n "TXT $2 @" "$1" | head -n1 | grep -q "@ns1.example.invalid"' _ "$STUB_DIG_LOG" "$name"
rm -f "$work/dns/example.com.NS"

printf '"%s"\n' "$v2048b" >"$work/dns/$name"
expect_not "the DNS wait gives up at --dns-timeout when the answer differs" \
  run publish --no-open --dns-timeout 0 --base main --domain example.com --data "$data" --value "$v2048"
expect "... saying what each resolver answers" stderr_has "@192.0.2.1 answers:"

echo
if [ "$fails" -ne 0 ]; then
  echo "test-google-workspace-dkim: $fails FAILED"
  exit 1
fi
echo "test-google-workspace-dkim: all passed"
