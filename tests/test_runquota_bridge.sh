#!/usr/bin/env bash
# test_runquota_bridge
#
# RQE-M6b: the Justfile's one heavy local build, the `ci-image` closure of the `image` recipe, takes a
# RunQuota lease and runs at the granted width instead of assuming every core is its own. A recipe
# that lost its bridge still PASSES (nix just runs wider), so only a test of the bound itself can
# notice. This is that test.
#
# WHAT IS REAL. A private `runquotad` (small CPU budget, socket in a scratch directory,
# RUNQUOTA_SOCKET + RUNQUOTA_ENDPOINT_SCOPE=private, so no other daemon is touched); the REAL
# `runquota run` with its REAL `nix` adapter; the REAL scripts/runquota-bridge.sh; and the REAL
# `image` recipe of the Justfile run through `just`, several sessions at once. The Justfile is copied
# into a scratch tree; scripts/ is symlinked so the helper under test is the real one.
#
# WHAT IS STUBBED, AND WHY. `nix` is a shim first on PATH. The real command would build the CI image
# (hours, and forbidden here); the unit under test is WHICH commands reach the bridge and WHAT
# ARGUMENTS they arrive with, not what nix does. The shim records argv and RUNQUOTA_RUN_WIDTH, then
# for `build` starts one `sleep 0.2537` per slot nix would use (max-jobs x cores; unconstrained is
# modelled as 8) and waits. The odd duration is one nothing else on a host runs, so sampling /proc by
# exact command line counts CPU slots in use across all sessions. `nix run` records and returns at
# once. Not exercised: real nix's treatment of --max-jobs/--cores, and distributed builds (the
# adapter's `--max-jobs 1` limits local jobs only).
#
# WHAT IT ASSERTS
#   1. static: every executable `nix build` line of the Justfile carries the bridge, and the `nix run`
#      line does not;
#   2. `just image`: `--max-jobs 1 --cores N` arrives right after `build`, the rest of argv is
#      unchanged and in order, and the later `nix run` still runs, unbridged, after the build;
#   3. N sessions of `just image` at once never exceed the budget AND exceed 1;
#   4. stdout and exit status pass through the bridge;
#   5. controls: RQ= is off, a runquota lacking the verb is not used, no runquota on PATH runs nix
#      unchanged;
#   6. NEGATIVE CONTROL (--mutate): the bridge is deleted from a copy of the Justfile and the same
#      measurement must then exceed the budget. Prints "MUTATION KILLED" when it does.
#
# Usage: tests/test_runquota_bridge.sh [--mutate]      (or: just test-runquota-bridge [--mutate])
set -uo pipefail

MUTATE=0
[ "${1:-}" = "--mutate" ] && MUTATE=1
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUDGET=3
SESSIONS=6
PASS=0; FAILED=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL $1"; }
die() { echo "test_runquota_bridge: $*" >&2; exit 2; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected [$2], got [$3])"; fi; }
assert_ge() { if [ "$3" -ge "$2" ]; then pass "$1 ($3 >= $2)"; else fail "$1 (expected >= $2, got $3)"; fi; }
assert_le() { if [ "$3" -le "$2" ]; then pass "$1 ($3 <= $2)"; else fail "$1 (expected <= $2, got $3)"; fi; }
assert_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (missing [$2] in [$3])" ;; esac; }
assert_lacks() { case "$3" in *"$2"*) fail "$1 (found [$2] in [$3])" ;; *) pass "$1" ;; esac; }

command -v runquota >/dev/null || die "runquota and runquotad are required on PATH"
command -v runquotad >/dev/null || die "runquota and runquotad are required on PATH"
command -v python3 >/dev/null || die "python3 is required (the /proc sampler)"
JUST="$(command -v just || true)"
[ -n "$JUST" ] || JUST="$(nix shell nixpkgs#just --command sh -c 'command -v just' 2>/dev/null || true)"
[ -x "$JUST" ] || die "just is required (on PATH, or via nix shell nixpkgs#just)"

# A Unix socket path is limited to ~100 bytes: keep the scratch directory under a short parent.
S="$(mktemp -d "/tmp/rqd.XXXXXX")" || die "mktemp failed"
DAEMON_PID=""
cleanup() {
  [ -n "${RQB_KEEP:-}" ] && { echo "kept $S" >&2; return; }
  # Stop only the daemon this script started, and only if the pid still names it.
  if [ -n "$DAEMON_PID" ] && ps -o args= -p "$DAEMON_PID" 2>/dev/null | grep -q -- "--socket $S/rq.sock"; then
    kill "$DAEMON_PID" 2>/dev/null
  fi
  rm -rf "$S"
}
trap cleanup EXIT

# --- the tree under test: a scratch copy of the real Justfile (or of the mutated one) -------------
TREE="$S/tree"
mkdir -p "$TREE" || die "mkdir"
ln -s "$REPO_ROOT/scripts" "$TREE/scripts"
if [ "$MUTATE" = 1 ]; then
  # Delete the bridge from every call site: `{{rq}} nix build` becomes `nix build`.
  sed -e 's/{{rq}} //g' "$REPO_ROOT/Justfile" >"$TREE/Justfile" || die "mutate"
