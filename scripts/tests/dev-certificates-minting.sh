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

# serve [<cert> <key>]  -> starts a server on a free port; sets SRV_PORT and
# SRV_PID. Serves the example.localhost leaf unless told otherwise.
#
# Called directly, NEVER as `port="$(serve)"`: a command substitution runs it in
# a subshell, so the `SRV_PID=$!` below would be lost with that subshell, and
# both `stop_srv` and the EXIT trap would see an empty SRV_PID and kill nothing.
# That is how this first shipped -- every run leaked an `openssl s_server`, and
# under `nix shell ... | tail` the orphan held the pipeline open so the run hung.
SRV_PORT=
serve() {
  local cert="${1:-$WORK/certs/example.localhost/fullchain.pem}"
  local key="${2:-$WORK/keys/example.localhost.key.pem}"
  SRV_PORT="$(free_port)" || return 1
  openssl s_server -accept "$SRV_PORT" \
    -cert "$cert" \
    -key "$key" \
    -www >"$WORK/server-$SRV_PORT.log" 2>&1 &
  SRV_PID=$!
  await_port "$SRV_PORT" || return 1
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

# handshake_ip <port> <ip>  -> exit status of a client that verifies the server
# as the IP address <ip>. It DIALS loopback and checks the leaf against <ip>,
# exactly as `curl --connect-to` would: the address being verified is the one
# the client believes it reached, which is what a client on the overlay does.
handshake_ip() {
  printf 'GET / HTTP/1.0\r\n\r\n' |
    openssl s_client -connect "127.0.0.1:$1" \
      -verify_ip "$2" \
      -CAfile "$WORK/certs/root-ca.crt" \
      -verify_return_error -brief 2>&1
}

# expect_verified <label> <rc> <transcript>
expect_verified() {
  if [ "$2" -ne 0 ]; then
    no "$1" "exit $2: $3"
    return
  fi
  # "Verification: OK" is what proves the chain was CHECKED and accepted, not
  # that checking was skipped.
  case "$3" in
  *"Verification: OK"*) ok "$1" ;;
  *) no "$1" "exit 0 but no 'Verification: OK' in the transcript: $3" ;;
  esac
}

# expect_rejected <label> <rc> <transcript>: the handshake must fail ON A
# VERIFICATION ERROR. A refused connection would also be non-zero and would
# prove nothing about verification, so it is a failure of the control.
expect_rejected() {
  if [ "$2" -eq 0 ]; then
    no "$1" "it was accepted -- verification is not actually on"
    return
  fi
  case "$3" in
  *"Connection refused"*)
    no "$1" "the connection never happened, so this says nothing about verification: $3"
    ;;
  *"certificate verify failed"* | *"mismatch"* | *"Verify return code"*)
    ok "$1"
    ;;
  *) no "$1" "exit $2 but for an unrecognised reason: $3" ;;
  esac
}

if serve; then
  port="$SRV_PORT"
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
  # The server must actually be gone, not merely forgotten: a stop that kills
  # nothing passes silently and leaks a listener on every run.
  if (exec 3<>/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then
    no "the TLS server is stopped once the test is done with it" \
      "port $port still accepts connections"
  else
    ok "the TLS server is stopped once the test is done with it"
  fi
else
  no "TLS server came up on the minted leaf" "could not bind a port"
fi

# ---------------------------------------------------------------------------
# 3b. Home-network HOST rows (policy section 2.1). The same root, a declared
#     `"kind": "host"` row, one <host>.home.arpa name and the host's own
#     private/overlay addresses as IP SANs -- proven by a real handshake to the
#     name AND to each address, with negative controls on the same server.
# ---------------------------------------------------------------------------
jq '.domains = [
      { "production": "example.com", "id": "example.localhost", "scheme": "localhost",
        "names": [ "example.localhost", "*.example.localhost" ] },
      { "id": "macbook-2012.home.arpa", "kind": "host",
        "names": [ "macbook-2012.home.arpa" ],
        "addresses": [ "10.100.0.19", "100.83.29.229" ] },
      { "id": "nas.home.arpa", "kind": "host", "names": [ "nas.home.arpa" ] },
      { "id": "dev.test", "kind": "dev", "names": [ "dev.test" ] }
    ]' "$WORK/spec.json" >"$WORK/spec-host.json"

