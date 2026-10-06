#!/usr/bin/env bash
#
# netrc-wire-test.sh — what the netrc written by `write-netrc.sh` makes curl
# actually SEND, and to whom.
#
# WHY A SECOND SUITE BESIDE write-netrc-test.sh
# ---------------------------------------------
# `write-netrc-test.sh` is a FILE-semantics suite: rotation, macdef parsing,
# atomic publication, permissions, CRLF. Everything it asserts is a statement
# about bytes on disk. That is the right shape for the GitHub credential, whose
# failure mode is loud — git prints "could not read Username" and the job dies.
#
# The cache credential's failure mode is SILENT. `setup-nix` writes
#
#     substituters = https://cache.nixos.org ${{inputs.substituters}}
#     netrc-file   = $HOME/.config/nix/netrc
#
# and every caller in this org puts its private Attic cache in `substituters`.
# With no credential for it, `GET <cache>/nix-cache-info` answers 401, Nix
# disables the substituter and retries, and everything not on cache.nixos.org
# is built FROM SOURCE — a job that looks healthy and is merely slow, until an
# ephemeral runner with an empty store turns it into a full toolchain build
# failing on some third-party fetch.
#
# And here is why a file-content suite cannot guard that: a `machine` token
# carrying a PORT or a PATH is perfectly well-formed netrc that matches
# NOTHING. `machine cache.example.com/codetracer password …` greps exactly like
# a working entry and produces byte-for-byte the same observable as the missing
# entry being fixed. A suite that only greps the file reports a green tick for
# the precise bug. So the assertions below run the real `curl` — the client Nix
# hands this file to via CURLOPT_NETRC_FILE — against a local origin that
# journals the credential each request arrived with.
#
# `--resolve <host>:<port>:127.0.0.1` is what lets the request URL carry a real
# hostname — `cache.example.com`, `github.com` — while the connection lands on
# the local probe. curl matches `machine` against the hostname it parsed from
# the URL, so the matching under test is the real one.
#
# NEGATIVE CONTROLS. Every wire case is paired with a MUTANT of the shipped
# script — the real file with one guard removed — and the pair fails if the
# case still passes against its mutant. `mutate` aborts when a line it was told
# to replace is absent, so a control cannot silently stop mutating.
#
# Needs python3 (for the probe origin) and curl. Their absence is a hard error,
# never a skip: skipping would leave the file-content suite alone, which is the
# thing that cannot see this defect.
#
# Run:  bash .github/setup-nix/tests/netrc-wire-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_NIX_DIR="$(cd "$HERE/.." && pwd)"
SCRIPT="${SETUP_NIX_WRITE_NETRC_TARGET:-$SETUP_NIX_DIR/write-netrc.sh}"
SERVER="$HERE/netrc-probe-server.py"
ACTION_YML="$SETUP_NIX_DIR/action.yml"

for f in "$SCRIPT" "$SERVER"; do
	[ -f "$f" ] || {
		echo "netrc-wire-test: cannot find $f" >&2
		exit 2
	}
done
for c in python3 curl; do
	command -v "$c" >/dev/null 2>&1 || {
		echo "netrc-wire-test: '$c' is required and not on PATH." >&2
		echo "  The wire assertions are the point of this suite; skipping them would" >&2
		echo "  leave only file-content greps, which pass for a credential filed under" >&2
		echo "  a machine name curl never matches. Install it rather than skipping." >&2
		exit 2
	}
done

PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	echo "ok   $1"
}
bad() {
	FAIL=$((FAIL + 1))
	echo "FAIL $1"
	[ -n "${2:-}" ] && echo "     $2"
	return 0
}
check() { # <desc> <actual> <expected>
	if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi
}

