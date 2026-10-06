#!/usr/bin/env bash
# Contract test for `.github/setup-nix/verify-nix-config.sh`.
#
# WHAT THIS PROVES, AND WHY IT IS NOT VACUOUS
# -------------------------------------------
# The defect being guarded against is an installer that no-ops on a runner where
# Nix is ALREADY present, reports success, and leaves `experimental-features`
# unapplied. A test that only exercised the healthy path would pass just as
# happily with no guard at all, which is the same "check reporting accurately
# about the wrong thing" failure the guard exists to end.
#
# So each negative case here does two things in order:
#
#   1. FIXTURE MUTATION CHECK — first prove the fixture genuinely reproduces the
#      defect, by running a plain `nix` command under it and requiring that the
#      command fails the way a real job step would. If the fixture cannot break
#      Nix, the case is declared broken rather than silently passing.
#   2. GUARD CHECK — only then require that verify-nix-config.sh exits non-zero.
#
# Without step 1, a change that made the fixture inert (say, Nix ignoring
# NIX_CONFIG) would turn every negative case into a green no-op.
#
# The suite additionally asserts that action.yml actually INVOKES the guard, so
# deleting the step from the action fails this test rather than quietly
# restoring the original silent-success behaviour.
#
# The native-Darwin service-PATH regression uses real executables rather than
# mocks: a temporary bin directory contains the real Nix and every external
# utility the guard uses except grep. A mutation with the portability bootstrap
# removed must reproduce the old false missing-feature report, then the real
# guard must pass under that identical PATH. This proves both that the fixture
# can trigger the defect and that the fix covers the service environment.

set -euo pipefail

# BEGIN contract-harness system utility PATH bootstrap
# This suite runs after setup-nix on both ephemeral and persistent runners. A
# native Darwin runner service can retain the selected Nix store/profile path
# while omitting /usr/bin, so the TEST HARNESS must establish its own platform
# utilities before it uses dirname/grep/etc. Do not delegate this to the guard
# under test: that would let a production-code mutation repair its own test.
setup_nix_test_incoming_path="${PATH:-}"
setup_nix_test_system_paths=(
  /usr/bin
  /bin
  /usr/sbin
  /sbin
  /run/current-system/sw/bin
  /nix/var/nix/profiles/default/bin
)
for setup_nix_test_system_dir in ${setup_nix_test_system_paths[@]+"${setup_nix_test_system_paths[@]}"}; do
  if [ -d "$setup_nix_test_system_dir" ]; then
    case ":${PATH:-}:" in
      *":$setup_nix_test_system_dir:"*) ;;
      *) PATH="${PATH:+$PATH:}$setup_nix_test_system_dir" ;;
    esac
  fi
done
export PATH

missing_setup_nix_test_utilities=""
for setup_nix_test_utility in bash cat chmod cut dirname grep head ln mkdir mktemp rm rmdir sed sort tr; do
  if ! command -v "$setup_nix_test_utility" >/dev/null 2>&1; then
    missing_setup_nix_test_utilities="$missing_setup_nix_test_utilities $setup_nix_test_utility"
  fi
done
if [ -n "$missing_setup_nix_test_utilities" ]; then
  echo "FAIL — required contract-test utilities are not on PATH:${missing_setup_nix_test_utilities}" >&2
  exit 1
fi
# END contract-harness system utility PATH bootstrap

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
setup_nix_dir="$(cd -- "$script_dir/.." && pwd)"
guard="$setup_nix_dir/verify-nix-config.sh"
action_yml="$setup_nix_dir/action.yml"

assertions=0
failures=0

pass() {
  assertions=$((assertions + 1))
  echo "ok   — $*"
}

fail() {
  assertions=$((assertions + 1))
  failures=$((failures + 1))
  echo "FAIL — $*" >&2
}

[ -f "$guard" ] || {
  echo "FAIL — the guard script is missing: $guard" >&2
  echo "       verify-nix-config.sh is what makes this action verify, rather than" >&2
  echo "       merely assert, that the Nix configuration took effect." >&2
  exit 1
}
[ -f "$action_yml" ] || {
  echo "FAIL — action.yml is missing: $action_yml" >&2
  exit 1
}

if ! command -v nix >/dev/null 2>&1; then
  echo "FAIL — nix is not on PATH; this suite must run where a real Nix exists," >&2
  echo "       because it verifies real Nix behaviour rather than a mock of it." >&2
  exit 1
