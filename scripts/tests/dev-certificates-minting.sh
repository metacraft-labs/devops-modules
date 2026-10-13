#!/usr/bin/env bash
# Integration test for `scripts/mint-dev-certificates.sh`.
#
# NO MOCKS. It runs the real tool with real openssl, mints a real root and real
# leaves, and then completes a real TLS handshake against `openssl s_server`
# using one of the minted leaves, verified against the minted root. That last
# step is the one worth having: environment-domains-and-dev-certificates.md §7
# says certificates being installed is not evidence that TLS works, and a mint
# that produces well-formed files a client then rejects is exactly the failure
# a file-shape assertion misses.
#
# It also exercises every refusal the tool owes, because a guard with no
# negative control is a guard nobody has seen fire. The TLD guard in particular
# shipped broken on its first write (it rejected every legitimate name) and a
# positive-only test would have called that a pass.
#
# Run it by hand with:  bash scripts/tests/dev-certificates-minting.sh
# It needs only bash, openssl and jq on PATH.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINT="$HERE/../mint-dev-certificates.sh"
[ -r "$MINT" ] || {
  echo "cannot find $MINT" >&2
  exit 1
}

WORK="$(mktemp -d)"

# The TLS server this test starts must not outlive it. `stop_srv` is called on
# the happy path, but a failed assertion between `serve` and it would leave an
# `openssl s_server` holding a port — on a shared self-hosted runner, for as long
# as the machine stays up. So the EXIT trap kills it too, and does so before
# removing the work directory the server is reading its certificate from.
SRV_PID=
cleanup() {
  [ -z "$SRV_PID" ] || kill "$SRV_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass=0
fail=0

ok() {
  pass=$((pass + 1))
  printf 'ok   %s\n' "$1"
}
no() {
  fail=$((fail + 1))
  printf 'FAIL %s\n' "$1"
  [ $# -lt 2 ] || printf '       %s\n' "$2"
}

# assert_fails <label> <expected substring> <command...>
assert_fails() {
  local label="$1" want="$2"
  shift 2
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    no "$label" "expected a non-zero exit, got 0"
    return
  fi
  case "$out" in
  *"$want"*) ok "$label" ;;
  *) no "$label" "exit $rc but the message did not mention '$want': $out" ;;
  esac
}

mint() { bash "$MINT" "$@"; }

# ---------------------------------------------------------------------------
# A spec with the two shapes that matter: a wildcard+apex pair and a
# wildcard-only row two labels deep. Small key, because this is about the
# tool's logic, not RSA.
# ---------------------------------------------------------------------------
cat >"$WORK/spec.json" <<'JSON'
{
  "rootCommonName": "Test Development Root CA",
  "rootValidityDays": 3650,
  "rootKeyBits": 2048,
  "leafValidityDays": 90,
  "leafExpiryFailBelowDays": 14,
  "domains": [
    { "production": "example.com", "id": "example.localhost", "scheme": "localhost",
      "names": [ "example.localhost", "*.example.localhost" ] },
    { "production": "example.com", "id": "sessions.example.localhost", "scheme": "localhost",
      "names": [ "*.sessions.example.localhost" ] },
    { "production": "other.com", "id": "other.test", "scheme": "test",
      "names": [ "other.test", "*.other.test" ] }
  ]
}
JSON

# ---------------------------------------------------------------------------
# 1. init-root
# ---------------------------------------------------------------------------
if mint init-root --spec "$WORK/spec.json" \
  --key-out "$WORK/root/ca.key" --cert-out "$WORK/certs/root-ca.crt" >"$WORK/init.log" 2>&1; then
  ok "init-root succeeds"
else
  no "init-root succeeds" "$(cat "$WORK/init.log")"
fi

[ -s "$WORK/root/ca.key" ] && ok "init-root wrote a root key" || no "init-root wrote a root key"

# The key must never be group- or world-readable, not even for an instant; the
# tool sets umask before genrsa rather than chmod after.
mode="$(stat -c '%a' "$WORK/root/ca.key" 2>/dev/null || stat -f '%Lp' "$WORK/root/ca.key")"
[ "$mode" = "600" ] && ok "root key is mode 600" || no "root key is mode 600" "got $mode"