TMPROOT="$(mktemp -d)"
SERVER_PID=""
cleanup() {
	[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
	rm -rf "$TMPROOT"
}
trap cleanup EXIT

# Fixture credentials, shaped so a substring search for one cannot accidentally
# match the other or any ordinary text -- and DELIBERATELY not shaped like a
# real credential of any kind. An earlier revision used a JWT-looking
# `eyJhbGciOiJIUzI1NiJ9.` prefix; on a GitHub runner the diagnostics for a
# failing assertion came back as `expected [***], got [***]`, i.e. the log
# scrubber ate exactly the two values a failure needs to show. A fixture that
# cannot be printed cannot be diagnosed.
GH_TOK="FIXTURE-github-4a1c9e2b7d3f6081"
ATTIC_TOK="FIXTURE-attic-current-5b2d8f30c17e94a6"
STALE_TOK="FIXTURE-attic-previous-job-9e4f1a7c26b0d385"
ATTIC_HOST="cache.example.com"
ATTIC_ENDPOINT_DEFAULT="https://${ATTIC_HOST}/"

# ---------------------------------------------------------------------------
# mutate <outfile> <from-line> <to-line> [<from-line> <to-line> ...]
#
# The shipped script with exact lines replaced. Every <from-line> must match at
# least once, or the "mutant" is the original and the control proves nothing.
# ---------------------------------------------------------------------------
mutate() { # <out> <from> <to> ...
	local out="$1"
	shift
	local -a from=() to=() hit=()
	while [ "$#" -gt 0 ]; do
		from+=("$1")
		to+=("$2")
		hit+=(0)
		shift 2
	done

	: >"$out"
	local line i n
	n=${#from[@]}
	while IFS= read -r line || [ -n "$line" ]; do
		i=0
		while [ "$i" -lt "$n" ]; do
			if [ "$line" = "${from[$i]}" ]; then
				line="${to[$i]}"
				hit[i]=1
				break
			fi
			i=$((i + 1))
		done
		printf '%s\n' "$line" >>"$out"
	done <"$SCRIPT"

	i=0
	while [ "$i" -lt "$n" ]; do
		if [ "${hit[$i]}" -eq 0 ]; then
			echo "netrc-wire-test: mutate found no line matching:" >&2
			echo "    ${from[$i]}" >&2
			echo "  The negative control built on this mutant would be testing the" >&2
			echo "  unmodified script against itself. Fix the mutation, not the test." >&2
			exit 2
		fi
		i=$((i + 1))
	done
}

# run_writer <script> <home> [KEY=VALUE ...]
#
# `env -i` so nothing inherited from this shell — a real ATTIC_TOKEN, a real
# HOME — can decide a case.
run_writer() { # <script> <home> [env assignments...]
	local script="$1" home="$2"
	shift 2
	mkdir -p "$home/.config/nix"
	RC=0
	OUT="$(env -i \
		PATH="$PATH" \
		HOME="$home" \
		SETUP_NIX_NETRC_HOME="$home" \
		"$@" \
		bash "$script" 2>&1)" || RC=$?
	NIX_NETRC="$home/.config/nix/netrc"
	USER_NETRC="$home/.netrc"
	return 0
}

fresh_home() { # <name> -> path
	local h="$TMPROOT/$1"
	rm -rf "$h"
	mkdir -p "$h/.config/nix"
	printf '%s' "$h"
}

# ---------------------------------------------------------------------------
# The probe origin.
# ---------------------------------------------------------------------------
JOURNAL="$TMPROOT/journal"
python3 "$SERVER" --journal "$JOURNAL" >"$TMPROOT/port" 2>"$TMPROOT/server.err" &
SERVER_PID=$!
PORT=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	PORT="$(cat "$TMPROOT/port" 2>/dev/null)"
	[ -n "$PORT" ] && break
	sleep 0.25
done
if [ -z "$PORT" ]; then
	echo "netrc-wire-test: probe server did not start" >&2
	cat "$TMPROOT/server.err" >&2
	exit 2
fi

# probe <netrc> <host> <path> -> CODE, CRED_USER, CRED_PASS
probe() { # <netrc> <host> <path>
	local netrc="$1" host="$2" path="$3" line
	: >"$JOURNAL"
	CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
		--netrc-file "$netrc" \
		--resolve "${host}:${PORT}:127.0.0.1" \
		"http://${host}:${PORT}${path}" 2>/dev/null)" || CODE="curl-failed"
	# The LAST journalled request: a 401 challenge makes curl retry, and the
	# retry is the one carrying the credential.
	line="$(tail -n 1 "$JOURNAL" 2>/dev/null)"
	if [ -z "$line" ]; then
		CRED_USER="<no-request>"
		CRED_PASS="<no-request>"
		return 0
	fi
	CRED_USER="$(printf '%s' "$line" | cut -f2)"
	CRED_PASS="$(printf '%s' "$line" | cut -f3)"
	return 0
}

echo "== 1. no attic token: both files are exactly what this script wrote before =="

# The pre-change output, reproduced verbatim from the `printf` block this
# change left in place. Byte identity against it is the proof that landing the
# READ credential ahead of any caller that supplies a token changes NOTHING.
LEGACY="$TMPROOT/legacy-netrc"
{
	printf 'machine github.com\n'
	printf '  login x-access-token\n'
	printf '  password %s\n' "$GH_TOK"
} >"$LEGACY"
LEGACY_SHA="$(sha256sum <"$LEGACY" | cut -d' ' -f1)"

H1="$(fresh_home home-1)"
run_writer "$SCRIPT" "$H1" SETUP_NIX_GITHUB_TOKEN="$GH_TOK"
check "writes with no attic token and exits 0" "$RC" "0"
check "the nix netrc is byte-identical to the pre-change output" \
	"$(sha256sum <"$NIX_NETRC" | cut -d' ' -f1)" "$LEGACY_SHA"
check "the user netrc is byte-identical to the pre-change output" \
	"$(sha256sum <"$USER_NETRC" | cut -d' ' -f1)" "$LEGACY_SHA"

# Same, with an endpoint present but no token — the shape EVERY caller in this
# org has today, since `attic-endpoint` carries a default in action.yml.
H1B="$(fresh_home home-1b)"
run_writer "$SCRIPT" "$H1B" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" \
	SETUP_NIX_ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
check "an endpoint without a token adds nothing" \
	"$(sha256sum <"$NIX_NETRC" | cut -d' ' -f1)" "$LEGACY_SHA"

# ... and with substituters declared too, which is the fleet's exact shape.
H1C="$(fresh_home home-1c)"
run_writer "$SCRIPT" "$H1C" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" \
	SETUP_NIX_ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT" \
	SETUP_NIX_SUBSTITUTERS="https://${ATTIC_HOST}/codetracer"
check "a declared substituter without a token still adds nothing" \
	"$(sha256sum <"$NIX_NETRC" | cut -d' ' -f1)" "$LEGACY_SHA"
case "$OUT" in
*"read them ANONYMOUSLY"*) ok "the anonymous-read condition is named in the log" ;;
*) bad "the anonymous-read condition is named in the log" "output was: $OUT" ;;
esac