fi

# Run the complete contract suite from a deterministic approximation of the
# persistent-Darwin service environment: the incoming PATH selects a real Nix
# but contains none of the platform utilities. The child skips this wrapper,
# independently bootstraps the harness utilities above, and runs every existing
# positive and negative assertion. Removing or moving the harness bootstrap
# makes the child fail before its first source-inspection grep.
if [ "${SETUP_NIX_TEST_SERVICE_PATH_CHILD:-}" != "1" ]; then
  harness_service_path_root="$(mktemp -d)"
  harness_service_path_bin="$harness_service_path_root/bin"
  harness_selected_nix="$(command -v nix)"
  mkdir "$harness_service_path_bin"
  ln -s "$harness_selected_nix" "$harness_service_path_bin/nix"

  if PATH="$harness_service_path_bin" \
    SETUP_NIX_TEST_SERVICE_PATH_CHILD=1 \
    SETUP_NIX_TEST_EXPECTED_NIX="$harness_service_path_bin/nix" \
    "$BASH" "${BASH_SOURCE[0]}"; then
    harness_child_status=0
  else
    harness_child_status=$?
  fi
  rm -rf "$harness_service_path_root"
  exit "$harness_child_status"
fi

incoming_service_nix="$({
  PATH="$setup_nix_test_incoming_path"
  export PATH
  command -v nix
})"
if [ "$incoming_service_nix" = "${SETUP_NIX_TEST_EXPECTED_NIX:-}" ] &&
  ! (PATH="$setup_nix_test_incoming_path"; export PATH; command -v grep >/dev/null 2>&1) &&
  command -v grep >/dev/null 2>&1; then
  pass "contract suite bootstraps its own utilities from a service PATH containing only the selected Nix"
else
  fail "contract harness service-PATH regression is broken (incoming nix=$incoming_service_nix expected=${SETUP_NIX_TEST_EXPECTED_NIX:-<unset>})"
fi

# ---------------------------------------------------------------------------
# 1. The action must actually invoke the guard.
# ---------------------------------------------------------------------------
# Match the INVOCATION, not any mention. A comment or an input description that
# merely names the script is not the action running it, and an assertion that
# accepted prose would be satisfied by an action that verifies nothing.
invocation_pattern='github.action_path }}/verify-nix-config.sh'
if grep -qF "$invocation_pattern" "$action_yml"; then
  pass "action.yml invokes verify-nix-config.sh"
else
  fail "action.yml does not invoke verify-nix-config.sh — the action would go back to reporting success without checking that its configuration applied"
fi

# The guard must run in the action AFTER nix.conf is written and BEFORE the
# first step that actually uses Nix (`Start Attic watch-store` runs `nix shell`).
# Otherwise the first casualty of a bad config is still an obscure error in an
# unrelated step.
configure_line="$(grep -n 'name: Configure Nix' "$action_yml" | head -n1 | cut -d: -f1 || true)"
verify_line="$(grep -nF "$invocation_pattern" "$action_yml" | head -n1 | cut -d: -f1 || true)"
attic_line="$(grep -n 'name: Start Attic watch-store' "$action_yml" | head -n1 | cut -d: -f1 || true)"
if [ -n "$configure_line" ] && [ -n "$verify_line" ] && [ -n "$attic_line" ] &&
  [ "$configure_line" -lt "$verify_line" ] && [ "$verify_line" -lt "$attic_line" ]; then
  pass "the guard runs after 'Configure Nix' and before the first Nix-using step"
else
  fail "the guard is not ordered between 'Configure Nix' and 'Start Attic watch-store' (configure=$configure_line verify=$verify_line attic=$attic_line)"
fi

# ---------------------------------------------------------------------------
# 2. Healthy path — the guard must not cry wolf.
# ---------------------------------------------------------------------------
healthy_features="nix-command flakes"
if NIX_CONFIG="experimental-features = $healthy_features" \
  SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES="$healthy_features" \
  bash "$guard" >/dev/null 2>&1; then
  pass "guard exits 0 when every requested experimental feature is in effect"
else
  fail "guard rejected a correctly configured Nix — it would block healthy jobs"
fi