if mint mint --spec "$WORK/spec-host.json" \
  --root-key "$WORK/root/ca.key" --root-cert "$WORK/certs/root-ca.crt" \
  --key-out-dir "$WORK/hkeys" --cert-out-dir "$WORK/hcerts" >"$WORK/mint-host.log" 2>&1; then
  ok "mint succeeds for a spec with host rows"
else
  no "mint succeeds for a spec with host rows" "$(cat "$WORK/mint-host.log")"
fi

HLEAF="$WORK/hcerts/macbook-2012.home.arpa/fullchain.pem"
HKEY="$WORK/hkeys/macbook-2012.home.arpa.key.pem"

openssl verify -CAfile "$WORK/certs/root-ca.crt" <(openssl x509 -in "$HLEAF") >/dev/null 2>&1 &&
  ok "host leaf verifies against the minted root" ||
  no "host leaf verifies against the minted root"

hkmode="$(stat -c '%a' "$HKEY" 2>/dev/null || stat -f '%Lp' "$HKEY")"
[ "$hkmode" = "600" ] && ok "host leaf key is mode 600" || no "host leaf key is mode 600" "got $hkmode"

# san_entries <cert>: one subjectAltName entry per line, so assertions compare
# whole entries -- "IP Address:10.0.0.1" must not be satisfied by "...:10.0.0.12".
san_entries() {
  openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null |
    awk 'NR > 1 { sub(/^[ \t]+/, ""); n = split($0, e, ", "); for (k = 1; k <= n; k++) print e[k] }'
}
hsan="$(san_entries "$HLEAF")"
for want in "DNS:macbook-2012.home.arpa" "IP Address:10.100.0.19" "IP Address:100.83.29.229"; do
  grep -Fxq -- "$want" <<<"$hsan" &&
    ok "host leaf carries $want" ||
    no "host leaf carries $want" "$hsan"
done
[ "$(grep -c . <<<"$hsan")" = "3" ] &&
  ok "host leaf carries exactly its one name and two addresses" ||
  no "host leaf carries exactly its one name and two addresses" "$hsan"

# Addresses are optional on a host row; without them the leaf is DNS-only.
nsan="$(san_entries "$WORK/hcerts/nas.home.arpa/fullchain.pem")"
[ "$nsan" = "DNS:nas.home.arpa" ] &&
  ok "a host row without addresses mints a DNS-only leaf" ||
  no "a host row without addresses mints a DNS-only leaf" "$nsan"

# A Scheme A row in the same spec is untouched: no IP SAN creeps onto it, and
# an explicit `"kind": "dev"` means what an absent kind means.
dsan="$(san_entries "$WORK/hcerts/example.localhost/fullchain.pem")"
# (Its own name must be there too, or a missing leaf would pass vacuously.)
if grep -Fxq "DNS:example.localhost" <<<"$dsan" && ! grep -q '^IP Address:' <<<"$dsan"; then
  ok "a Scheme A leaf minted beside host rows carries no IP SAN"
else
  no "a Scheme A leaf minted beside host rows carries no IP SAN" "$dsan"
fi
[ "$(san_entries "$WORK/hcerts/dev.test/fullchain.pem")" = "DNS:dev.test" ] &&
  ok "an explicit kind \"dev\" row mints as a Scheme A row" ||
  no "an explicit kind \"dev\" row mints as a Scheme A row"

if serve "$HLEAF" "$HKEY"; then
  hport="$SRV_PORT"
  ok "TLS server came up on the host leaf"

  out="$(handshake "$hport" macbook-2012.home.arpa)"
  expect_verified "a real client completed a VERIFIED handshake to macbook-2012.home.arpa" $? "$out"
  out="$(handshake_ip "$hport" 10.100.0.19)"
  expect_verified "a real client completed a VERIFIED handshake to the home address 10.100.0.19" $? "$out"
  out="$(handshake_ip "$hport" 100.83.29.229)"
  expect_verified "a real client completed a VERIFIED handshake to the overlay address 100.83.29.229" $? "$out"

  out="$(handshake "$hport" other-host.home.arpa)"
  expect_rejected "the client REJECTS a home.arpa name the host leaf does not carry" $? "$out"
  out="$(handshake_ip "$hport" 10.100.0.20)"
  expect_rejected "the client REJECTS an address the host leaf does not carry (10.100.0.20)" $? "$out"
  # The address the client actually dialled is not on the leaf either: the
  # IP check is against the SAN, not against where the bytes went.
  out="$(handshake_ip "$hport" 127.0.0.1)"
  expect_rejected "the client REJECTS the dialled loopback address, which the host leaf does not carry" $? "$out"

  stop_srv