# NEGATIVE CONTROL: a writer that appends the attic entry unconditionally. If
# byte-identity still held, it would be holding for some reason other than the
# guard.
M_ALWAYS="$TMPROOT/mutant-always.sh"
# The mutation arguments are literal lines of the target script, not expansions.
# shellcheck disable=SC2016
mutate "$M_ALWAYS" \
	'  if [[ "$want_attic" -eq 1 && -n "$attic_token" ]]; then' '  if true; then'
HM="$(fresh_home home-mutant-always)"
run_writer "$M_ALWAYS" "$HM" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" \
	SETUP_NIX_ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
if [ "$(sha256sum <"$NIX_NETRC" 2>/dev/null | cut -d' ' -f1)" = "$LEGACY_SHA" ]; then
	bad "CONTROL: a writer that always appends is caught by the byte-identity case" \
		"the mutant produced the same bytes, so that case proves nothing"
else
	ok "CONTROL: a writer that always appends is caught by the byte-identity case"
fi

echo
echo "== 2. attic token supplied: Nix can READ the private cache =="

H2="$(fresh_home home-2)"
run_writer "$SCRIPT" "$H2" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" \
	SETUP_NIX_ATTIC_TOKEN="$ATTIC_TOK" \
	SETUP_NIX_ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
check "writes with an attic token and exits 0" "$RC" "0"
check "the nix netrc names the bare host" \
	"$(grep -c "^machine ${ATTIC_HOST} password " "$NIX_NETRC")" "1"

# THE WIRE. This is the assertion the whole suite exists for.
probe "$NIX_NETRC" "$ATTIC_HOST" "/codetracer/nix-cache-info"
check "the cache receives the attic token" "$CRED_PASS" "$ATTIC_TOK"
check "the cache request is authorised" "$CODE" "200"

probe "$NIX_NETRC" "github.com" "/metacraft-labs/codetracer"
check "github.com still receives the github token" "$CRED_PASS" "$GH_TOK"
check "github.com still receives the x-access-token login" "$CRED_USER" "x-access-token"

