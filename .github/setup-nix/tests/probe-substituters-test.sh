#!/usr/bin/env bash
# probe-substituters-test.sh — contract suite for ../probe-substituters.sh.
#
# No mocks of the unit under test: the real script runs against a real HTTP
# origin (a throwaway Python server on 127.0.0.1) through the real curl, and the
# credential comes from a real netrc file, exactly as on a runner. The origin
# plays the four cache shapes seen in production:
#
#   /ok/          200 + a nix-cache-info body          (a healthy cache)
#   /private/     401 unless Basic credentials arrive  (Attic, no/bad token)
#   /acl/         403 nginx page                       (Attic behind an ACL
#                                                        that excludes us)
#   /portal/      200 + HTML                           (captive portal)
#   /missing/     404                                  (wrong cache name)
#
# plus a closed port for "unreachable".
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
probe="$here/../probe-substituters.sh"
work="$(mktemp -d)"
server_pid=""
cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

cat >"$work/origin.py" <<'PY'
import base64, sys
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

GOOD = "good-token"

class H(BaseHTTPRequestHandler):
    def reply(self, code, body, ctype="text/plain"):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        cache_info = "StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 40\n"
        if self.path == "/ok/nix-cache-info":
            return self.reply(200, cache_info)
        if self.path == "/private/nix-cache-info":
            auth = self.headers.get("Authorization", "")
            if auth.startswith("Basic "):
                _, _, password = base64.b64decode(auth[6:]).decode().partition(":")
                if password == GOOD:
                    return self.reply(200, cache_info)
            return self.reply(401, '{"code":401,"error":"Unauthorized"}')
        if self.path == "/acl/nix-cache-info":
            return self.reply(403, "<html><head><title>403 Forbidden</title></head><body><center>nginx</center></body></html>", "text/html")
        if self.path == "/portal/nix-cache-info":
            return self.reply(200, "<html>Please log in to the Wi-Fi</html>", "text/html")
        return self.reply(404, "not found")

    def log_message(self, *a):
        pass

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY

python3 "$work/origin.py" >"$work/port" &
server_pid=$!
for _ in $(seq 1 50); do [[ -s "$work/port" ]] && break; sleep 0.1; done
port="$(cat "$work/port")"
base="http://127.0.0.1:$port"

# A port nothing listens on: bind, record, release.
closed_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

pass=0
fail=0

# run <name> <expected-exit> <env...> -- stores output in $out
run() {
  local name="$1" expect="$2"
  shift 2
  local rc=0
  out="$(env -i PATH="$PATH" HOME="$work" \
    SETUP_NIX_PROBE_UPSTREAM="$base/ok" \
    SETUP_NIX_PROBE_ATTEMPTS=2 \
    SETUP_NIX_PROBE_CONNECT_TIMEOUT=2 \
    SETUP_NIX_PROBE_MAX_TIME=5 \
    "$@" bash "$probe" 2>&1)" || rc=$?
  if [[ "$rc" != "$expect" ]]; then
    echo "FAIL [$name]: exit $rc, expected $expect"
    printf '%s\n' "$out" | sed 's/^/    /'
    fail=$((fail + 1))
    return 1
  fi
  return 0
}

expect_in() {
  local name="$1" needle="$2"
  if [[ "$out" != *"$needle"* ]]; then
    echo "FAIL [$name]: output lacks: $needle"
    printf '%s\n' "$out" | sed 's/^/    /'
    fail=$((fail + 1))
    # Recorded, not returned: a non-zero last command of an && chain would
    # trip errexit and skip the tally below.
    return 0
  fi
  pass=$((pass + 1))
}

expect_not_in() {
  local name="$1" needle="$2"
  if [[ "$out" == *"$needle"* ]]; then
    echo "FAIL [$name]: output unexpectedly contains: $needle"
    printf '%s\n' "$out" | sed 's/^/    /'
    fail=$((fail + 1))
    # Recorded, not returned: a non-zero last command of an && chain would
    # trip errexit and skip the tally below.
    return 0
  fi
  pass=$((pass + 1))
}

good_netrc="$work/netrc-good"
printf 'machine 127.0.0.1\nlogin attic\npassword good-token\n' >"$good_netrc"
bad_netrc="$work/netrc-bad"
printf 'machine 127.0.0.1\nlogin attic\npassword revoked-token\n' >"$bad_netrc"
chmod 600 "$good_netrc" "$bad_netrc"