# pathlen:0 -- this root signs leaves and must not be able to mint an
# intermediate that could then sign anything at all.
ext="$(openssl x509 -in "$WORK/certs/root-ca.crt" -noout -text)"
case "$ext" in
*"CA:TRUE, pathlen:0"*) ok "root is a CA with pathlen:0" ;;
*) no "root is a CA with pathlen:0" "basicConstraints not as expected" ;;
esac

assert_fails "init-root refuses to overwrite an existing root" \
  "already exists" \
  mint init-root --spec "$WORK/spec.json" \
  --key-out "$WORK/root/ca.key" --cert-out "$WORK/certs/root-ca.crt"

# ---------------------------------------------------------------------------
# 2. mint
# ---------------------------------------------------------------------------
if mint mint --spec "$WORK/spec.json" \
  --root-key "$WORK/root/ca.key" --root-cert "$WORK/certs/root-ca.crt" \
  --key-out-dir "$WORK/keys" --cert-out-dir "$WORK/certs" >"$WORK/mint.log" 2>&1; then
  ok "mint succeeds"
else
  no "mint succeeds" "$(cat "$WORK/mint.log")"
fi

for id in example.localhost sessions.example.localhost other.test; do
  [ -s "$WORK/certs/$id/fullchain.pem" ] &&
    ok "leaf certificate exists for $id" ||
    no "leaf certificate exists for $id"
  [ -s "$WORK/keys/$id.key.pem" ] &&
    ok "leaf key exists for $id" ||
    no "leaf key exists for $id"
done

kmode="$(stat -c '%a' "$WORK/keys/example.localhost.key.pem" 2>/dev/null ||
  stat -f '%Lp' "$WORK/keys/example.localhost.key.pem")"
[ "$kmode" = "600" ] && ok "leaf key is mode 600" || no "leaf key is mode 600" "got $kmode"

# fullchain = leaf FIRST, then root. A server handed them the other way round
# presents the root as its own certificate and every client rejects it.
nleaf="$(grep -c 'BEGIN CERTIFICATE' "$WORK/certs/example.localhost/fullchain.pem")"
[ "$nleaf" = "2" ] && ok "fullchain carries two certificates" ||
  no "fullchain carries two certificates" "got $nleaf"
firstcn="$(openssl x509 -in "$WORK/certs/example.localhost/fullchain.pem" -noout -subject)"
case "$firstcn" in
*example.localhost*) ok "fullchain leads with the leaf, not the root" ;;
*) no "fullchain leads with the leaf, not the root" "first subject was $firstcn" ;;
esac

# The apex+wildcard row must carry BOTH names: a wildcard matches exactly one
# label, so a leaf with only `*.example.localhost` fails on the apex.
san="$(openssl x509 -in "$WORK/certs/example.localhost/fullchain.pem" -noout -ext subjectAltName)"
case "$san" in
*"DNS:example.localhost"*) ok "apex name is in the SAN" ;;
*) no "apex name is in the SAN" "$san" ;;
esac
case "$san" in
*"DNS:*.example.localhost"*) ok "wildcard name is in the SAN" ;;
*) no "wildcard name is in the SAN" "$san" ;;
esac

case "$(openssl x509 -in "$WORK/certs/other.test/fullchain.pem" -noout -ext extendedKeyUsage)" in
*"TLS Web Server Authentication"*) ok "leaf is marked serverAuth" ;;
*) no "leaf is marked serverAuth" ;;
esac

openssl verify -CAfile "$WORK/certs/root-ca.crt" \
  <(openssl x509 -in "$WORK/certs/example.localhost/fullchain.pem") >/dev/null 2>&1 &&
  ok "leaf verifies against the minted root" ||
  no "leaf verifies against the minted root"