# TOO BROAD, in all three directions, observed rather than reasoned about.
probe "$NIX_NETRC" "$ATTIC_HOST" "/codetracer/nix-cache-info"
check "the cache never receives the github token" \
	"$(test "$CRED_PASS" = "$GH_TOK" && echo leaked || echo no)" "no"
probe "$NIX_NETRC" "github.com" "/metacraft-labs/codetracer"
check "github.com never receives the attic token" \
	"$(test "$CRED_PASS" = "$ATTIC_TOK" && echo leaked || echo no)" "no"
probe "$NIX_NETRC" "third-party.example.org" "/whatever"
check "a host with no entry receives no credential at all" "$CRED_PASS" "-"

# The user netrc is git's, and a binary-cache token has no business in it.
check "the cache token is not written into the user netrc" \
	"$(grep -c "$ATTIC_TOK" "$USER_NETRC")" "0"
probe "$USER_NETRC" "$ATTIC_HOST" "/codetracer/nix-cache-info"
check "and the cache receives nothing from the user netrc" "$CRED_PASS" "-"

# NEGATIVE CONTROL: the shipped script with the attic entry never appended —
# i.e. the defect exactly as it shipped.
M_NONE="$TMPROOT/mutant-none.sh"
# The mutation arguments are literal lines of the target script, not expansions.
# shellcheck disable=SC2016
mutate "$M_NONE" \
	'  if [[ "$want_attic" -eq 1 && -n "$attic_token" ]]; then' '  if false; then'
HMN="$(fresh_home home-mutant-none)"
run_writer "$M_NONE" "$HMN" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" \
	SETUP_NIX_ATTIC_TOKEN="$ATTIC_TOK" \
	SETUP_NIX_ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
probe "$NIX_NETRC" "$ATTIC_HOST" "/codetracer/nix-cache-info"
check "CONTROL: without the entry the cache gets nothing and answers 401" "$CODE" "401"
check "CONTROL: without the entry no credential reaches the cache" "$CRED_PASS" "-"

echo
echo "== 3. the machine name is the HOST, which is the only thing curl matches =="

for ep in \
	"https://${ATTIC_HOST}" \
	"https://${ATTIC_HOST}/" \
	"https://${ATTIC_HOST}/codetracer" \
	"https://${ATTIC_HOST}:8443/codetracer" \
	"https://user:pw@${ATTIC_HOST}/codetracer"; do
	HE="$(fresh_home home-ep)"
	run_writer "$SCRIPT" "$HE" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" \
		SETUP_NIX_ATTIC_TOKEN="$ATTIC_TOK" SETUP_NIX_ATTIC_ENDPOINT="$ep"
	if [ "$RC" -ne 0 ]; then
		bad "endpoint '$ep' yields a usable entry" "writer exited $RC: $OUT"
		continue
	fi
	probe "$NIX_NETRC" "$ATTIC_HOST" "/codetracer/nix-cache-info"
	check "endpoint '$ep' -> the token reaches ${ATTIC_HOST}" "$CRED_PASS" "$ATTIC_TOK"
done

# NEGATIVE CONTROL: keep the path in the machine name (and disable the guard
# that would otherwise refuse the resulting name, so the mutant produces a
# plausible-looking file rather than an error). curl must then send nothing.
M_PATH="$TMPROOT/mutant-path.sh"
# The mutation arguments are literal lines of the target script, not expansions.
# shellcheck disable=SC2016
mutate "$M_PATH" \
	'  authority="${authority%%/*}"  # path' '  : # mutant: path not stripped' \
	'    *[!0-9A-Za-z._-]*)' '    *XXXneverXXX*)'
HMP="$(fresh_home home-mutant-path)"
run_writer "$M_PATH" "$HMP" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" \
	SETUP_NIX_ATTIC_TOKEN="$ATTIC_TOK" \
	SETUP_NIX_ATTIC_ENDPOINT="https://${ATTIC_HOST}/codetracer"
if [ "$RC" -ne 0 ]; then
	bad "CONTROL: the path-keeping mutant writes a file" "it exited $RC: $OUT"
