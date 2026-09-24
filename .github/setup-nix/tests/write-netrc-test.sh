#!/usr/bin/env bash
# Contract test for write-netrc.sh — the credential path that makes a
# `type = "git"` private flake input fetchable.
#
# It exercises the real script through its isolated-home seam. In addition to
# final contents, the mv shim observes that the old destination stays intact
# until a complete mode-0600 replacement is atomically renamed over it.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
target="${SETUP_NIX_WRITE_NETRC_TARGET:-$script_dir/write-netrc.sh}"
test_root="$(mktemp -d)"
failures=0

# Invoked indirectly by the traps below.
# shellcheck disable=SC2329
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

check() { # check <description> <condition-exit-code>
  if [[ "$2" -eq 0 ]]; then
    echo "  ok:   $1"
  else
    echo "  FAIL: $1"
    failures=$((failures + 1))
  fi
}

# The harness's own tools must exist before any assertion runs. Several
# checks are NEGATIVE ("no temporary credential remains") and are written as
# `[[ -z "$(find ...)" ]]`: with `find` missing, the substitution is empty and
# the check passes vacuously while the paired positive check fails for a
# misleading reason. That is exactly what the minimal-PATH m3 service runner
# produced ("an unremovable temporary credential remains protected at mode
# 600" failed, every "leaves no temporary credential" check passed). A harness
# that cannot observe must refuse to report, not report success.
missing_harness_tools=()
for harness_tool in awk grep sed cmp find stat cp ln readlink chmod mkdir mktemp mv rm cat wc dirname env; do
  command -v "$harness_tool" >/dev/null 2>&1 || missing_harness_tools+=("$harness_tool")