# ---------------------------------------------------------------------------
# 2a. Native-Darwin runner services may omit /usr/bin from PATH.
#
# Retain the real Nix and every other external utility used by the guard, but
# deliberately omit grep. This is the precise environment from the failing
# native-Darwin jobs: Nix reports all requested features as effective, while the
# guard used to turn `grep: command not found` into a false missing-feature
# report. The vulnerable mutation proves this fixture kills the old code before
# the fixed guard is allowed to establish the positive result.
# ---------------------------------------------------------------------------
portable_fixture_root="$(mktemp -d)"
portable_fixture_bin="$portable_fixture_root/bin"
vulnerable_guard="$portable_fixture_root/verify-nix-config-without-path-bootstrap.sh"
no_system_path_guard="$portable_fixture_root/verify-nix-config-without-system-paths.sh"
selected_nix_marker="$portable_fixture_root/selected-nix-used"
selected_nix_real="$(command -v nix)"
mkdir "$portable_fixture_bin"
trap 'rm -rf "$portable_fixture_root"' EXIT

for portable_fixture_utility in mktemp rm cat sed sort tr; do
  portable_fixture_utility_path="$(command -v "$portable_fixture_utility")"
  ln -s "$portable_fixture_utility_path" "$portable_fixture_bin/$portable_fixture_utility"
done

# Delegate to the real Nix, while leaving evidence that the guard preserved the
# incoming PATH's selected Nix instead of replacing it with one from a profile.
{
  printf '#!%s\n' "$BASH"
  cat <<'EOF'
if [ -n "${SETUP_NIX_SELECTED_NIX_MARKER:-}" ]; then
  printf 'used\n' >>"$SETUP_NIX_SELECTED_NIX_MARKER"
fi
exec "$SETUP_NIX_SELECTED_NIX_REAL" "$@"
EOF
} >"$portable_fixture_bin/nix"
chmod +x "$portable_fixture_bin/nix"

if (PATH="$portable_fixture_bin"; export PATH; command -v grep >/dev/null 2>&1); then
  fail "FIXTURE BROKEN: grep is still available in the minimal service PATH"
else
  pass "fixture reproduces a service PATH with real Nix and utilities but no grep"
fi

if portable_nix_probe="$(
  PATH="$portable_fixture_bin" \
    NIX_CONFIG="experimental-features = $healthy_features" \
    SETUP_NIX_SELECTED_NIX_REAL="$selected_nix_real" \
    nix eval --raw --expr '"minimal-path-nix-ok"'
)" && [ "$portable_nix_probe" = "minimal-path-nix-ok" ]; then
  pass "fixture's real Nix has every requested feature in effect"
else
  fail "FIXTURE BROKEN: real Nix is not functional in the minimal service PATH"
fi

sed \
  '/^# BEGIN portable system utility PATH bootstrap$/,/^# END portable system utility PATH bootstrap$/d' \
  "$guard" >"$vulnerable_guard"

set +e
vulnerable_output="$(
  PATH="$portable_fixture_bin" \
    NIX_CONFIG="experimental-features = $healthy_features" \
    SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES="$healthy_features" \
    SETUP_NIX_SELECTED_NIX_REAL="$selected_nix_real" \
    "$BASH" "$vulnerable_guard" 2>&1
)"
vulnerable_exit_code=$?
set -e

if [ "$vulnerable_exit_code" -ne 0 ] &&
  printf '%s' "$vulnerable_output" | grep -q 'grep: command not found' &&
  printf '%s' "$vulnerable_output" | grep -q 'requested experimental features are not in effect'; then
  pass "fixture reproduces the old grep failure and false missing-feature report"
else
  fail "FIXTURE BROKEN: guard without the PATH bootstrap did not reproduce the old failure: $vulnerable_output"
fi

rm -f "$selected_nix_marker"
if PATH="$portable_fixture_bin" \
  NIX_CONFIG="experimental-features = $healthy_features" \
  SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES="$healthy_features" \
  SETUP_NIX_SELECTED_NIX_MARKER="$selected_nix_marker" \
  SETUP_NIX_SELECTED_NIX_REAL="$selected_nix_real" \
  "$BASH" "$guard" >/dev/null 2>&1; then
  pass "guard restores platform utility paths and verifies real Nix from the minimal service PATH"
else
  fail "guard rejected healthy Nix when the incoming service PATH omitted grep"
fi

if [ -s "$selected_nix_marker" ]; then
  pass "PATH repair preserves the incoming service's selected Nix executable"
else
  fail "PATH repair replaced the incoming service's selected Nix with a profile or system Nix"
fi