else
	check "CONTROL: the path-keeping mutant files the entry under a name with a path" \
		"$(grep -c "^machine ${ATTIC_HOST}/codetracer " "$NIX_NETRC")" "1"
	probe "$NIX_NETRC" "$ATTIC_HOST" "/codetracer/nix-cache-info"
	check "CONTROL: curl matches that entry against nothing, so the cache gets no credential" \
		"$CRED_PASS" "-"
fi

echo
echo "== 4. a reused \$HOME: a previous job's cache entry must not survive =="

# Self-hosted runners in this org reuse \$HOME between jobs, so a netrc this
# job publishes can start life as the one the last job left. The property is
# that the file this job hands to Nix carries no credential this job was not
# given: an entry the owner has since rotated away is a credential presented
# to the cache on every request, and which of two entries for one host wins
# is not even a fixed answer — see the control at the end of this section.
H4="$(fresh_home home-4)"
{
	printf 'machine %s password %s\n' "$ATTIC_HOST" "$STALE_TOK"
	printf 'machine unrelated.example.org password KEEP-ME\n'
} >"$H4/.config/nix/netrc"
chmod 644 "$H4/.config/nix/netrc"
run_writer "$SCRIPT" "$H4" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" \
	SETUP_NIX_ATTIC_TOKEN="$ATTIC_TOK" \
	SETUP_NIX_ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
check "the run succeeds over a netrc a previous job left behind" "$RC" "0"
probe "$NIX_NETRC" "$ATTIC_HOST" "/codetracer/nix-cache-info"
check "the cache receives THIS job's token, not the stale one" "$CRED_PASS" "$ATTIC_TOK"
check "the stale token is gone from the file" "$(grep -c "$STALE_TOK" "$NIX_NETRC")" "0"
check "an unrelated record is preserved" \
	"$(grep -c '^machine unrelated.example.org password KEEP-ME$' "$NIX_NETRC")" "1"
check "the replaced file is mode 600 even though it was 644" \
	"$(stat -c '%a' "$NIX_NETRC")" "600"

# Case is not significant in a netrc machine name, and a previous job may well
# have written the host in a different case than this one reads it in.
H4B="$(fresh_home home-4b)"
printf 'machine %s password %s\n' "CACHE.Example.COM" "$STALE_TOK" >"$H4B/.config/nix/netrc"
run_writer "$SCRIPT" "$H4B" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" \
	SETUP_NIX_ATTIC_TOKEN="$ATTIC_TOK" \
	SETUP_NIX_ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
check "a stale entry spelled in another case is dropped too" \
	"$(grep -c "$STALE_TOK" "$NIX_NETRC")" "0"

# NEGATIVE CONTROL: the filter told to drop github.com only, which is what it
# did before this change. The previous job's cache entry then survives into the
# file this job hands to Nix, alongside this job's own -- two credentials under
# one machine name.
#
# THE ASSERTION IS ON THE FILE HERE, NOT ON THE WIRE, and that is a finding
# rather than a convenience. An earlier revision asserted "curl then sends the
# PREVIOUS job's token", on the usual claim that a netrc reader takes the FIRST
# matching `machine`. Two curls agree with that; the curl on `ubuntu-latest`
# does not, and that one assertion failed there while the other 53 passed. So
# WHICH of two same-host entries is presented is a property of the client, not
# of the format -- which makes a file carrying both strictly worse than either
# bug alone: the credential the job presents depends on the curl Nix happens to
# link against. The observed choice is PRINTED below rather than asserted, so
# the log records it on every platform without pinning behaviour this
# repository does not control.
M_KEEP="$TMPROOT/mutant-keep-stale.sh"
# The mutation arguments are literal lines of the target script, not expansions.
# shellcheck disable=SC2016
mutate "$M_KEEP" \
	'    drop_globs+=("$(case_insensitive_glob "$attic_host")")' '    : # mutant: stale cache entries kept'
HMK="$(fresh_home home-mutant-keep)"
printf 'machine %s password %s\n' "$ATTIC_HOST" "$STALE_TOK" >"$HMK/.config/nix/netrc"
run_writer "$M_KEEP" "$HMK" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" \
	SETUP_NIX_ATTIC_TOKEN="$ATTIC_TOK" \
	SETUP_NIX_ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
check "CONTROL: without the drop, the PREVIOUS job's token survives into the file" \
	"$(grep -c "$STALE_TOK" "$NIX_NETRC")" "1"
