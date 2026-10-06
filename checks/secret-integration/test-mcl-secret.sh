#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------
# Setup
# ---------------------------------------------------------------
MCL_SECRET_TMP_DIR="$(mktemp -d)"

# configPath is "./checks/test-machine" — mcl writes secrets there.
# Clean up both the temp dir and any repo-local artifacts on exit.
cleanup() {
  rm -rf "$MCL_SECRET_TMP_DIR"
  rm -rf ./checks/test-machine/secrets
  rmdir ./checks/test-machine 2>/dev/null || true
}
trap cleanup EXIT

# Point HOME at the temp dir and symlink .ssh to the test keys so that
# mcl's auto-discovery finds the identity at $HOME/.ssh/id_ed25519.
export HOME="$MCL_SECRET_TMP_DIR"
ln -s "@TEST_KEYS_DIR@/.ssh" "$HOME/.ssh"

# configPath resolves to ./checks/test-machine (relative to repo root).
# mcl derives secrets paths from it, so secrets are written there.
SECRETS_DIR="./checks/test-machine/secrets"

# Create a helper script to use as EDITOR — it copies the
# cleartext-input file to the target file that age will encrypt.
export EDITOR="$MCL_SECRET_TMP_DIR/fake-editor"
cat > "$EDITOR" <<'EDSCRIPT'
#!/usr/bin/env bash
cp "$CLEARTEXT_INPUT" "$1"
EDSCRIPT
chmod +x "$EDITOR"

pass=0
fail=0
tests=0
assert_eq() {
  local actual="$1" expected="$2" label="$3"
  tests=$((tests + 1))
  if [ "$actual" = "$expected" ]; then
    pass=$((pass + 1))
    echo "  PASS: $label"
  else
    fail=$((fail + 1))
    echo "  FAIL: $label (expected '$expected', got '$actual')"
  fi
}
assert_file_exists() {
  local path="$1" label="$2"
  tests=$((tests + 1))
  if [ -f "$path" ]; then
    pass=$((pass + 1))
    echo "  PASS: $label"
  else
    fail=$((fail + 1))
    echo "  FAIL: $label (file does not exist: $path)"
  fi
}

# ---------------------------------------------------------------
# Test 1: `mcl-devops secret edit` — create a new secret
# ---------------------------------------------------------------
echo "=== Test 1: mcl-devops secret edit (create new secret) ==="

export CLEARTEXT_INPUT="$MCL_SECRET_TMP_DIR/cleartext-input"
echo -n "super-secret-password" > "$CLEARTEXT_INPUT"
mcl-devops secret \
  --machine test-secret-machine \
  edit \
  --service test-svc \
  --secret password

assert_file_exists "$SECRETS_DIR/test-svc/password.age" "password.age created"

decrypted=$(age --decrypt \
  -i "$HOME/.ssh/id_ed25519" \
  "$SECRETS_DIR/test-svc/password.age")
assert_eq "$decrypted" "super-secret-password" "decrypted content matches original"

# ---------------------------------------------------------------
# Test 2: `mcl-devops secret edit` — edit an existing secret
# ---------------------------------------------------------------
echo "=== Test 2: mcl-devops secret edit (edit existing secret) ==="

echo -n "updated-password" > "$CLEARTEXT_INPUT"
mcl-devops secret \
  --machine test-secret-machine \
  edit \
  --service test-svc \
  --secret password

decrypted=$(age --decrypt \
  -i "$HOME/.ssh/id_ed25519" \
  "$SECRETS_DIR/test-svc/password.age")
assert_eq "$decrypted" "updated-password" "edited content matches"

# ---------------------------------------------------------------
# Test 3: Create a second secret, then `mcl-devops secret re-encrypt`
# ---------------------------------------------------------------
echo "=== Test 3: mcl-devops secret re-encrypt ==="

echo -n "my-api-key-123" > "$CLEARTEXT_INPUT"
mcl-devops secret \
  --machine test-secret-machine \
  edit \
  --service test-svc \
  --secret api-key

mcl-devops secret \
  --machine test-secret-machine \
  re-encrypt \
  --service test-svc

d1=$(age --decrypt -i "$HOME/.ssh/id_ed25519" "$SECRETS_DIR/test-svc/password.age")
d2=$(age --decrypt -i "$HOME/.ssh/id_ed25519" "$SECRETS_DIR/test-svc/api-key.age")
assert_eq "$d1" "updated-password" "password preserved after re-encrypt"
assert_eq "$d2" "my-api-key-123" "api-key preserved after re-encrypt"

# ---------------------------------------------------------------
# Test 4: `mcl-devops secret re-encrypt-all`
# ---------------------------------------------------------------
echo "=== Test 4: mcl-devops secret re-encrypt-all ==="