done
if (( ${#missing_harness_tools[@]} > 0 )); then
  echo "write-netrc-test: harness tools missing from PATH: ${missing_harness_tools[*]}" >&2
  echo "write-netrc-test: refusing to run; negative assertions would pass vacuously" >&2
  exit 2
fi

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

github_stanza_count() {
  awk '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      split(line, fields, /[[:space:]]+/)
      host = tolower(fields[2])
      sub(/\r$/, "", host)
      if (tolower(fields[1]) == "machine" && host == "github.com") count++
    }
    END { print count + 0 }
  ' "$1"
}

literal_count() {
  awk -v needle="$2" '
    {
      rest = $0
      while ((position = index(rest, needle)) != 0) {
        count++
        rest = substr(rest, position + length(needle))
      }
    }
    END { print count + 0 }
  ' "$1"
}

has_exact_canonical_stanza() {
  awk -v expected_token="$2" '
    $0 == "machine github.com" {
      if ((getline login_line) <= 0 || login_line != "  login x-access-token") invalid = 1
      if ((getline password_line) <= 0 || password_line != "  password " expected_token) invalid = 1
      canonical_count++
    }
    END { exit(canonical_count == 1 && !invalid ? 0 : 1) }
  ' "$1"
}

write_rotation_fixtures() {
  fixture_home="$1"
  mkdir -p "$fixture_home/.config/nix"
  printf '%s\n' \
    '# leading comment remains' \
    'machine example.com' \
    '  login example-user' \
    '  password keep-example-token' \
    'machine github.com login old-inline-user password old-inline-token' \
    'machine github.com' \
    '  login old-multiline-user' \
    '  password old-multiline-token' \
    '# comment between the removed record and the next machine remains' \
    '' \
    'machine gitlab.com login gitlab-user password keep-gitlab-token' \
    '# trailing comment remains' > "$fixture_home/.netrc"
  printf '%s\n' \
    'machine github.com login old-nix-inline password old-nix-inline-token' \
    'machine cache.example.test' \
    '  login cache-user' \
    '  password keep-cache-token' \
    'machine github.com' \
    '  login old-nix-multiline' \
    '  password old-nix-multiline-token' \
    'default login default-user password keep-default-token' > "$fixture_home/.config/nix/netrc"
}

assert_rotated_file() {
  rotated_file="$1"
  label="$2"
  expected_token="$3"

  assertion_rc=1
  [[ "$(github_stanza_count "$rotated_file")" == "1" ]] && assertion_rc=0
  check "$label contains exactly one github.com stanza" "$assertion_rc"
  assertion_rc=1
  [[ "$(literal_count "$rotated_file" "$expected_token")" == "1" ]] && assertion_rc=0
  check "$label contains the new token exactly once" "$assertion_rc"
  has_exact_canonical_stanza "$rotated_file" "$expected_token"
  check "$label uses the exact canonical three-line GitHub stanza" $?
  ! grep -Fq 'old-' "$rotated_file"
  check "$label contains no old GitHub credential" $?
  [[ "$(file_mode "$rotated_file")" == "600" ]]
  check "$label is mode 600" $?
}

echo "write-netrc-test: exercising $target"

# ── §1 pre-Nix PATH: the real parser must not depend on awk ─────────────────
minimal_path="$test_root/minimal-pre-nix-path"
minimal_home="$test_root/minimal-pre-nix-home"
mkdir -p "$minimal_path"
write_rotation_fixtures "$minimal_home"
for command_name in bash chmod mkdir mktemp mv rm; do
  command_path="$(command -v "$command_name")"
  ln -s "$command_path" "$minimal_path/$command_name"
done

assertion_rc=1
if [[ ! -e "$minimal_path/awk" ]] && ! PATH="$minimal_path" command -v awk >/dev/null 2>&1; then
  assertion_rc=0
fi
check "the deliberately minimal pre-Nix PATH contains no awk" "$assertion_rc"

minimal_output="$test_root/minimal-pre-nix-output"
PATH="$minimal_path" \
  SETUP_NIX_NETRC_HOME="$minimal_home" \
  SETUP_NIX_GITHUB_TOKEN="new-minimal-token" \
  bash "$target" > "$minimal_output" 2>&1
minimal_rc=$?
check "runs successfully on a deliberately awk-free pre-Nix PATH" "$minimal_rc"
! grep -Fq 'new-minimal-token' "$minimal_output"
check "awk-free execution does not print the token" $?
assert_rotated_file "$minimal_home/.netrc" 'awk-free user netrc' 'new-minimal-token'
assert_rotated_file "$minimal_home/.config/nix/netrc" 'awk-free Nix netrc' 'new-minimal-token'

! grep -Eq '(^|[^[:alnum:]_])awk([^[:alnum:]_]|$)' "$target"
check "the production writer contains no awk command" $?

# ── §2 rotation: one-line and multiline GitHub records are replaced ────────
rotation_home="$test_root/rotation-home"
write_rotation_fixtures "$rotation_home"

rotation_output="$test_root/rotation-output"
SETUP_NIX_NETRC_HOME="$rotation_home" SETUP_NIX_GITHUB_TOKEN="new-rotation-token" \
  bash "$target" > "$rotation_output" 2>&1
rotation_rc=$?
check "runs successfully when a replacement token is supplied" "$rotation_rc"
! grep -Fq 'new-rotation-token' "$rotation_output"
check "does not print the new token" $?

assert_rotated_file "$rotation_home/.netrc" 'user netrc' 'new-rotation-token'
assert_rotated_file "$rotation_home/.config/nix/netrc" 'Nix netrc' 'new-rotation-token'

grep -Fq 'keep-example-token' "$rotation_home/.netrc" &&
  grep -Fq 'keep-gitlab-token' "$rotation_home/.netrc" &&
  grep -Fq '# leading comment remains' "$rotation_home/.netrc" &&
  grep -Fq '# comment between the removed record and the next machine remains' "$rotation_home/.netrc" &&
  grep -Fq '# trailing comment remains' "$rotation_home/.netrc"
check "user netrc preserves unrelated machine entries and comments" $?

grep -Fq 'keep-cache-token' "$rotation_home/.config/nix/netrc" &&
  grep -Fq 'keep-default-token' "$rotation_home/.config/nix/netrc"
check "Nix netrc preserves unrelated machine and default entries" $?

# ── §3 parser boundaries: case/spacing/CRLF/macdef/EOF remain safe ──────────
parser_home="$test_root/parser-home"
mkdir -p "$parser_home/.config/nix"
printf '  MaChInE\tGitHub.COM\r\n\tlogin stale-crlf\r\n\tpassword stale-crlf-token\r\n# keep-crlf-comment\r\n\r\n  DEFAULT\r\n\tlogin keep-default-crlf\r\n\tpassword keep-default-crlf-token' > "$parser_home/.netrc"
printf '%s\n' \
  'macdef deploy' \
  'machine github.com login macro-data password keep-macro-data' \
  '' \
  'machine github.com login stale-macro-boundary password stale-macro-token' \
  'machine example.test login keep-example password keep-example-parser-token' > "$parser_home/.config/nix/netrc"

parser_output="$test_root/parser-output"
SETUP_NIX_NETRC_HOME="$parser_home" SETUP_NIX_GITHUB_TOKEN="new-parser-token" \
  bash "$target" > "$parser_output" 2>&1
parser_rc=$?
check "rotates case/spacing/CRLF and macdef boundary fixtures" "$parser_rc"
! grep -Fq 'new-parser-token' "$parser_output"
check "parser-edge rotation does not print the token" $?
grep -Fq $'# keep-crlf-comment\r' "$parser_home/.netrc" &&
  grep -Fq $'  DEFAULT\r' "$parser_home/.netrc" &&
  grep -Fq $'\tlogin keep-default-crlf\r' "$parser_home/.netrc" &&
  grep -Fq $'\tpassword keep-default-crlf-token' "$parser_home/.netrc"
check "CRLF comments/default and the unterminated EOF field survive rotation" $?
! grep -Fq 'stale-crlf' "$parser_home/.netrc"
check "case-insensitive, tab-separated GitHub record is removed" $?
grep -Fq 'machine github.com login macro-data password keep-macro-data' "$parser_home/.config/nix/netrc" &&
  grep -Fq 'keep-example-parser-token' "$parser_home/.config/nix/netrc" &&
  ! grep -Fq 'stale-macro' "$parser_home/.config/nix/netrc"
check "macdef body is opaque while the following real GitHub record is removed" $?
parser_expected_user="$test_root/parser-expected-user-netrc"
printf '# keep-crlf-comment\r\n\r\n  DEFAULT\r\n\tlogin keep-default-crlf\r\n\tpassword keep-default-crlf-token\nmachine github.com\n  login x-access-token\n  password new-parser-token\n' > "$parser_expected_user"
cmp -s "$parser_expected_user" "$parser_home/.netrc"
check "CRLF and unterminated unrelated bytes are preserved around the required record separator" $?
parser_expected_nix="$test_root/parser-expected-nix-netrc"
printf '%s\n' \
  'macdef deploy' \
  'machine github.com login macro-data password keep-macro-data' \
  '' \
  'machine example.test login keep-example password keep-example-parser-token' \
  'machine github.com' \
  '  login x-access-token' \
  '  password new-parser-token' > "$parser_expected_nix"
cmp -s "$parser_expected_nix" "$parser_home/.config/nix/netrc"
check "opaque macdef and unrelated record bytes are preserved exactly" $?
assertion_rc=1
[[ "$(grep -xc 'machine github.com' "$parser_home/.netrc")" -eq 1 ]] &&
  [[ "$(grep -xc 'machine github.com' "$parser_home/.config/nix/netrc")" -eq 1 ]] &&
  assertion_rc=0
check "parser-edge files each receive exactly one canonical GitHub record" "$assertion_rc"
assertion_rc=1
[[ "$(file_mode "$parser_home/.netrc")" == "600" ]] &&
  [[ "$(file_mode "$parser_home/.config/nix/netrc")" == "600" ]] &&
  assertion_rc=0
check "parser-edge files are mode 600" "$assertion_rc"

# An unterminated macdef has no safe point at which to append a machine stanza:
# doing so would leave the credential inside the opaque macro body. The parser
# must fail without publishing or leaking the proposed token.
unterminated_home="$test_root/unterminated-macdef-home"
mkdir -p "$unterminated_home/.config/nix"
printf '%s\n' \
  'machine example.test login keep password keep-unterminated-user' \
  'macdef deploy' \
  'machine github.com login macro-data password keep-opaque-data' > "$unterminated_home/.netrc"
printf '%s\n' 'default login keep password keep-unterminated-nix' > "$unterminated_home/.config/nix/netrc"
cp "$unterminated_home/.netrc" "$test_root/unterminated-user-before"
cp "$unterminated_home/.config/nix/netrc" "$test_root/unterminated-nix-before"
unterminated_output="$test_root/unterminated-macdef-output"
SETUP_NIX_NETRC_HOME="$unterminated_home" \
  SETUP_NIX_GITHUB_TOKEN="new-unterminated-token" \
  bash "$target" > "$unterminated_output" 2>&1
unterminated_rc=$?
assertion_rc=1
[[ "$unterminated_rc" -ne 0 ]] && assertion_rc=0
check "an unterminated macdef fails closed" "$assertion_rc"
cmp -s "$test_root/unterminated-user-before" "$unterminated_home/.netrc" &&
  cmp -s "$test_root/unterminated-nix-before" "$unterminated_home/.config/nix/netrc"
check "unterminated macdef failure leaves both destinations unchanged" $?
assertion_rc=1
[[ -z "$(find "$unterminated_home" -name '.write-netrc.*' -print -quit)" ]] && assertion_rc=0
check "unterminated macdef failure cleans its temporary file" "$assertion_rc"
! grep -Fq 'new-unterminated-token' "$unterminated_output"
check "unterminated macdef failure does not print the token" $?

# ── §4 idempotence: the same token produces byte-identical contents ────────
cp "$rotation_home/.netrc" "$test_root/netrc-before-repeat"
cp "$rotation_home/.config/nix/netrc" "$test_root/nix-netrc-before-repeat"
SETUP_NIX_NETRC_HOME="$rotation_home" SETUP_NIX_GITHUB_TOKEN="new-rotation-token" \
  bash "$target" >/dev/null 2>&1
repeat_rc=$?
check "a repeated identical token succeeds" "$repeat_rc"
cmp -s "$test_root/netrc-before-repeat" "$rotation_home/.netrc" &&
  cmp -s "$test_root/nix-netrc-before-repeat" "$rotation_home/.config/nix/netrc"
check "a repeated identical token is byte-idempotent in both files" $?

# ── §5 atomic publication: destination changes only at same-dir rename ───────
atomic_home="$test_root/atomic-home"
write_rotation_fixtures "$atomic_home"
shim_dir="$test_root/atomic-shims"
mkdir -p "$shim_dir"
real_mv="$(command -v mv)"
atomic_marker="$test_root/atomic-moves"
# These single-quoted lines are the literal source of the generated shim.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '[[ "$#" -eq 4 && "$1" == "-f" && "$2" == "--" ]]' \
  'source_path="$3"' \
  'destination_path="$4"' \
  '[[ "${source_path%/*}" == "${destination_path%/*}" ]]' \
  '[[ "${source_path##*/}" == .write-netrc.* ]]' \
  '[[ "$(stat -c "%a" "$source_path" 2>/dev/null || stat -f "%Lp" "$source_path")" == "600" ]]' \
  'grep -Fq "$EXPECTED_NEW_TOKEN" "$source_path"' \
  '! grep -Fq "old-" "$source_path"' \
  'grep -Fq "old-" "$destination_path"' \
  '! grep -Fq "$EXPECTED_NEW_TOKEN" "$destination_path"' \
  'printf "%s\n" "$destination_path" >> "$ATOMIC_MARKER"' \
  'exec "$REAL_MV" "$@"' > "$shim_dir/mv"
chmod 0700 "$shim_dir/mv"

PATH="$shim_dir:$PATH" \
  REAL_MV="$real_mv" \
  ATOMIC_MARKER="$atomic_marker" \
  EXPECTED_NEW_TOKEN="new-atomic-token" \
  SETUP_NIX_NETRC_HOME="$atomic_home" \
  SETUP_NIX_GITHUB_TOKEN="new-atomic-token" \
  bash "$target" >/dev/null 2>&1
atomic_rc=$?
check "publishes complete replacements through the observed rename boundary" "$atomic_rc"
assertion_rc=1
[[ "$(wc -l < "$atomic_marker" 2>/dev/null)" -eq 2 ]] && assertion_rc=0
check "atomically renames both managed netrc files" "$assertion_rc"
assert_rotated_file "$atomic_home/.netrc" 'user netrc after atomic observation' 'new-atomic-token'
assert_rotated_file "$atomic_home/.config/nix/netrc" 'Nix netrc after atomic observation' 'new-atomic-token'

# ── §6 no token: preserve existing bytes, modes, and absent directories ────────
no_token_home="$test_root/no-token-home"
write_rotation_fixtures "$no_token_home"
chmod 0640 "$no_token_home/.netrc"
chmod 0644 "$no_token_home/.config/nix/netrc"
cp "$no_token_home/.netrc" "$test_root/no-token-netrc-before"
cp "$no_token_home/.config/nix/netrc" "$test_root/no-token-nix-netrc-before"

SETUP_NIX_NETRC_HOME="$no_token_home" SETUP_NIX_GITHUB_TOKEN="" \
  bash "$target" >/dev/null 2>&1
no_token_rc=$?
check "succeeds when no token is supplied" "$no_token_rc"
cmp -s "$test_root/no-token-netrc-before" "$no_token_home/.netrc" &&
  cmp -s "$test_root/no-token-nix-netrc-before" "$no_token_home/.config/nix/netrc" &&
  [[ "$(file_mode "$no_token_home/.netrc")" == "640" ]] &&
  [[ "$(file_mode "$no_token_home/.config/nix/netrc")" == "644" ]]
check "no-token mode preserves existing contents and permissions" $?

absent_home="$test_root/absent-no-token-home"
SETUP_NIX_NETRC_HOME="$absent_home" SETUP_NIX_GITHUB_TOKEN="" \
  bash "$target" >/dev/null 2>&1
absent_rc=$?
check "no-token mode also succeeds for an absent home" "$absent_rc"
assertion_rc=1
[[ ! -e "$absent_home" ]] && assertion_rc=0
check "no-token mode does not create an absent home or config directory" "$assertion_rc"

env -u HOME -u SETUP_NIX_NETRC_HOME SETUP_NIX_GITHUB_TOKEN="" \
  bash "$target" >/dev/null 2>&1
unset_home_rc=$?
check "no-token mode succeeds without consulting an unset HOME" "$unset_home_rc"

linebreak_home="$test_root/linebreak-token-home"
linebreak_output="$test_root/linebreak-token-output"
SETUP_NIX_NETRC_HOME="$linebreak_home" SETUP_NIX_GITHUB_TOKEN=$'invalid\ncredential' \
  bash "$target" > "$linebreak_output" 2>&1
linebreak_rc=$?
assertion_rc=1
[[ "$linebreak_rc" -ne 0 ]] && assertion_rc=0
check "a line-breaking token is rejected" "$assertion_rc"
! grep -Fq 'invalid' "$linebreak_output" && ! grep -Fq 'credential' "$linebreak_output"
check "line-breaking token rejection does not print token fragments" $?
assertion_rc=1
[[ ! -e "$linebreak_home" ]] && assertion_rc=0
check "line-breaking token rejection is non-destructive" "$assertion_rc"

carriage_home="$test_root/carriage-token-home"
carriage_output="$test_root/carriage-token-output"
SETUP_NIX_NETRC_HOME="$carriage_home" SETUP_NIX_GITHUB_TOKEN=$'invalid\rcredential' \
  bash "$target" > "$carriage_output" 2>&1
carriage_rc=$?
assertion_rc=1
[[ "$carriage_rc" -ne 0 ]] && assertion_rc=0
check "a carriage-return token is rejected" "$assertion_rc"
! grep -Fq 'invalid' "$carriage_output" && ! grep -Fq 'credential' "$carriage_output"
check "carriage-return rejection does not print token fragments" $?
assertion_rc=1
[[ ! -e "$carriage_home" ]] && assertion_rc=0
check "carriage-return rejection is non-destructive" "$assertion_rc"

# ── §7 fail closed: injected filesystem failures cannot report success ────────────
for failure_mode in mkdir write chmod mv; do
  failure_home="$test_root/failure-$failure_mode-home"
  write_rotation_fixtures "$failure_home"
  cp "$failure_home/.netrc" "$test_root/failure-$failure_mode-netrc-before"
  cp "$failure_home/.config/nix/netrc" "$test_root/failure-$failure_mode-nix-netrc-before"

  failure_shim_dir="$test_root/failure-$failure_mode-shims"
  mkdir -p "$failure_shim_dir"
  failure_bash_env=""
  if [[ "$failure_mode" == "write" ]]; then
    failure_bash_env="$failure_shim_dir/bash-env"
    printf '%s\n' 'printf() { return 97; }' > "$failure_bash_env"
  else
    printf '%s\n' '#!/usr/bin/env bash' 'exit 97' > "$failure_shim_dir/$failure_mode"
    chmod 0700 "$failure_shim_dir/$failure_mode"
  fi

  failure_output="$test_root/failure-$failure_mode-output"
  PATH="$failure_shim_dir:$PATH" \
    BASH_ENV="$failure_bash_env" \
    SETUP_NIX_NETRC_HOME="$failure_home" \
    SETUP_NIX_GITHUB_TOKEN="new-failure-token" \
    bash "$target" > "$failure_output" 2>&1
  failure_rc=$?
  assertion_rc=1
  [[ "$failure_rc" -ne 0 ]] && assertion_rc=0
  check "a forced $failure_mode failure returns nonzero" "$assertion_rc"
  ! grep -Fq 'new-failure-token' "$failure_output"
  check "a forced $failure_mode failure does not print the token" $?
  cmp -s "$test_root/failure-$failure_mode-netrc-before" "$failure_home/.netrc" &&
    cmp -s "$test_root/failure-$failure_mode-nix-netrc-before" "$failure_home/.config/nix/netrc"
  check "a forced $failure_mode failure leaves both destinations unchanged" $?
  assertion_rc=1
  [[ -z "$(find "$failure_home" -name '.write-netrc.*' -print -quit)" ]] && assertion_rc=0
  check "a forced $failure_mode failure leaves no temporary credential file" "$assertion_rc"
done

# A pending signal after the credential bytes reach the unpublished temporary
# file must run the EXIT cleanup and preserve the old destinations.
signal_home="$test_root/signal-home"
write_rotation_fixtures "$signal_home"
cp "$signal_home/.netrc" "$test_root/signal-netrc-before"
cp "$signal_home/.config/nix/netrc" "$test_root/signal-nix-netrc-before"
signal_shims="$test_root/signal-shims"
mkdir -p "$signal_shims"
# These single-quoted lines are the literal source of the generated Bash hook.
# shellcheck disable=SC2016
printf '%s\n' \
  'printf() {' \
  '  builtin printf "$@"' \
  '  if [[ "$1" == *password* ]]; then kill -TERM "$$"; fi' \
  '}' > "$signal_shims/bash-env"
signal_output="$test_root/signal-output"
BASH_ENV="$signal_shims/bash-env" \
  SETUP_NIX_NETRC_HOME="$signal_home" \
  SETUP_NIX_GITHUB_TOKEN="new-signal-token" \
  bash "$target" > "$signal_output" 2>&1
signal_rc=$?
assertion_rc=1
[[ "$signal_rc" -eq 143 ]] && assertion_rc=0
check "TERM is propagated as exit 143" "$assertion_rc"
cmp -s "$test_root/signal-netrc-before" "$signal_home/.netrc" &&
  cmp -s "$test_root/signal-nix-netrc-before" "$signal_home/.config/nix/netrc"
check "TERM after staging the token leaves both destinations unchanged" $?
assertion_rc=1
[[ -z "$(find "$signal_home" -name '.write-netrc.*' -print -quit)" ]] && assertion_rc=0
check "TERM cleans the unpublished credential file" "$assertion_rc"
! grep -Fq 'new-signal-token' "$signal_output"
check "signal handling does not print the token" $?

# If both publication and cleanup are forced to fail, the original files must
# remain intact and the protected temporary credential must remain mode 0600.
cleanup_failure_home="$test_root/cleanup-failure-home"
write_rotation_fixtures "$cleanup_failure_home"
cp "$cleanup_failure_home/.netrc" "$test_root/cleanup-failure-netrc-before"
cp "$cleanup_failure_home/.config/nix/netrc" "$test_root/cleanup-failure-nix-netrc-before"
cleanup_failure_shims="$test_root/cleanup-failure-shims"
mkdir -p "$cleanup_failure_shims"
for command_name in mv rm; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 97' > "$cleanup_failure_shims/$command_name"
  chmod 0700 "$cleanup_failure_shims/$command_name"
done
cleanup_failure_output="$test_root/cleanup-failure-output"
PATH="$cleanup_failure_shims:$PATH" \
  SETUP_NIX_NETRC_HOME="$cleanup_failure_home" \
  SETUP_NIX_GITHUB_TOKEN="new-cleanup-failure-token" \
  bash "$target" > "$cleanup_failure_output" 2>&1
cleanup_failure_rc=$?
assertion_rc=1
[[ "$cleanup_failure_rc" -ne 0 ]] && assertion_rc=0
check "cleanup failure remains fail-visible" "$assertion_rc"
cmp -s "$test_root/cleanup-failure-netrc-before" "$cleanup_failure_home/.netrc" &&
  cmp -s "$test_root/cleanup-failure-nix-netrc-before" "$cleanup_failure_home/.config/nix/netrc"
check "cleanup failure leaves both destinations unchanged" $?
cleanup_failure_temp="$(find "$cleanup_failure_home" -name '.write-netrc.*' -print -quit)"
assertion_rc=1
[[ -n "$cleanup_failure_temp" ]] &&
  [[ "$(file_mode "$cleanup_failure_temp")" == "600" ]] &&
  grep -Fq 'new-cleanup-failure-token' "$cleanup_failure_temp" &&
  assertion_rc=0
check "an unremovable temporary credential remains protected at mode 600" "$assertion_rc"
! grep -Fq 'new-cleanup-failure-token' "$cleanup_failure_output"
check "cleanup failure does not print the token" $?

# Symlinked credentials on persistent runners are configuration, not scratch
# paths. Put the symlink at the second managed path to prove both targets are
# validated before the first one can be changed.
symlink_home="$test_root/symlink-home"
symlink_targets="$test_root/symlink-targets"
mkdir -p "$symlink_home/.config/nix" "$symlink_targets"
printf '%s\n' 'machine example.test login keep password keep-user-before-nix-link' > "$symlink_home/.netrc"
printf '%s\n' 'default login keep password keep-nix-link-target' > "$symlink_targets/nix-netrc"
ln -s "$symlink_targets/nix-netrc" "$symlink_home/.config/nix/netrc"
cp "$symlink_home/.netrc" "$test_root/symlink-user-before"
cp "$symlink_targets/nix-netrc" "$test_root/symlink-nix-target-before"
symlink_output="$test_root/symlink-output"
SETUP_NIX_NETRC_HOME="$symlink_home" SETUP_NIX_GITHUB_TOKEN="new-symlink-token" \
  bash "$target" > "$symlink_output" 2>&1
symlink_rc=$?
assertion_rc=1
[[ "$symlink_rc" -ne 0 ]] && assertion_rc=0
check "a symlinked managed netrc fails closed" "$assertion_rc"
assertion_rc=1
[[ -f "$symlink_home/.netrc" ]] && [[ ! -L "$symlink_home/.netrc" ]] &&
  [[ -L "$symlink_home/.config/nix/netrc" ]] &&
  [[ "$(readlink "$symlink_home/.config/nix/netrc")" == "$symlink_targets/nix-netrc" ]] &&
  assertion_rc=0
check "second-target symlink failure preserves both path identities" "$assertion_rc"
cmp -s "$test_root/symlink-user-before" "$symlink_home/.netrc" &&
  cmp -s "$test_root/symlink-nix-target-before" "$symlink_targets/nix-netrc"
check "second-target symlink failure leaves the first file and link target unchanged" $?
assertion_rc=1
[[ -z "$(find "$symlink_home" -name '.write-netrc.*' -print -quit)" ]] && assertion_rc=0
check "symlink failure creates no temporary credential" "$assertion_rc"
! grep -Fq 'new-symlink-token' "$symlink_output"
check "symlink failure does not print the token" $?

# Directories, devices, sockets, and FIFOs are not files this action may
# replace. A directory exercises the common non-regular branch portably.
nonregular_home="$test_root/nonregular-home"
mkdir -p "$nonregular_home/.netrc" "$nonregular_home/.config/nix"
printf '%s\n' 'default login keep password keep-nonregular-nix' > "$nonregular_home/.config/nix/netrc"
cp "$nonregular_home/.config/nix/netrc" "$test_root/nonregular-nix-before"
nonregular_output="$test_root/nonregular-output"
SETUP_NIX_NETRC_HOME="$nonregular_home" SETUP_NIX_GITHUB_TOKEN="new-nonregular-token" \
  bash "$target" > "$nonregular_output" 2>&1
nonregular_rc=$?
assertion_rc=1
[[ "$nonregular_rc" -ne 0 ]] && assertion_rc=0
check "a non-regular managed netrc fails closed" "$assertion_rc"
[[ -d "$nonregular_home/.netrc" ]] &&
  cmp -s "$test_root/nonregular-nix-before" "$nonregular_home/.config/nix/netrc"
check "non-regular failure preserves both managed targets" $?
assertion_rc=1
[[ -z "$(find "$nonregular_home" -name '.write-netrc.*' -print -quit)" ]] && assertion_rc=0
check "non-regular failure creates no temporary credential" "$assertion_rc"
! grep -Fq 'new-nonregular-token' "$nonregular_output"
check "non-regular failure does not print the token" $?

# A failure on the second rename cannot be a transaction across two separate
# pathnames. It must still be fail-visible and preserve per-file atomicity; a
# retry must converge the already-rotated first file and untouched second file.
second_rename_home="$test_root/second-rename-home"
write_rotation_fixtures "$second_rename_home"
second_rename_shims="$test_root/second-rename-shims"
mkdir -p "$second_rename_shims"
second_rename_count="$test_root/second-rename-count"
printf '0\n' > "$second_rename_count"
# These single-quoted lines are the literal source of the generated shim.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'count="$(cat "$SECOND_RENAME_COUNT")"' \
  'count=$((count + 1))' \
  'printf "%s\n" "$count" > "$SECOND_RENAME_COUNT"' \
  'if [[ "$count" -eq 2 ]]; then exit 97; fi' \
  'exec "$REAL_MV" "$@"' > "$second_rename_shims/mv"
chmod 0700 "$second_rename_shims/mv"

PATH="$second_rename_shims:$PATH" \
  REAL_MV="$real_mv" \
  SECOND_RENAME_COUNT="$second_rename_count" \
  SETUP_NIX_NETRC_HOME="$second_rename_home" \
  SETUP_NIX_GITHUB_TOKEN="new-second-rename-token" \
  bash "$target" >/dev/null 2>&1
second_rename_rc=$?
assertion_rc=1
[[ "$second_rename_rc" -ne 0 ]] && assertion_rc=0
check "a failure on the second rename returns nonzero" "$assertion_rc"
assert_rotated_file "$second_rename_home/.netrc" 'first file after second-rename failure' 'new-second-rename-token'
grep -Fq 'old-' "$second_rename_home/.config/nix/netrc" &&
  ! grep -Fq 'new-second-rename-token' "$second_rename_home/.config/nix/netrc"
check "second-rename failure leaves the second file wholly unmodified" $?
assertion_rc=1
[[ -z "$(find "$second_rename_home" -name '.write-netrc.*' -print -quit)" ]] && assertion_rc=0
check "second-rename failure cleans its unpublished temporary file" "$assertion_rc"

SETUP_NIX_NETRC_HOME="$second_rename_home" \
  SETUP_NIX_GITHUB_TOKEN="new-second-rename-token" \
  bash "$target" >/dev/null 2>&1
second_rename_retry_rc=$?
check "retry after a second-rename failure succeeds" "$second_rename_retry_rc"
assert_rotated_file "$second_rename_home/.netrc" 'first file after retry' 'new-second-rename-token'
assert_rotated_file "$second_rename_home/.config/nix/netrc" 'second file after retry' 'new-second-rename-token'

# Concurrent retries with the same token must use collision-free temporary
# names and converge without leaving a partial file or cleanup residue.
concurrent_home="$test_root/concurrent-home"
write_rotation_fixtures "$concurrent_home"
concurrent_failed=0
concurrent_pids=()
for invocation in 1 2 3 4 5 6 7 8; do
  SETUP_NIX_NETRC_HOME="$concurrent_home" \
    SETUP_NIX_GITHUB_TOKEN="new-concurrent-token" \
    bash "$target" > "$test_root/concurrent-$invocation-output" 2>&1 &
  concurrent_pids+=("$!")
done
for concurrent_pid in "${concurrent_pids[@]}"; do
  if ! wait "$concurrent_pid"; then
    concurrent_failed=1
  fi
done
check "concurrent same-token rotations all succeed" "$concurrent_failed"
assert_rotated_file "$concurrent_home/.netrc" 'user netrc after concurrent rotations' 'new-concurrent-token'
assert_rotated_file "$concurrent_home/.config/nix/netrc" 'Nix netrc after concurrent rotations' 'new-concurrent-token'
[[ -z "$(find "$concurrent_home" -name '.write-netrc.*' -print -quit)" ]]
check "concurrent rotations leave no temporary credential file" $?
assertion_rc=0
for invocation in 1 2 3 4 5 6 7 8; do
  if grep -Fq 'new-concurrent-token' "$test_root/concurrent-$invocation-output"; then
    assertion_rc=1
  fi
done
check "concurrent rotations do not print the token" "$assertion_rc"

# ── §8 reusable-workflow secret contract and precedence ────────────────────────
for workflow_and_count in \
  'reusable-lint.yml:1' \
  'reusable-flake-checks-ci-matrix.yml:5'; do
  workflow_name="${workflow_and_count%%:*}"
  expected_precedence_count="${workflow_and_count##*:}"
  workflow="$repo_root/.github/workflows/$workflow_name"

  declaration_count="$(grep -Ec '^      GH_READ_METACRAFT_PRIVATE_REPOS:$' "$workflow")"
  assertion_rc=1
  [[ "$declaration_count" -eq 1 ]] && assertion_rc=0
  check "$workflow_name declares the legacy fallback workflow-call secret once" "$assertion_rc"

  awk '
    /^      GH_READ_METACRAFT_PRIVATE_REPOS:$/ {
      getline
      description = $0
      getline
      requirement = $0
      if (description ~ /only when NIX_GITHUB_TOKEN is unset \(optional\)/ &&
          requirement ~ /^[[:space:]]+required: false$/) valid = 1
    }
    END { exit(valid ? 0 : 1) }
  ' "$workflow"
  check "$workflow_name documents the fallback as lower-precedence and optional" $?

  # The literal GitHub expression must reach the workflow unchanged. The one
  # permitted extension is a LAST-resort App-minted token (reusable-lint's
  # `app-token` step, which runs only when neither secret is set), so the
  # static secrets keep their order and precedence.
  # shellcheck disable=SC2016
  precedence_count="$(grep -Ec 'nix-github-token: \$\{\{ secrets\.NIX_GITHUB_TOKEN \|\| secrets\.GH_READ_METACRAFT_PRIVATE_REPOS( \|\| steps\.app-token\.outputs\.token)? \}\}$' "$workflow")"
  token_input_count="$(grep -Ec '^[[:space:]]+nix-github-token:' "$workflow")"
  [[ "$precedence_count" -eq "$expected_precedence_count" ]] &&
    [[ "$token_input_count" -eq "$expected_precedence_count" ]]
  check "$workflow_name keeps NIX_GITHUB_TOKEN first at every token input" $?
done

# ── §9 negative controls: the suite rejects specific production regressions ─
if [[ "${SETUP_NIX_SKIP_WRITE_NETRC_MUTATIONS:-0}" != "1" ]]; then
  run_rejected_mutation() { # run_rejected_mutation <name> <expected-failure> <sed-expression>
    mutation_name="$1"
    expected_failure="$2"
    sed_expression="$3"
    mutated_target="$test_root/write-netrc-$mutation_name.sh"
    mutation_output="$test_root/write-netrc-$mutation_name-output"

    sed "$sed_expression" "$target" > "$mutated_target"
    mutation_rc=0
    if cmp -s "$target" "$mutated_target"; then
      mutation_rc=1
    else
      SETUP_NIX_SKIP_WRITE_NETRC_MUTATIONS=1 \
        SETUP_NIX_WRITE_NETRC_TARGET="$mutated_target" \
        bash "$0" > "$mutation_output" 2>&1
      mutated_suite_rc=$?
      if [[ "$mutated_suite_rc" -eq 0 ]] || ! grep -Fq "FAIL: $expected_failure" "$mutation_output"; then
        mutation_rc=1
      fi
    fi
    check "CONTROL: rejects $mutation_name" "$mutation_rc"
  }

  # The sed programs intentionally refer to literal target-script variables.
  # shellcheck disable=SC2016
  run_rejected_mutation \
    'direct non-atomic publication' \
    'atomically renames both managed netrc files' \
    's/^  mv -f -- "$temporary_file" "$netrc"$/  cp "$temporary_file" "$netrc"/'
  # shellcheck disable=SC2016
  run_rejected_mutation \
    'stale GitHub credential retention' \
    'user netrc contains no old GitHub credential' \
    's/dropping=1/dropping=0/'
  # This inserts a behavior-neutral probe before the real Bash parser. The
  # normal PATH can satisfy it; the deliberately sparse production analogue
  # must reject the reintroduced dependency by actually executing the mutant.
  # shellcheck disable=SC2016
  run_rejected_mutation \
    'reintroduced pre-Nix awk dependency' \
    'runs successfully on a deliberately awk-free pre-Nix PATH' \
    's@^    filter_existing_netrc .*$@    awk "BEGIN { exit 0 }"; &@'
  run_rejected_mutation \
    'unterminated macdef acceptance' \
    'an unterminated macdef fails closed' \
    's/return 65/return 0/'
  # Limit the edit to the validation condition so CRLF parsing remains intact
  # and the intended carriage-return-token assertion must kill the mutant.
  # shellcheck disable=SC2016
  run_rejected_mutation \
    'carriage-return token acceptance' \
    'a carriage-return token is rejected' \
    '/^if \[\[ "$token"/s/\\r/\\x/'
  # shellcheck disable=SC2016
  run_rejected_mutation \
    'omission of the git-visible user netrc' \
    'user netrc contains exactly one github.com stanza' \
    '/^  write_netrc "$user_netrc" 0$/d'
  run_rejected_mutation \
    'disabled failure propagation' \
    'a forced mkdir failure returns nonzero' \
    's/^set -euo pipefail$/set -uo pipefail/'
fi

echo
if [[ "$failures" -eq 0 ]]; then
  echo "write-netrc-test: PASS"
  exit 0
fi
echo "write-netrc-test: FAIL ($failures check(s))"
exit 1