else
  cp "$REPO_ROOT/Justfile" "$TREE/Justfile" || die "copy Justfile"
fi

# --- private daemon ------------------------------------------------------------------------------
export RUNQUOTA_SOCKET="$S/rq.sock" RUNQUOTA_ENDPOINT_SCOPE=private
runquotad --socket "$S/rq.sock" --cpu-milli $((BUDGET * 1000)) --memory-bytes 17179869184 \
  --no-write-stats --estimate-db "$S/est.db" --observation-db "$S/obs.db" --log-file "$S/rqd.log" \
  >"$S/rqd.out" 2>&1 &
DAEMON_PID=$!
for _ in $(seq 100); do runquota status >/dev/null 2>&1 && break; sleep 0.1; done
runquota status >/dev/null 2>&1 || die "the private runquotad did not answer: $(tail -3 "$S/rqd.log" "$S/rqd.out" 2>/dev/null)"

# --- the nix stub --------------------------------------------------------------------------------
mkdir -p "$S/bin"
cat >"$S/bin/nix" <<'EOF2'
#!/usr/bin/env bash
# test shim: record argv and the granted width, answer like nix, hold the slots a build would use.
case "${1:-}" in
  eval) echo "stub-image:latest"; exit 0 ;;      # the Justfile's `image` backtick
  build|run) ;;
  *) exit 0 ;;
esac
verb="$1"
{ printf 'nix-%s W=%s' "$verb" "${RUNQUOTA_RUN_WIDTH:-unset}"; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >>"$NIX_STUB_LOG"
echo "nix-stub-output"
[ -n "${NIX_STUB_FAIL:-}" ] && exit 7
[ "$verb" = run ] && exit 0
# Slots in use = max-jobs x cores; a nix with neither flag is modelled as using every core (8).
jobs=1; cores=8
while [ $# -gt 0 ]; do
  case "$1" in
    --max-jobs|-j) jobs="$2"; shift ;;
    --cores) cores="$2"; shift ;;
  esac
  shift
done
for _ in $(seq $((jobs * cores))); do sleep 0.2537 & done
wait
EOF2
chmod +x "$S/bin/nix"
export PATH="$S/bin:$PATH" NIX_STUB_LOG="$S/stub.log"
unset RUNQUOTA_RUN_WIDTH RQ NIX_STUB_FAIL CI

cat >"$S/sample.py" <<'EOF2'
import os, sys, time
stop, out = sys.argv[1], sys.argv[2]
peak = 0
while not os.path.exists(stop):
    n = 0
    for p in os.listdir('/proc'):
        if p.isdigit():
            try:
                with open('/proc/%s/cmdline' % p, 'rb') as f:
                    if f.read() == b'sleep\x000.2537\x00':
                        n += 1
            except OSError:
                pass
    peak = max(peak, n)
    time.sleep(0.005)
open(out, 'w').write(str(peak))
EOF2

jt() { "$JUST" --justfile "$TREE/Justfile" --working-directory "$TREE" "$@"; }

# measure_peak <label>: SESSIONS sessions of `just image` at once; print the peak slots in use.
measure_peak() {
  local label="$1" pids=() sp i p
  rm -f "$S/stop" "$S/peak.$label"; : >"$NIX_STUB_LOG"
  python3 -I "$S/sample.py" "$S/stop" "$S/peak.$label" & sp=$!
  for i in $(seq "$SESSIONS"); do
    jt image >"$S/session.$label.$i.out" 2>&1 & pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  : >"$S/stop"; wait "$sp"
  cat "$S/peak.$label"
}

if [ "$MUTATE" = 1 ]; then
  echo "== negative control: the bridge deleted from a copy of the Justfile =="
  peak="$(measure_peak mutant)"
  if [ "$peak" -gt "$BUDGET" ]; then
    echo "MUTATION KILLED: without the bridge the peak was $peak slots, over the budget of $BUDGET"
    exit 0
  fi
  echo "MUTATION SURVIVED: peak $peak did not exceed the budget of $BUDGET; the test cannot see a missing bridge"
  exit 1
fi

echo "== 1. static: every executable 'nix build' line is bridged, 'nix run' is not =="
builds="$(grep -nE '(^|[[:space:]({`])(nix build|nix-build)([[:space:]]|$)' "$REPO_ROOT/Justfile" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
nb_total="$(printf '%s\n' "$builds" | grep -c . || true)"
nb_bridged="$(printf '%s\n' "$builds" | grep -c '{{rq}}' || true)"
assert_ge "the Justfile has at least one nix build line" 1 "$nb_total"
assert_eq "every nix build line carries {{rq}}" "$nb_total" "$nb_bridged"
runs="$(grep -E '^[[:space:]]+nix run ' "$REPO_ROOT/Justfile" | grep -E 'ci-image' || true)"
assert_contains "the ci-image nix run line exists" "nix run" "$runs"
assert_lacks "the nix run line is not bridged" "{{rq}}" "$runs"