# ---------------------------------------------------------------------------
# 3. A REAL handshake. This is the §7 proof: a running process accepted the
#    credential over the local name, rather than the files merely parsing.
# ---------------------------------------------------------------------------
# NOT `-naccept 1`: the readiness probe below opens a connection of its own, so
# a one-shot server has already served and exited by the time the client dials
# and the test fails with "Connection refused". That is how this first failed --
# and the negative control two assertions down then PASSED for the same wrong
# reason, which is why it now asserts on the verification message rather than
# merely on a non-zero exit.
free_port() {
  local cand
  for _ in $(seq 1 40); do
    cand=$((20000 + RANDOM % 20000))
    if ! (exec 3<>/dev/tcp/127.0.0.1/$cand) 2>/dev/null; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

await_port() {
  local p="$1"
  for _ in $(seq 1 150); do
    if (exec 3<>/dev/tcp/127.0.0.1/"$p") 2>/dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}

# serve <label>  -> starts a server on a free port, echoes the port
serve() {
  local port
  port="$(free_port)" || return 1
  openssl s_server -accept "$port" \
    -cert "$WORK/certs/example.localhost/fullchain.pem" \
    -key "$WORK/keys/example.localhost.key.pem" \
    -www >"$WORK/server-$port.log" 2>&1 &
  SRV_PID=$!
  await_port "$port" || return 1
  printf '%s\n' "$port"
}

stop_srv() {
  [ -n "$SRV_PID" ] || return 0
  kill "$SRV_PID" 2>/dev/null || true
  wait "$SRV_PID" 2>/dev/null || true
  SRV_PID=
}

# handshake <port> <servername>  -> exit status of a hostname-verifying client
handshake() {
  printf 'GET / HTTP/1.0\r\n\r\n' |
    openssl s_client -connect "127.0.0.1:$1" \
      -servername "$2" \
      -verify_hostname "$2" \
      -CAfile "$WORK/certs/root-ca.crt" \
      -verify_return_error -brief 2>&1
}

if port="$(serve)"; then
  ok "TLS server came up on the minted leaf"

  # A name one label under the apex: covered by `*.example.localhost`.
  out="$(handshake "$port" ide.example.localhost)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    # "Verification: OK" is what proves the chain was CHECKED and accepted,
    # not that checking was skipped.
    case "$out" in
    *"Verification: OK"*) ok "a real client completed a VERIFIED handshake for ide.example.localhost (wildcard)" ;;
    *) no "a real client completed a VERIFIED handshake for ide.example.localhost (wildcard)" \
      "exit 0 but no 'Verification: OK' in the transcript: $out" ;;
    esac
  else
    no "a real client completed a VERIFIED handshake for ide.example.localhost (wildcard)" \
      "exit $rc: $out"
  fi

  # The apex itself -- the reason each row carries two names.
  out="$(handshake "$port" example.localhost)"
  if [ $? -eq 0 ]; then
    ok "a real client completed a verified handshake for the APEX example.localhost"
  else
    no "a real client completed a verified handshake for the APEX example.localhost" "$out"
  fi

  # Negative control, on the SAME running server so "refused" cannot stand in
  # for "rejected": two labels deep is NOT covered by a single-label wildcard.
  out="$(handshake "$port" a.b.example.localhost)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    no "the client REJECTS a name the leaf does not carry" \
      "a.b.example.localhost was accepted -- hostname verification is not actually on"
  else
    case "$out" in
    *"Connection refused"*)
      no "the client REJECTS a name the leaf does not carry" \
        "the connection never happened, so this says nothing about verification: $out"
      ;;
    *"certificate verify failed"* | *"Hostname mismatch"* | *"Verify return code"*)
      ok "the client REJECTS a name the leaf does not carry, on a verification error"
      ;;
    *)
      no "the client REJECTS a name the leaf does not carry" \
        "exit $rc but for an unrecognised reason: $out"
      ;;
    esac
  fi

  # And a client that does NOT trust the minted root must refuse the same leaf.
  # Otherwise the handshake above would prove only that TLS happened. No
  # `-CAfile` at all here: passing the fullchain was the first attempt and it
  # HANDED the client the root, so the leaf was correctly accepted and the
  # control reported a failure that was its own.
  out="$(printf 'GET / HTTP/1.0\r\n\r\n' |
    openssl s_client -connect "127.0.0.1:$port" \
      -servername ide.example.localhost -verify_hostname ide.example.localhost \
      -no-CAfile -no-CApath -verify_return_error -brief 2>&1)"
  if [ $? -eq 0 ]; then
    no "a client with no trust anchor refuses the leaf" \
      "it was accepted without the root being trusted"
  else
    ok "a client with no trust anchor refuses the leaf"
  fi

  stop_srv
else
  no "TLS server came up on the minted leaf" "could not bind a port"
fi

