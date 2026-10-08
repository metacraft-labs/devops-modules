#!/usr/bin/env bash
# Contract tests for github-app-rate-budget. No credentials or network: most
# fixtures are saved `GET /rate_limit` responses read through --from-file. The
# header probe is exercised against a loopback HTTP server that answers the way
# api.github.com documents (X-RateLimit-* headers on a counted request, 404 for
# a non-installation token). It stands in for GitHub because CI has no App
# token; the unit under test runs unmodified.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
script="${GITHUB_APP_RATE_BUDGET_SCRIPT:-${here}/../github-app-rate-budget}"
python="${GITHUB_APP_RATE_BUDGET_PYTHON:-python3}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}
run() { GITHUB_STEP_SUMMARY="$tmp/summary" "$python" "$script" "$@"; }

resp() { # name used remaining reset
  printf '{"resources":{"core":{"limit":12500,"used":%s,"remaining":%s,"reset":%s}},"rate":{"limit":12500,"used":%s,"remaining":%s,"reset":%s}}' \
    "$2" "$3" "$4" "$2" "$3" "$4" >"$tmp/$1.json"
}

resp before 1000 11500 1790900000
resp after 5900 6600 1790900000
resp rolled 300 12200 1790903600

out="$(run --label before --save "$tmp/saved" --from-file "$tmp/before.json")"
grep -q 'limit=12500 used=1000 remaining=11500' <<<"$out" || fail "before reading not printed: $out"
[ -s "$tmp/saved" ] || fail "reading not saved"

out="$(run --label after --since "$tmp/saved" --from-file "$tmp/after.json")"
grep -q 'consumed since the earlier reading: 4900$' <<<"$out" || fail "same-window delta wrong: $out"

out="$(run --label after --since "$tmp/saved" --from-file "$tmp/rolled.json")"
grep -q '>= 300 (the hourly window reset in between)' <<<"$out" || fail "rolled-window delta wrong: $out"

grep -q 'used=5900' "$tmp/summary" || fail "step summary not written"

# Never fails the job: malformed input and a missing token are warnings.
echo '{"resources":{}}' >"$tmp/bad.json"
run --from-file "$tmp/bad.json" >"$tmp/bad.out" || fail "malformed response failed the step"
grep -q '::warning::' "$tmp/bad.out" || fail "malformed response not reported"
GITHUB_TOKEN='' run >"$tmp/notoken.out" || fail "missing token failed the step"
grep -q 'GITHUB_TOKEN is empty' "$tmp/notoken.out" || fail "missing token not reported"


# Header probe: the reading comes from the counted request's X-RateLimit-*
# headers, and falls back to /rate_limit when the probe is refused.
port_file="$tmp/port"
"$python" - "$port_file" <<'PY' &
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/ok/installation/repositories"):
            self.send_response(200)
            for k, v in (("Limit", "12500"), ("Used", "2601"), ("Remaining", "9899"), ("Reset", "1790903600"), ("Resource", "core")):
                self.send_header(f"X-RateLimit-{k}", v)
            self.end_headers(); self.wfile.write(b'{"total_count":1,"repositories":[]}')
        elif self.path.startswith("/pat/installation/repositories"):
            self.send_response(403); self.end_headers(); self.wfile.write(b"{}")
        elif self.path == "/pat/rate_limit":
            body = json.dumps({"resources": {"core": {"limit": 5000, "used": 7, "remaining": 4993, "reset": 1790903600}}}).encode()
            self.send_response(200); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
for _ in $(seq 1 50); do [ -s "$port_file" ] && break; sleep 0.1; done
port="$(cat "$port_file")"
out="$(GITHUB_TOKEN=x run --label probe --api-url "http://127.0.0.1:$port/ok")"
grep -q 'used=2601 remaining=9899' <<<"$out" || fail "header probe not used: $out"
grep -q 'from headers (core)' <<<"$out" || fail "header source not reported: $out"
out="$(GITHUB_TOKEN=x run --label probe --api-url "http://127.0.0.1:$port/pat")"
grep -q 'limit=5000 used=7' <<<"$out" || fail "/rate_limit fallback not used: $out"
grep -q 'from /rate_limit' <<<"$out" || fail "fallback source not reported: $out"

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "github-app-rate-budget: all tests passed"