# Service temp roots can contain shell metacharacters. Cleanup must retain the
# exact mktemp paths rather than interpolating them into a trap command string.
quoted_tmp_dir="$portable_fixture_root/service'tmp"
mkdir "$quoted_tmp_dir"
if TMPDIR="$quoted_tmp_dir" \
  NIX_CONFIG="experimental-features = $healthy_features" \
  SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES="$healthy_features" \
  "$BASH" "$guard" >/dev/null 2>&1; then
  pass "guard succeeds when the service temp path contains a quote"
else
  fail "guard mishandled a quoted service temp path"
fi
if rmdir "$quoted_tmp_dir"; then
  pass "probe cleanup removes exact temp paths containing shell metacharacters"
else
  fail "probe cleanup leaked files from a quoted service temp path"
fi

# Remove only the conventional path entries, retaining the utility preflight.
# This lets the suite verify that the inventory is complete and that each
# helper has a direct diagnostic instead of being misreported as a Nix feature
# failure. The generated guard still executes the real functional probes.
sed '
  /^setup_nix_system_paths=(/,/^)/ {
    /^  \//d
  }
' "$guard" >"$no_system_path_guard"

portable_utility_names="mktemp rm cat grep sed sort tr"
complete_utility_bin="$portable_fixture_root/complete-utility-bin"
mkdir "$complete_utility_bin"
ln -s "$selected_nix_real" "$complete_utility_bin/nix"
for portable_fixture_utility in $portable_utility_names; do
  portable_fixture_utility_path="$(command -v "$portable_fixture_utility")"
  ln -s "$portable_fixture_utility_path" "$complete_utility_bin/$portable_fixture_utility"
done

if PATH="$complete_utility_bin" \
  NIX_CONFIG="experimental-features = $healthy_features" \
  SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES="$healthy_features" \
  "$BASH" "$no_system_path_guard" >/dev/null 2>&1; then
  pass "the declared utility inventory is sufficient for every functional probe"
else
  fail "the guard uses an external utility that its preflight does not declare"
fi

for missing_portable_utility in $portable_utility_names; do
  missing_utility_bin="$portable_fixture_root/missing-$missing_portable_utility-bin"
  mkdir "$missing_utility_bin"
  ln -s "$selected_nix_real" "$missing_utility_bin/nix"
  for portable_fixture_utility in $portable_utility_names; do
    if [ "$portable_fixture_utility" != "$missing_portable_utility" ]; then
      portable_fixture_utility_path="$(command -v "$portable_fixture_utility")"
      ln -s "$portable_fixture_utility_path" "$missing_utility_bin/$portable_fixture_utility"
    fi
  done

  set +e
  missing_utility_output="$(
    PATH="$missing_utility_bin" \
      NIX_CONFIG="experimental-features = $healthy_features" \
      SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES="$healthy_features" \
      "$BASH" "$no_system_path_guard" 2>&1
  )"
  missing_utility_exit_code=$?
  set -e

  if [ "$missing_utility_exit_code" -ne 0 ] &&
    printf '%s' "$missing_utility_output" | grep -qF "required verification utilities are not on PATH: $missing_portable_utility" &&
    ! printf '%s' "$missing_utility_output" | grep -qF 'requested experimental features are not in effect'; then
    pass "missing $missing_portable_utility is diagnosed as a utility failure"
  else
    fail "missing $missing_portable_utility was not diagnosed precisely: $missing_utility_output"
  fi
done

# ---------------------------------------------------------------------------
# 2b. The guard must not be fooled by Nix writing WARNINGS to stderr.
#
# This case exists because the guard originally captured the probe with `2>&1`,
# folding Nix's warnings into the value it then compared against a literal. On
# the real `eph-*` runners the CI user is not in Nix's `trusted-users`, so every
# restricted setting in nix.conf emits a warning, the comparison failed, and a
# perfectly healthy runner was reported broken.
#
# A false alarm is not a harmless failure mode here: a guard that cries wolf
# gets disabled, and then the real defect it was added for goes back to being
# invisible. The healthy-path case above did not catch it because a quiet Nix
# emits nothing on stderr.
# ---------------------------------------------------------------------------
noisy_config="experimental-features = nix-command flakes
setup-nix-bogus-setting = 1"
noisy_probe=""
noisy_probe="$(NIX_CONFIG="$noisy_config" nix eval --raw --expr '"x"' 2>&1 >/dev/null || true)"
if [ -z "$noisy_probe" ]; then
  fail "FIXTURE BROKEN: the noisy fixture produced no stderr output, so it cannot prove the guard tolerates warnings"