# 1. All healthy (trailing slash tolerated).
run healthy 0 SETUP_NIX_PROBE_SUBSTITUTERS="$base/ok/ $base/private" \
  SETUP_NIX_PROBE_NETRC="$good_netrc" SETUP_NIX_PROBE_TOKEN_SUPPLIED=true &&
  expect_in healthy "OK  $base/ok" && expect_in healthy "OK  $base/private" &&
  expect_not_in healthy "::warning" && expect_not_in healthy "::error"

# 2. The production shape: ACL 403 on the private cache, default warn mode.
run acl-warn 0 SETUP_NIX_PROBE_SUBSTITUTERS="$base/ok $base/acl" &&
  expect_in acl-warn "::warning title=Binary cache unusable::$base/acl" &&
  expect_in acl-warn "SOURCE ADDRESS is not in the allow-list" &&
  expect_in acl-warn "BUILT FROM SOURCE"

# 3. Same, fail mode: the job must stop here.
run acl-fail 1 SETUP_NIX_PROBE_MODE=fail SETUP_NIX_PROBE_SUBSTITUTERS="$base/ok $base/acl" &&
  expect_in acl-fail "::error title=Binary cache unusable::$base/acl" &&
  expect_in acl-fail "failing now rather than letting Nix build"

# 4. Private cache, no token passed: diagnosis names the missing input.
run no-token 1 SETUP_NIX_PROBE_MODE=fail SETUP_NIX_PROBE_SUBSTITUTERS="$base/private" &&
  expect_in no-token "no attic-token was passed"

# 5. Private cache, token passed but refused.
run bad-token 1 SETUP_NIX_PROBE_MODE=fail SETUP_NIX_PROBE_SUBSTITUTERS="$base/private" \
  SETUP_NIX_PROBE_NETRC="$bad_netrc" SETUP_NIX_PROBE_TOKEN_SUPPLIED=true &&
  expect_in bad-token "rejected the credential"

# 6. The upstream cache failing is fatal even in warn mode.
run upstream-down 1 SETUP_NIX_PROBE_UPSTREAM="http://127.0.0.1:$closed_port" \
  SETUP_NIX_PROBE_SUBSTITUTERS="http://127.0.0.1:$closed_port $base/ok" &&
  expect_in upstream-down "::error title=Binary cache unusable::http://127.0.0.1:$closed_port" &&
  expect_in upstream-down "unreachable after 2 attempt(s)" &&
  expect_in upstream-down "attempt 1/2" # transport errors ARE retried

# 7. 401/403 are NOT retried.
run no-retry-on-403 1 SETUP_NIX_PROBE_MODE=fail SETUP_NIX_PROBE_SUBSTITUTERS="$base/acl" &&
  expect_not_in no-retry-on-403 "retrying"

# 8. A 200 that is not a cache (captive portal) is not "OK".
run portal 1 SETUP_NIX_PROBE_MODE=fail SETUP_NIX_PROBE_SUBSTITUTERS="$base/portal" &&
  expect_in portal "not a nix-cache-info document"

# 9. Wrong cache name.
run missing 1 SETUP_NIX_PROBE_MODE=fail SETUP_NIX_PROBE_SUBSTITUTERS="$base/nope" &&
  expect_in missing "HTTP 404"

# 10. Non-HTTP substituters are skipped, not failed.
run non-http 0 SETUP_NIX_PROBE_SUBSTITUTERS="$base/ok s3://bucket file:///tmp/cache" &&
  expect_in non-http "skipping non-HTTP substituter s3://bucket"

# 11. off / invalid mode.
run off 0 SETUP_NIX_PROBE_MODE=off SETUP_NIX_PROBE_SUBSTITUTERS="$base/acl" &&
  expect_in off "disabled (mode=off)"
run bad-mode 1 SETUP_NIX_PROBE_MODE=sometimes SETUP_NIX_PROBE_SUBSTITUTERS="$base/ok" &&
  expect_in bad-mode "must be one of fail, warn, off"

# 12. Step summary gets a table row per cache.
summary_file="$work/summary.md"
run summary 0 GITHUB_STEP_SUMMARY="$summary_file" SETUP_NIX_PROBE_SUBSTITUTERS="$base/ok $base/acl" &&
  out="$(cat "$summary_file")" &&
  expect_in summary "| \`$base/ok\` | OK |" &&
  expect_in summary "| \`$base/acl\` | WARN — HTTP 403"

echo "probe-substituters-test: $pass assertion(s) passed, $fail failed"
[[ "$fail" -eq 0 ]]