else
  no "TLS server came up on the host leaf" "could not bind a port"
fi

# Section 4.1 applies to host leaves unchanged; a lapse there breaks a running
# service for every client.
mint report --spec "$WORK/spec-host.json" --cert-dir "$WORK/hcerts" >"$WORK/report-host.log" 2>&1 &&
  ok "report passes on fresh host leaves" ||
  no "report passes on fresh host leaves" "$(cat "$WORK/report-host.log")"
grep -q '^macbook-2012.home.arpa .* ok$' "$WORK/report-host.log" &&
  ok "report lists the host leaf by its id" ||
  no "report lists the host leaf by its id" "$(cat "$WORK/report-host.log")"

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

# A name that is not a plain DNS name must be refused outright. The newline
# case is the one that matters: it once passed the TLD check on its first line
# and then became an extra, unchecked row -- and a leaf for evil.com.
jq '.domains = [ { "production": "x.com", "id": "x.test", "scheme": "test",
                   "names": [ "x.test", "y.test\nfoo\tevil.com" ] } ]' \
  "$WORK/spec.json" >"$WORK/spec-inject.json"
assert_fails "refuses a name carrying a newline (no smuggled extra row)" \
  "not a DNS name" \
  mint mint --spec "$WORK/spec-inject.json" \
  --root-key "$WORK/root/ca.key" --root-cert "$WORK/certs/root-ca.crt" \
  --key-out-dir "$WORK/k4" --cert-out-dir "$WORK/c4"
[ ! -e "$WORK/c4/foo" ] && [ ! -e "$WORK/k4/foo.key.pem" ] &&
  ok "the smuggled row produced no leaf" ||
  no "the smuggled row produced no leaf"

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

# ---------------------------------------------------------------------------
# 5b. Host-row refusals (policy section 2.1 / section 4). Each must exit
#     non-zero with its own message AND leave no leaf behind: the host
#     exception is narrow on purpose, and every way out of it is a refusal.
# ---------------------------------------------------------------------------
# assert_refused_mint <label> <expected substring> <tag> <jq row(s)>
assert_refused_mint() {
  local label="$1" want="$2" tag="$3" rows="$4"
  jq ".domains = [ $rows ]" "$WORK/spec.json" >"$WORK/spec-$tag.json" || {
    no "$label" "the test's own jq for this case failed"
    return
  }
  assert_fails "$label" "$want" \
    mint mint --spec "$WORK/spec-$tag.json" \
    --root-key "$WORK/root/ca.key" --root-cert "$WORK/certs/root-ca.crt" \
    --key-out-dir "$WORK/k-$tag" --cert-out-dir "$WORK/c-$tag"
  if [ -n "$(ls -A "$WORK/k-$tag" "$WORK/c-$tag" 2>/dev/null)" ]; then
    no "$label: no leaf is created" "$(ls -AR "$WORK/k-$tag" "$WORK/c-$tag" 2>&1)"
  else
    ok "$label: no leaf is created"
  fi
}

H='"id": "macbook-2012.home.arpa", "kind": "host"'

assert_refused_mint "refuses a host row with two names" \
  "with 2 names" two-names \
  "{ $H, \"names\": [ \"macbook-2012.home.arpa\", \"hub.home.arpa\" ] }"
assert_refused_mint "refuses a host row with a wildcard" \
  "takes no wildcard" wildcard \
  "{ $H, \"names\": [ \"*.macbook-2012.home.arpa\" ] }"
assert_refused_mint "refuses a host row two labels under home.arpa" \
  "single host label" two-labels \
  '{ "id": "svc.macbook-2012.home.arpa", "kind": "host", "names": [ "svc.macbook-2012.home.arpa" ] }'
assert_refused_mint "refuses a host row whose name is not under home.arpa" \
  "RFC 8375" public-name \
  '{ "id": "hub.codetracer.com", "kind": "host", "names": [ "hub.codetracer.com" ] }'
assert_refused_mint "refuses a host row with a .local (mDNS) name" \
  "RFC 8375" mdns-host \
  '{ "id": "macbook-2012.local", "kind": "host", "names": [ "macbook-2012.local" ] }'
