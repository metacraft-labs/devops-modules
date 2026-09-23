#!/usr/bin/env bash
# fallback-semantics-test.sh — what Nix's `fallback` setting ACTUALLY does,
# pinned against the real `nix` on PATH (no mocks), so the `fallback` input of
# setup-nix is documented by evidence rather than by belief.
#
# A local HTTP origin plays a binary cache; a trivial derivation that is in NO
# cache is built into a throwaway chroot store with that cache as its only
# substituter:
#
#   narinfo answer | fallback=true        | fallback=false
#   ---------------+----------------------+-------------------------------
#   404 (a miss)   | built locally        | built locally
#   502 (an error) | built locally (cache | FAILS — the substituter error is
#                  |  disabled 60s)       |  rethrown even though the path
#                  |                      |  is in no cache
#
# The second row is why setup-nix keeps `fallback = true` by default and makes
# `false` an explicit opt-in: with `false`, an Attic 500 burst fails the job.
#
# Needs: nix (any 2.2x+), python3, bash. Runs unprivileged (chroot store).
set -euo pipefail

command -v nix >/dev/null || {
  echo "fallback-semantics-test: SKIP (nix not on PATH)"
  exit 0
}

work="$(mktemp -d)"
server_pid=""
cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
  chmod -R u+w "$work" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

cat >"$work/origin.py" <<'PY'
import sys
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
NARINFO_STATUS = int(sys.argv[1])
class H(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
    def do_GET(self):
        if self.path == "/nix-cache-info":
            return self.reply(200, "StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 10\n")
        return self.reply(NARINFO_STATUS, "origin says %d" % NARINFO_STATUS)
    do_HEAD = do_GET
    def log_message(self, *a):
        pass
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY

# A derivation no cache can have: its output depends on this run's nonce.
cat >"$work/drv.nix" <<EOF
derivation {
  name = "fallback-semantics-$RANDOM$RANDOM";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = [ "-c" "echo built > \$out" ];
}
EOF

pass=0
fail=0

start_origin() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null || true
  rm -f "$work/port"
  python3 "$work/origin.py" "$1" >"$work/port" &
  server_pid=$!
  for _ in $(seq 1 50); do [[ -s "$work/port" ]] && break; sleep 0.1; done
  port="$(cat "$work/port")"
}

# case <narinfo-status> <fallback> <expected: built|fails>
case_() {
  local status="$1" fallback="$2" expect="$3" rc=0 store="$work/store-$1-$2"
  start_origin "$status"
  nix-build "$work/drv.nix" --no-out-link \
    --store "local?root=$store" \
    --option substituters "http://127.0.0.1:$port" \
    --option trusted-substituters "" \
    --option require-sigs false \
    --option sandbox false \
    --option fallback "$fallback" \
    --option download-attempts 1 \
    --option narinfo-cache-negative-ttl 0 \
    --option narinfo-cache-positive-ttl 0 \
    >"$work/log-$1-$2" 2>&1 || rc=$?
  local got=built
  [[ "$rc" -eq 0 ]] || got=fails
  if [[ "$got" == "$expect" ]]; then
    echo "ok   narinfo $status, fallback=$fallback -> $got"
    pass=$((pass + 1))
  else
    echo "FAIL narinfo $status, fallback=$fallback -> $got (expected $expect)"
    sed 's/^/    /' "$work/log-$1-$2" | tail -15
    fail=$((fail + 1))
  fi
}

echo "fallback-semantics-test: $(nix --version)"
case_ 404 true built
case_ 404 false built
case_ 502 true built
case_ 502 false fails

echo "fallback-semantics-test: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