echo -n "other-token-value" > "$CLEARTEXT_INPUT"
mcl-devops secret \
  --machine test-secret-machine \
  edit \
  --service other-svc \
  --secret token

mcl-devops secret \
  --machine test-secret-machine \
  re-encrypt-all

d1=$(age --decrypt -i "$HOME/.ssh/id_ed25519" "$SECRETS_DIR/test-svc/password.age")
d2=$(age --decrypt -i "$HOME/.ssh/id_ed25519" "$SECRETS_DIR/test-svc/api-key.age")
d3=$(age --decrypt -i "$HOME/.ssh/id_ed25519" "$SECRETS_DIR/other-svc/token.age")
assert_eq "$d1" "updated-password" "password preserved after re-encrypt-all"
assert_eq "$d2" "my-api-key-123" "api-key preserved after re-encrypt-all"
assert_eq "$d3" "other-token-value" "token preserved after re-encrypt-all"

# ---------------------------------------------------------------
# Test 5: `mcl-devops secret list` (single machine, tree output)
# ---------------------------------------------------------------
echo "=== Test 5: mcl-devops secret list (single machine, tree) ==="
list_output=$(mcl-devops secret --machine test-secret-machine list)
assert_eq "$(echo "$list_output" | grep -c 'test-svc\|other-svc')" "2" "list shows both services"
assert_eq "$(echo "$list_output" | grep -c '  - password\|  - api-key\|  - token')" "3" "list shows all 3 secrets"

# ---------------------------------------------------------------
# Test 6: `mcl-devops secret list` (single machine, JSON output)
# ---------------------------------------------------------------
echo "=== Test 6: mcl-devops secret list (single machine, JSON) ==="
list_json=$(mcl-devops secret --machine test-secret-machine list --json)
assert_eq "$(echo "$list_json" | jq -r '.services | keys | sort | join(",")')" \
  "other-svc,test-svc" "JSON has expected service keys"
assert_eq "$(echo "$list_json" | jq -r '.services."test-svc" | sort | join(",")')" \
  "api-key,password" "JSON test-svc has expected secrets"

# ---------------------------------------------------------------
# Test 7: `mcl-devops secret list` (all machines, tree output)
# ---------------------------------------------------------------
echo "=== Test 7: mcl-devops secret list (all machines) ==="
all_output=$(mcl-devops secret list)
assert_eq "$(echo "$all_output" | grep -c 'test-secret-machine')" "1" "list all shows machine name"
assert_eq "$(echo "$all_output" | grep -c '  test-svc:\|  other-svc:')" "2" "list all shows services indented"

# ---------------------------------------------------------------
# Test 8: `mcl-devops secret list` is resilient to a machine that fails to
#         evaluate. `broken-machine` throws while forcing its secrets;
#         the whole-fleet eval must not abort — it should surface an
#         ERROR marker for that machine and still list the healthy ones.
# ---------------------------------------------------------------
echo "=== Test 8: mcl-devops secret list (resilient to broken machine) ==="
broken_stderr="$MCL_SECRET_TMP_DIR/broken-stderr"
broken_output=$(mcl-devops secret list 2>"$broken_stderr")
assert_eq "$(echo "$broken_output" | grep -c '^broken-machine:')" "1" \
  "broken machine appears in list"
assert_eq "$(echo "$broken_output" | grep -c 'ERROR (see stderr for details)')" "1" \
  "broken machine shows ERROR marker"
assert_eq "$(echo "$broken_output" | grep -c '^test-secret-machine:')" "1" \
  "healthy machine still listed despite broken peer"
assert_eq "$(grep -c 'broken-machine' "$broken_stderr")" "1" \
  "broken machine error logged to stderr"

# JSON output must carry the per-machine error too.
broken_json=$(mcl-devops secret list --json 2>/dev/null)
assert_eq "$(echo "$broken_json" | jq -r '."broken-machine".error')" \
  "evaluation failed" "JSON list marks broken machine with an error"

# ---------------------------------------------------------------
# Test 9: `mcl-devops secret list` hides VMs (machines ending in `-vm`) by
#         default and reveals them with `--include-vms`.
# ---------------------------------------------------------------
echo "=== Test 9: mcl-devops secret list (VM filtering) ==="
default_list=$(mcl-devops secret list 2>/dev/null)
assert_eq "$(echo "$default_list" | grep -c '^test-secret-machine-vm:')" "0" \
  "VM hidden by default"
include_list=$(mcl-devops secret list --include-vms 2>/dev/null)
assert_eq "$(echo "$include_list" | grep -c '^test-secret-machine-vm:')" "1" \
  "VM shown with --include-vms"

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo ""
echo "Results: $pass/$tests passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