assert_refused_mint "refuses a host row with a public address (8.8.8.8)" \
  "private (RFC 1918" public-ip \
  "{ $H, \"names\": [ \"macbook-2012.home.arpa\" ], \"addresses\": [ \"10.100.0.19\", \"8.8.8.8\" ] }"
assert_refused_mint "refuses a host row with a loopback address (127.0.0.1)" \
  "private (RFC 1918" loopback-ip \
  "{ $H, \"names\": [ \"macbook-2012.home.arpa\" ], \"addresses\": [ \"127.0.0.1\" ] }"
assert_refused_mint "refuses a host row with an address just outside 100.64/10 (100.128.0.1)" \
  "private (RFC 1918" cgnat-edge \
  "{ $H, \"names\": [ \"macbook-2012.home.arpa\" ], \"addresses\": [ \"100.128.0.1\" ] }"
assert_refused_mint "refuses a host row with an IPv6 address" \
  "not a list of IPv4 dotted-quad strings" ipv6 \
  "{ $H, \"names\": [ \"macbook-2012.home.arpa\" ], \"addresses\": [ \"fd00::1\" ] }"
assert_refused_mint "refuses a host row with an octet over 255 (10.0.0.256)" \
  "greater than 255" octet-256 \
  "{ $H, \"names\": [ \"macbook-2012.home.arpa\" ], \"addresses\": [ \"10.0.0.256\" ] }"
assert_refused_mint "refuses a host row with a leading-zero octet (010.0.0.1)" \
  "without leading zeros" leading-zero \
  "{ $H, \"names\": [ \"macbook-2012.home.arpa\" ], \"addresses\": [ \"010.0.0.1\" ] }"
assert_refused_mint "refuses a host row with a three-octet address (10.0.0)" \
  "exactly four octets" three-octets \
  "{ $H, \"names\": [ \"macbook-2012.home.arpa\" ], \"addresses\": [ \"10.0.0\" ] }"
# The smuggling case, as for names: a newline inside one address must not
# split into an extra line of the row stream.
assert_refused_mint "refuses an address carrying a newline (10.0.0.1\\nfoo)" \
  "not a list of IPv4 dotted-quad strings" ip-newline \
  "{ $H, \"names\": [ \"macbook-2012.home.arpa\" ], \"addresses\": [ \"10.0.0.1\\nfoo\" ] }"
assert_refused_mint "refuses \"addresses\" that is not a list" \
  "not a list of IPv4 dotted-quad strings" ip-scalar \
  "{ $H, \"names\": [ \"macbook-2012.home.arpa\" ], \"addresses\": \"10.0.0.1\" }"
assert_refused_mint "refuses \"addresses\" on a Scheme A row" \
  'carries "addresses"' dev-addresses \
  '{ "id": "x.test", "names": [ "x.test" ], "addresses": [ "10.0.0.1" ] }'
assert_refused_mint "refuses a home.arpa name in a Scheme A row" \
  "Declare it as a home-network host row" dev-home-arpa \
  '{ "id": "macbook-2012.home.arpa", "names": [ "macbook-2012.home.arpa" ] }'
assert_refused_mint "refuses a home.arpa name in an explicit kind \"dev\" row" \
  "Declare it as a home-network host row" dev-kind-home-arpa \
  '{ "id": "macbook-2012.home.arpa", "kind": "dev", "names": [ "macbook-2012.home.arpa" ] }'
assert_refused_mint "refuses an unknown kind" \
  "unknown kind 'server'" unknown-kind \
  '{ "id": "macbook-2012.home.arpa", "kind": "server", "names": [ "macbook-2012.home.arpa" ] }'
assert_refused_mint "refuses a kind that is not a string" \
  "kind that is not a string" kind-number \
  '{ "id": "x.test", "kind": 1, "names": [ "x.test" ] }'

# A bad host row is refused before init-root writes a root key, as for any row.
jq '.domains = [ { "id": "hub.example.com", "kind": "host", "names": [ "hub.example.com" ] } ]' \
  "$WORK/spec.json" >"$WORK/spec-host-root.json"
assert_fails "init-root refuses a spec with a bad host row" \
  "RFC 8375" \
  mint init-root --spec "$WORK/spec-host-root.json" \
  --key-out "$WORK/z/ca.key" --cert-out "$WORK/z/root-ca.crt"
[ ! -e "$WORK/z/ca.key" ] &&
  ok "a refused host row leaves no root key behind" ||
  no "a refused host row leaves no root key behind"

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