echo "== 2. 'just image' =="
dry="$(jt --dry-run image 2>&1)"
assert_contains "the build line is bridged" 'runquota-bridge.sh" run -- nix build --no-link' "$dry"
assert_eq "exactly one line is bridged" 1 "$(printf '%s\n' "$dry" | grep -c 'runquota-bridge')"
attr=copyToDockerDaemon; command -v podman >/dev/null 2>&1 && attr=copyToPodman
: >"$NIX_STUB_LOG"
jt image >"$S/image.out" 2>&1; assert_eq "just image succeeds" 0 "$?"
build_line="$(grep '^nix-build ' "$NIX_STUB_LOG")"
run_line="$(grep '^nix-run ' "$NIX_STUB_LOG")"
case "$build_line" in
  *"[build] [--max-jobs] [1] [--cores] ["*"] [--no-link] [--accept-flake-config] [--offline] [.#ci-image.$attr]") pass "--max-jobs 1 --cores N right after build; the rest of argv unchanged and in order" ;;
  *) fail "build argv: [$build_line]" ;;
esac
assert_eq "the nix run line is not bridged and runs unchanged" "nix-run W=unset [run] [--accept-flake-config] [--offline] [.#ci-image.$attr]" "$run_line"
assert_eq "the build runs before the nix run" "nix-build nix-run" "$(awk '{print $1}' "$NIX_STUB_LOG" | tr '\n' ' ' | sed 's/ $//')"
CI=true jt image >/dev/null 2>&1
assert_lacks "CI=true drops --offline from the build, as before" "--offline" "$(grep '^nix-build ' "$NIX_STUB_LOG" | tail -1)"

echo "== 3. concurrency: $SESSIONS sessions, budget $BUDGET =="
peak="$(measure_peak on)"
assert_le "the peak slots in use never exceed the budget" "$BUDGET" "$peak"
assert_ge "the peak exceeds 1 (the build really ran in parallel)" 2 "$peak"
assert_eq "every session ran its build and its nix run" "$((SESSIONS * 2))" "$(grep -c '^nix-' "$NIX_STUB_LOG")"

echo "== 4. stdout and exit status =="
out="$("$REPO_ROOT/scripts/runquota-bridge.sh" run -- nix build .#x)"
assert_eq "a \$(...) capture sees only the command's own output" "nix-stub-output" "$out"
NIX_STUB_FAIL=1 "$REPO_ROOT/scripts/runquota-bridge.sh" run -- nix build .#x >/dev/null; assert_eq "the command's exit status passes through" 7 "$?"
NIX_STUB_FAIL=1 jt image >/dev/null 2>&1; assert_eq "a failing build fails the recipe with its status" 7 "$?"
assert_eq "a failed build stops the recipe before nix run" 0 "$(grep -c '^nix-run' <(NIX_STUB_FAIL=1 sh -c ": >$NIX_STUB_LOG; $JUST --justfile $TREE/Justfile --working-directory $TREE image >/dev/null 2>&1; cat $NIX_STUB_LOG"))"
"$REPO_ROOT/scripts/runquota-bridge.sh" >/dev/null 2>&1; assert_eq "no verb is a usage error" 2 "$?"
"$REPO_ROOT/scripts/runquota-bridge.sh" run nix build >/dev/null 2>&1; assert_eq "a missing -- is a usage error" 2 "$?"

echo "== 5. the escape hatch and its controls =="
: >"$NIX_STUB_LOG"
RQ='' "$REPO_ROOT/scripts/runquota-bridge.sh" run -- nix build .#x >/dev/null
assert_eq "RQ= runs nix with no lease and no width flag" "nix-build W=unset [build] [.#x]" "$(cat "$NIX_STUB_LOG")"
peak_off="$(RQ='' measure_peak off)"
assert_ge "RQ= turns the bridge off: the same sessions then exceed the budget" $((BUDGET + 1)) "$peak_off"
# A runquota that predates the verb prints usage and exits 0 -- it must not be used.
mkdir -p "$S/old"; printf '#!/usr/bin/env bash\necho "usage: runquota ..."; exit 0\n' >"$S/old/runquota"; chmod +x "$S/old/runquota"
: >"$NIX_STUB_LOG"
PATH="$S/old:$PATH" "$REPO_ROOT/scripts/runquota-bridge.sh" run -- nix build .#x >/dev/null
assert_eq "a runquota without the run verb is not used; nix runs unchanged" "nix-build W=unset [build] [.#x]" "$(cat "$NIX_STUB_LOG")"
# A PATH of symlinks to just the tools the script and the stub use: whole tool directories can also
# hold `runquota`, which would defeat the control.
mkdir -p "$S/nort"
for t in bash env tr dirname basename seq sleep cat; do ln -sf "$(command -v "$t")" "$S/nort/$t"; done
: >"$NIX_STUB_LOG"
PATH="$S/bin:$S/nort" "$REPO_ROOT/scripts/runquota-bridge.sh" run -- nix build .#x >/dev/null
assert_eq "with no runquota on PATH nix runs unchanged" "nix-build W=unset [build] [.#x]" "$(cat "$NIX_STUB_LOG")"

echo
echo "test_runquota_bridge: $PASS passed, $FAILED failed"
[ "$FAILED" = 0 ]
