#!/usr/bin/env bash
# Contract tests for github-app-rate-budget. No credentials or network: each
# fixture is a saved `GET /rate_limit` response in the documented shape, read
# through --from-file. No mocks of the unit under test.
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

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)" >&2
  exit 1
fi
echo "github-app-rate-budget: all tests passed"