check "CONTROL: and the host then carries two conflicting credentials" \
	"$(grep -c "^machine ${ATTIC_HOST} password " "$NIX_NETRC")" "2"
probe "$NIX_NETRC" "$ATTIC_HOST" "/codetracer/nix-cache-info"
CURL_ID="$(curl --version | head -n 1 | cut -d' ' -f1-2)"
case "$CRED_PASS" in
"$STALE_TOK") ok "CONTROL: the two-credential file presents one of them ($CURL_ID chose the FIRST entry, the previous job's)" ;;
"$ATTIC_TOK") ok "CONTROL: the two-credential file presents one of them ($CURL_ID chose the LAST entry, this job's)" ;;
*) bad "CONTROL: the two-credential file presents one of the two tokens" "it presented [$CRED_PASS]" ;;
esac

echo
echo "== 5. a token that cannot be filed is a loud failure, never a silent one =="

# Every case here is one where the OLD behaviour — write the github entry and
# say nothing — would leave Nix reading the cache anonymously while the job
# looks healthy. That is the failure mode this whole change is about, so none
# of them may be quiet.
HX="$(fresh_home home-x)"

run_writer "$SCRIPT" "$HX" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" SETUP_NIX_ATTIC_TOKEN="$ATTIC_TOK"
check "an attic token with an empty endpoint is refused" "$RC" "1"

run_writer "$SCRIPT" "$HX" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" \
	SETUP_NIX_ATTIC_TOKEN="$ATTIC_TOK" SETUP_NIX_ATTIC_ENDPOINT="${ATTIC_HOST}/codetracer"
check "an endpoint with no scheme is refused" "$RC" "1"

run_writer "$SCRIPT" "$HX" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" \
	SETUP_NIX_ATTIC_TOKEN="$ATTIC_TOK" SETUP_NIX_ATTIC_ENDPOINT="https://[2001:db8::1]:8443/c"
check "an IPv6-literal endpoint is refused rather than guessed at" "$RC" "1"

run_writer "$SCRIPT" "$HX" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" \
	SETUP_NIX_ATTIC_TOKEN="${ATTIC_TOK}"$'\n' SETUP_NIX_ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
check "a token with a trailing newline is refused, not truncated" "$RC" "1"
case "$OUT" in
*"$ATTIC_TOK"*) bad "the refusal does not echo the token" "the diagnostic contained it" ;;
*) ok "the refusal does not echo the token" ;;
esac

run_writer "$SCRIPT" "$HX" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" \
	SETUP_NIX_ATTIC_TOKEN="$ATTIC_TOK" SETUP_NIX_ATTIC_ENDPOINT="https://github.com/cache"
check "an endpoint colliding with the github.com stanza is refused" "$RC" "1"

# NEGATIVE CONTROL: without the whitespace guard the writer succeeds and files
# an entry whose password is the token up to the space — a truncated
# credential, filed and reported as a success.
M_WS="$TMPROOT/mutant-ws.sh"
# The mutation arguments are literal lines of the target script, not expansions.
# shellcheck disable=SC2016
mutate "$M_WS" '    *[[:space:]]*)' '    *XXXneverXXX*)'
HMW="$(fresh_home home-mutant-ws)"
run_writer "$M_WS" "$HMW" SETUP_NIX_GITHUB_TOKEN="$GH_TOK" \
	SETUP_NIX_ATTIC_TOKEN="${ATTIC_TOK} extra" \
	SETUP_NIX_ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
check "CONTROL: without the whitespace guard the writer reports success" "$RC" "0"
probe "$NIX_NETRC" "$ATTIC_HOST" "/codetracer/nix-cache-info"
check "CONTROL: and the cache receives a TRUNCATED credential" "$CRED_PASS" "$ATTIC_TOK"

echo
echo "== 6. a cache token alone, with no github token =="

# `nix-github-token` is optional and many callers pass none. Before this change
# the script exited before writing anything in that case; a cache credential
# must still be filed, and the github stanza must NOT be invented.
H6="$(fresh_home home-6)"
run_writer "$SCRIPT" "$H6" SETUP_NIX_ATTIC_TOKEN="$ATTIC_TOK" \
	SETUP_NIX_ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
