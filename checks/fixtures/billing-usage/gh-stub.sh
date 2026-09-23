# Stub `gh` for the hermetic runner-mode gates (t_runner_mode_manager,
# t_runner_mode_switch, t_private_repo_hybrid_fallback). The gates prepend a
# `#!<bash>` line and install it as the ONLY `gh` on PATH under `env -i`, so a
# regression that reached the network fails instead of passing.
#
# It serves the enhanced-billing usage report from a fixture CAPTURED LIVE
# (2026-09 month-to-date via the local operator token; org and repo names
# anonymized to example-org / <visibility>-repo-NNN, no IDs or tokens) and
# mimics GitHub's real failure shapes, including the HTTP 410 the classic
# /orgs/{org}/settings/billing/actions endpoint now returns (gh prints the JSON
# error body to stdout, the message to stderr, and exits 1).
#
# Env knobs:
#   FIXTURES            directory holding the fixture files (required)
#   MOCK_USAGE          usage-report fixture file name (in FIXTURES)
#   MOCK_UNTIL          keep only usage rows dated <= this YYYY-MM-DD
#   MOCK_EXPECT_SCOPE   org | enterprise — the usage endpoint that MUST be hit
#   MOCK_PLAN           plan.name for GET /orgs/{org} (default team)
#   MOCK_INJECT_SKU / MOCK_INJECT_UNIT / MOCK_INJECT_NET
#                       append one synthetic private-repo row billed MOCK_INJECT_NET USD
#   MOCK_FAIL           every call fails (unreachable API)
#   MOCK_USAGE_410      the usage endpoint answers HTTP 410
#   MOCK_OLD_SHAPE      the usage endpoint answers 200 with the OLD classic body
#   MOCK_FAIL_REPOS     the public-repo listing fails
set -uo pipefail

gone() {
  printf '{"message":"This endpoint has been moved.","documentation_url":"https://gh.io/billing-api-updates-org","status":"410"}'
  echo "gh: This endpoint has been moved. (HTTP 410)" >&2
  exit 1
}

if [ -n "${MOCK_FAIL:-}" ]; then
  echo "gh: simulated billing API failure (connection refused)" >&2
  exit 1
fi

[ "${1:-}" = "api" ] || { echo "gh-stub: unexpected command: $*" >&2; exit 2; }
shift
jqexpr=""
path=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jqexpr="$2"; shift 2 ;;
    -H) shift 2 ;;
    --paginate) shift ;;
    -*) echo "gh-stub: unexpected flag $1" >&2; exit 2 ;;
    *) path="$1"; shift ;;
  esac
done

usage_body() {
  case "$path" in
    *year=*month=*) ;;
    *) echo "gh-stub: usage call without year/month: $path" >&2; exit 3 ;;
  esac
  [ -n "${MOCK_USAGE_410:-}" ] && gone
  if [ -n "${MOCK_OLD_SHAPE:-}" ]; then
    printf '{"total_minutes_used":100,"total_paid_minutes_used":0,"included_minutes":3000}'
    return
  fi
  jq -c --arg until "${MOCK_UNTIL:-9999-12-31}" \
    --arg sku "${MOCK_INJECT_SKU:-}" --arg unit "${MOCK_INJECT_UNIT:-Minutes}" \
    --argjson net "${MOCK_INJECT_NET:-0}" '
    .usageItems |= map(select(.date[0:10] <= $until))
    | if $sku == "" then . else .usageItems += [{
        date: "2026-09-02T00:00:00Z", product: "actions", sku: $sku,
        quantity: 1, unitType: $unit, pricePerUnit: $net, grossAmount: $net,
        discountAmount: 0, netAmount: $net,
        organizationName: (.usageItems[0].organizationName),
        repositoryName: "private-repo-injected"}] end' \
    "$FIXTURES/$MOCK_USAGE"
}

case "$path" in
  /orgs/*/settings/billing/actions) gone ;;
  /organizations/*/settings/billing/usage\?*)
    [ "${MOCK_EXPECT_SCOPE:-org}" = "org" ] \
      || { echo "gh-stub: org usage read but scope should be ${MOCK_EXPECT_SCOPE}" >&2; exit 3; }
    body="$(usage_body)" || { rc=$?; printf "%s" "$body"; exit "$rc"; } ;;
  /enterprises/*/settings/billing/usage\?*)
    [ "${MOCK_EXPECT_SCOPE:-org}" = "enterprise" ] \
      || { echo "gh-stub: enterprise usage read but scope should be ${MOCK_EXPECT_SCOPE:-org}" >&2; exit 3; }
    body="$(usage_body)" || { rc=$?; printf "%s" "$body"; exit "$rc"; } ;;
  /orgs/*/repos\?type=public*)
    [ -n "${MOCK_FAIL_REPOS:-}" ] && { echo "gh: HTTP 502 listing repos" >&2; exit 1; }
    o="${path#/orgs/}"; o="${o%%/*}"
    if [ -f "$FIXTURES/public-repos-$o.json" ]; then
      body="$(cat "$FIXTURES/public-repos-$o.json")"
    else
      body='[]'
    fi ;;
  /orgs/*/*) echo "gh-stub: unexpected call: $path" >&2; exit 2 ;;
  /orgs/*)
    o="${path#/orgs/}"
    body="$(jq -cn --arg o "$o" --arg p "${MOCK_PLAN:-team}" '{login: $o, plan: {name: $p}}')" ;;
  *) echo "gh-stub: unexpected call: $path" >&2; exit 2 ;;
esac

if [ -n "$jqexpr" ]; then
  printf '%s' "$body" | jq -r "$jqexpr"
else
  printf '%s\n' "$body"
fi