# ---------------------------------------------------------------------------
# 4. report
# ---------------------------------------------------------------------------
mint report --spec "$WORK/spec.json" --cert-dir "$WORK/certs" >"$WORK/report.log" 2>&1 &&
  ok "report passes on fresh leaves" ||
  no "report passes on fresh leaves" "$(cat "$WORK/report.log")"

grep -q '89\|90' "$WORK/report.log" &&
  ok "report prints remaining validity (section 4.1)" ||
  no "report prints remaining validity (section 4.1)" "$(cat "$WORK/report.log")"

# The threshold must FAIL, not warn. Force it by raising the threshold above
# the leaf validity rather than waiting 76 days.
assert_fails "report FAILS below the threshold rather than warning" \
  "need a re-mint" \
  mint report --spec "$WORK/spec.json" --cert-dir "$WORK/certs" --fail-below 10000

# A missing leaf is a failure, not a skip: a domain row added without a re-mint
# is precisely the state that looks fine and serves nothing.
rm -rf "$WORK/certs/other.test"
assert_fails "report FAILS on a never-minted leaf" \
  "MISSING" \
  mint report --spec "$WORK/spec.json" --cert-dir "$WORK/certs"

# ---------------------------------------------------------------------------
# 5. The refusals that protect production
# ---------------------------------------------------------------------------
jq '.domains = [ { "production": "codetracer.com", "id": "localhost-ide.codetracer.com",
                   "scheme": "b", "names": [ "localhost-ide.codetracer.com" ] } ]' \
  "$WORK/spec.json" >"$WORK/spec-public.json"
assert_fails "refuses a publicly resolvable name (scheme B takes a PUBLIC cert)" \
  "reserved TLDs" \
  mint init-root --spec "$WORK/spec-public.json" \
  --key-out "$WORK/x/ca.key" --cert-out "$WORK/x/root-ca.crt"

# `.local` is RFC 6762 mDNS and the policy rules it out by name; the guard must
# not quietly accept it just because it looks like a dev TLD.
jq '.domains = [ { "production": "x.com", "id": "x.local", "scheme": "local",
                   "names": [ "x.local" ] } ]' \
  "$WORK/spec.json" >"$WORK/spec-mdns.json"
assert_fails "refuses a .local (mDNS) name" \
  "reserved TLDs" \
  mint init-root --spec "$WORK/spec-mdns.json" \
  --key-out "$WORK/y/ca.key" --cert-out "$WORK/y/root-ca.crt"

jq '.domains = [ { "production": "x.com", "id": "wrong.localhost", "scheme": "localhost",
                   "names": [ "right.localhost" ] } ]' \
  "$WORK/spec.json" >"$WORK/spec-mismatch.json"
assert_fails "refuses a row whose id does not match names[0]" \
  "derives" \
  mint mint --spec "$WORK/spec-mismatch.json" \
  --root-key "$WORK/root/ca.key" --root-cert "$WORK/certs/root-ca.crt" \
  --key-out-dir "$WORK/k2" --cert-out-dir "$WORK/c2"

jq '.domains = [ { "production": "a.com", "id": "dup.localhost", "scheme": "localhost",
                   "names": [ "dup.localhost" ] },
                 { "production": "b.com", "id": "dup.localhost", "scheme": "localhost",
                   "names": [ "dup.localhost" ] } ]' \
  "$WORK/spec.json" >"$WORK/spec-dup.json"
assert_fails "refuses two rows sharing one install directory" \
  "twice" \
  mint mint --spec "$WORK/spec-dup.json" \
  --root-key "$WORK/root/ca.key" --root-cert "$WORK/certs/root-ca.crt" \
  --key-out-dir "$WORK/k3" --cert-out-dir "$WORK/c3"

# A bad row must be refused BEFORE a root key is written, or the next run is
# blocked by the overwrite guard on a root nobody wanted.
[ ! -e "$WORK/x/ca.key" ] && [ ! -e "$WORK/y/ca.key" ] &&
  ok "a refused spec leaves no root key behind" ||
  no "a refused spec leaves no root key behind"

jq '.domains = []' "$WORK/spec.json" >"$WORK/spec-empty.json"
assert_fails "refuses an empty domain set" \
  "no domains" \
  mint report --spec "$WORK/spec-empty.json" --cert-dir "$WORK/certs"

assert_fails "refuses an unknown subcommand" \
  "unknown subcommand" \
  mint frobnicate

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