else
  pass "fixture makes Nix emit a warning on stderr while the features still work"

  if NIX_CONFIG="$noisy_config" \
    SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES="nix-command flakes" \
    bash "$guard" >/dev/null 2>&1; then
    pass "guard tolerates Nix warnings on stderr instead of misreading them as the probe value"
  else
    fail "guard failed on a HEALTHY Nix that merely wrote a warning to stderr — a false alarm, which gets guards switched off"
  fi
fi

# ---------------------------------------------------------------------------
# 3. THE REGRESSION CASE — a pre-installed Nix with no experimental-features.
#
# This is the exact state `cachix/install-nix-action` leaves behind when it
# prints "Aborting: Nix is already installed" and exits 0.
# ---------------------------------------------------------------------------
broken_env_probe=""
if broken_env_probe="$(NIX_CONFIG="experimental-features =" nix eval --raw --expr '"x"' 2>&1)"; then
  fail "FIXTURE BROKEN: a plain 'nix eval' still succeeded with experimental-features cleared, so this case proves nothing. Guard result ignored."
else
  case "$broken_env_probe" in
    *"'nix-command' is disabled"*)
      pass "fixture reproduces the real defect (nix-command disabled on a pre-installed Nix)"
      ;;
    *)
      fail "FIXTURE BROKEN: 'nix eval' failed for an unexpected reason, not the disabled-feature one: $broken_env_probe"
      ;;
  esac

  if NIX_CONFIG="experimental-features =" \
    SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES="nix-command flakes" \
    bash "$guard" >/dev/null 2>&1; then
    fail "guard PASSED against a pre-installed Nix with no experimental-features — this is the whole defect, undetected"
  else
    pass "guard fails loudly on a pre-installed Nix with no experimental-features"
  fi
fi

# ---------------------------------------------------------------------------
# 4. The partial case — some requested features applied, others silently dropped.
#
# A coarse "can nix run at all" probe waves this through: nix-command and flakes
# work, so every smoke test looks fine, and only a pipe-operator expression far
# downstream fails.
# ---------------------------------------------------------------------------
partial_probe=""
partial_probe="$(NIX_CONFIG="experimental-features = nix-command flakes" nix config show experimental-features 2>&1 || true)"
if printf '%s' "$partial_probe" | tr ' ' '\n' | grep -qxF 'pipe-operators'; then
  fail "FIXTURE BROKEN: pipe-operators is still in effect under the partial fixture, so this case proves nothing"
else
  pass "fixture reproduces a partially applied feature set (pipe-operators absent)"

  if NIX_CONFIG="experimental-features = nix-command flakes" \
    SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES="nix-command flakes pipe-operators" \
    bash "$guard" >/dev/null 2>&1; then
    fail "guard PASSED while a requested feature (pipe-operators) was not in effect"
  else
    pass "guard fails when only some requested features are in effect"
  fi
fi

# ---------------------------------------------------------------------------
# 5. The guard must not leak credentials.
#
# nix.conf carries `access-tokens`, so the failure diagnostics must report the
# presence of an override, never its value.
# ---------------------------------------------------------------------------
secret="ghp_setupnixcanarytokenvalue0000000000000"
guard_output="$(NIX_CONFIG="experimental-features =
access-tokens = github.com=$secret" \
  SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES="nix-command" \
  bash "$guard" 2>&1 || true)"
if printf '%s' "$guard_output" | grep -qF "$secret"; then
  fail "guard printed a credential from NIX_CONFIG into its diagnostics"
else
  pass "guard diagnostics do not echo credentials from NIX_CONFIG"
fi

# ---------------------------------------------------------------------------
# Pin the reviewed count so deleting a whole assertion block cannot leave a
# shorter, apparently green contract suite.
expected_assertions=26
if [ "$assertions" -ne "$expected_assertions" ]; then
  echo "FAIL — expected $expected_assertions assertions, but ran $assertions" >&2
  echo "       contract coverage changed without updating the reviewed count" >&2
  exit 1
fi

echo
echo "verify-nix-config-test: $assertions assertions, $failures failure(s)"
if [ "$failures" -ne 0 ]; then
  exit 1
fi
echo "verify-nix-config-test: PASS"