check "a cache token with no github token exits 0" "$RC" "0"
probe "$NIX_NETRC" "$ATTIC_HOST" "/codetracer/nix-cache-info"
check "the cache still receives the token" "$CRED_PASS" "$ATTIC_TOK"
check "no github stanza is invented" "$(grep -c '^machine github.com' "$NIX_NETRC")" "0"
check "the user netrc is not created" \
	"$(test -e "$USER_NETRC" && echo exists || echo absent)" "absent"

# A github credential somebody else filed in the user netrc must survive a run
# that has no github token of its own to replace it with.
H6B="$(fresh_home home-6b)"
printf 'machine github.com login x-access-token password SOMEONE-ELSES\n' >"$H6B/.netrc"
run_writer "$SCRIPT" "$H6B" SETUP_NIX_ATTIC_TOKEN="$ATTIC_TOK" \
	SETUP_NIX_ATTIC_ENDPOINT="$ATTIC_ENDPOINT_DEFAULT"
check "a github credential this run cannot replace is left alone" \
	"$(grep -c 'SOMEONE-ELSES' "$USER_NETRC")" "1"

# And with NEITHER token nothing is touched at all, which is the pre-change
# behaviour for that case.
H6C="$(fresh_home home-6c)"
printf 'machine anything.example.org password UNTOUCHED\n' >"$H6C/.config/nix/netrc"
run_writer "$SCRIPT" "$H6C"
check "with no tokens at all the writer exits 0" "$RC" "0"
check "with no tokens at all the existing netrc is untouched" \
	"$(grep -c 'UNTOUCHED' "$NIX_NETRC")" "1"

echo
echo "== 7. action.yml actually hands it the tokens, through env =="

if [ -f "$ACTION_YML" ]; then
	# The step under test, isolated. Asserting against the whole manifest would
	# be satisfied by the token appearing in the Attic UPLOAD step, which is
	# where it already was while Nix had no credential at all — the defect.
	STEP="$TMPROOT/configure-nix-step.yml"
	awk '
		/^    - name: Configure Nix$/ { inside = 1; next }
		inside && /^    - name: / { inside = 0 }
		inside { print }
	' "$ACTION_YML" >"$STEP"
	if [ ! -s "$STEP" ]; then
		bad "the 'Configure Nix' step can be located in action.yml" \
			"the extractor found nothing; this suite would then assert nothing"
	else
		check "the step delegates the netrc to write-netrc.sh" \
			"$(grep -cE 'write-netrc\.sh"$' "$STEP")" "1"
		check "the step is given the attic token" \
			"$(grep -cE '^[[:space:]]*SETUP_NIX_ATTIC_TOKEN: \$\{\{ inputs\.attic-token \}\}[[:space:]]*$' "$STEP")" "1"
		check "the step is given the attic endpoint" \
			"$(grep -cE '^[[:space:]]*SETUP_NIX_ATTIC_ENDPOINT: \$\{\{ inputs\.attic-endpoint \}\}[[:space:]]*$' "$STEP")" "1"
		check "the step is given the declared substituters, so it can name the anonymous-read case" \
			"$(grep -cE '^[[:space:]]*SETUP_NIX_SUBSTITUTERS: \$\{\{ inputs\.substituters \}\}[[:space:]]*$' "$STEP")" "1"
	fi

	# Interpolating a secret into a `run:` body bakes it into the command file
	# the runner writes to disk and executes, and into any `set -x` trace of it.
	# Routing it through `env:` does not. `if:` is exempt: a step condition is
	# evaluated by the runner and never written into a script.
	MENTIONS="$(grep -cE '^[[:space:]]*[^#].*inputs\.attic-token' "$ACTION_YML")"
	ALLOWED="$(grep -cE '^[[:space:]]*(SETUP_NIX_ATTIC_TOKEN|ATTIC_TOKEN|attic-token): \$\{\{ inputs\.attic-token \}\}[[:space:]]*$|^[[:space:]]*if: .*inputs\.attic-token' "$ACTION_YML")"
	check "action.yml never interpolates the attic token into a command" \
		"$((MENTIONS - ALLOWED))" "0"
else
	bad "action.yml is present two directories up from this suite"
fi

echo
echo "assertions: $((PASS + FAIL))  pass: $PASS  fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then
	echo "netrc-wire-test: CONTRACTS BROKEN." >&2
	exit 1
fi
echo "netrc-wire-test: all contracts hold."
