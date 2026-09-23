#!/usr/bin/env bash
# Contract tests for plan-destroy-guard. No credentials, network or tofu: every
# fixture is a hand-written `tofu show -json` document shaped like the real one.
#
# No mocks of the unit under test: the real script runs against each fixture.
# The fixtures stand in for tofu's JSON plan output because producing a plan
# with a destroy needs live provider state; the shapes used here (actions,
# address, type, before/after) are the documented JSON output format.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
guard="${PLAN_DESTROY_GUARD_SCRIPT:-${here}/../plan-destroy-guard}"
python="${PLAN_DESTROY_GUARD_PYTHON:-python3}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

# plan NAME <<JSON — write a fixture.
plan() { cat > "$tmp/$1.json"; }

# expect NAME EXIT [--authorized R] — run the guard and check its exit status.
expect() {
  local name="$1" want="$2"
  shift 2
  local got=0
  "$python" "$guard" "$tmp/$name.json" "$@" > "$tmp/$name.out" 2>&1 || got=$?
  if [[ "$got" != "$want" ]]; then
    fail "$name: exit $got, want $want"
    sed 's/^/    /' "$tmp/$name.out" >&2
  fi
}

# contains NAME TEXT — the guard's output for NAME must mention TEXT.
contains() {
  grep -qF -- "$2" "$tmp/$1.out" || fail "$1: output lacks '$2'"
}
lacks() {
  if grep -qF -- "$2" "$tmp/$1.out"; then fail "$1: output unexpectedly has '$2'"; fi
}

# --- Positive controls: nothing destructive -> apply proceeds ---------------
plan benign <<'JSON'
{"format_version":"1.2","resource_changes":[
 {"address":"a.x","mode":"managed","type":"a","change":{"actions":["no-op"]}},
 {"address":"a.y","mode":"managed","type":"a","change":{"actions":["create"],"after":{}}},
 {"address":"a.z","mode":"managed","type":"a","change":{"actions":["update"],"before":{},"after":{}}},
 {"address":"a.moved[0]","previous_address":"a.moved","mode":"managed","type":"a","change":{"actions":["no-op"]}},
 {"address":"data.a.d","mode":"data","type":"a","change":{"actions":["read"]}}
]}
JSON
expect benign 0
contains benign "no destroy or replace actions"

plan empty-changes <<'JSON'
{"format_version":"1.2"}
JSON
expect empty-changes 0

# --- The 2026-09-23 incident, replayed ---------------------------------------
# `count` added to a Cloudflare record with no `moved` block.
plan incident <<'JSON'
{"format_version":"1.2","resource_changes":[
 {"address":"cloudflare_dns_record.metacraft_identity","mode":"managed","type":"cloudflare_dns_record",
  "change":{"actions":["delete"],"before":{"zone_id":"z1","name":"login.metacraft-labs.com","type":"CNAME"},"after":null},
  "action_reason":"delete_because_count_index"},
 {"address":"cloudflare_dns_record.metacraft_identity[0]","mode":"managed","type":"cloudflare_dns_record",
  "change":{"actions":["create"],"before":null,"after":{"zone_id":"z1","name":"login","type":"CNAME"}}}
]}
JSON
expect incident 3
contains incident "unmoved-address"
contains incident "moved { from = cloudflare_dns_record.metacraft_identity to = cloudflare_dns_record.metacraft_identity[0] }"
contains incident "Refused."
contains incident "::error::"
# The create half is not reported as a separate destroy.
lacks incident '| `delete` |'

# The same plan, explicitly authorized: apply may proceed, findings still shown.
cp "$tmp/incident.json" "$tmp/incident-authorized.json"
expect incident-authorized 0 --authorized "workflow_dispatch allow_destroy=true by @someone"
contains incident-authorized "Authorized:"
contains incident-authorized "::warning::"
lacks incident-authorized "Refused."

# The same shape on a non-DNS type is recognised by address alone.
plan count-wrap <<'JSON'
{"format_version":"1.2","resource_changes":[
 {"address":"aws_iam_role.r","mode":"managed","type":"aws_iam_role","change":{"actions":["delete"],"before":{}}},
 {"address":"aws_iam_role.r[\"a\"]","mode":"managed","type":"aws_iam_role","change":{"actions":["create"],"after":{}}}
]}
JSON
expect count-wrap 3
contains count-wrap "same base address"

# --- A renamed DNS resource: different base address, same live record --------
plan dns-rename <<'JSON'
{"format_version":"1.2","resource_changes":[
 {"address":"cloudflare_record.old","mode":"managed","type":"cloudflare_record",
  "change":{"actions":["delete"],"before":{"zone_id":"z1","name":"www.example.com","type":"A"}}},
 {"address":"cloudflare_record.new","mode":"managed","type":"cloudflare_record",
  "change":{"actions":["create"],"after":{"zone_id":"z1","name":"www","type":"A"}}}
]}
JSON
expect dns-rename 3
contains dns-rename "unmoved-address"
contains dns-rename "same DNS record"

# Negative control for the pairing: a different record NAME is a real delete.
plan dns-different <<'JSON'
{"format_version":"1.2","resource_changes":[
 {"address":"cloudflare_record.old","mode":"managed","type":"cloudflare_record",
  "change":{"actions":["delete"],"before":{"zone_id":"z1","name":"www.example.com","type":"A"}}},
 {"address":"cloudflare_record.new","mode":"managed","type":"cloudflare_record",
  "change":{"actions":["create"],"after":{"zone_id":"z1","name":"wwwx","type":"A"}}}
]}
JSON
expect dns-different 3
contains dns-different '| `delete` | `cloudflare_record.old`'
lacks dns-different "unmoved-address"

# ...and so is the same name with a different record TYPE (A vs AAAA coexist).
plan dns-other-type <<'JSON'
{"format_version":"1.2","resource_changes":[
 {"address":"cloudflare_record.old","mode":"managed","type":"cloudflare_record",
  "change":{"actions":["delete"],"before":{"zone_id":"z1","name":"www.example.com","type":"A"}}},
 {"address":"cloudflare_record.new","mode":"managed","type":"cloudflare_record",
  "change":{"actions":["create"],"after":{"zone_id":"z1","name":"www","type":"AAAA"}}}
]}
JSON
expect dns-other-type 3
lacks dns-other-type "unmoved-address"

# --- In-place replaces -------------------------------------------------------
plan dns-replace <<'JSON'
{"format_version":"1.2","resource_changes":[
 {"address":"cloudflare_dns_record.login","mode":"managed","type":"cloudflare_dns_record",
  "change":{"actions":["delete","create"],"before":{"zone_id":"z1","name":"login","type":"A"},"after":{"zone_id":"z1","name":"login","type":"CNAME"}}}
]}
JSON
expect dns-replace 3
contains dns-replace "dns-replace"
contains dns-replace "destroy-before-create"
contains dns-replace "Same-name DNS record replacement"

plan generic-replace <<'JSON'
{"format_version":"1.2","resource_changes":[
 {"address":"aws_instance.web","mode":"managed","type":"aws_instance",
  "change":{"actions":["create","delete"],"before":{},"after":{}}}
]}
JSON
expect generic-replace 3
contains generic-replace '| `replace` | `aws_instance.web` | create-before-destroy |'

# --- A plain destroy of an unrelated resource ---------------------------------
plan pure-delete <<'JSON'
{"format_version":"1.2","resource_changes":[
 {"address":"module.m.aws_s3_bucket.b","mode":"managed","type":"aws_s3_bucket","change":{"actions":["delete"],"before":{}}},
 {"address":"module.m.aws_iam_role.r","mode":"managed","type":"aws_iam_role","change":{"actions":["create"],"after":{}}}
]}
JSON
expect pure-delete 3
contains pure-delete '| `delete` | `module.m.aws_s3_bucket.b`'
lacks pure-delete "unmoved-address"

# --- Fail closed on anything that is not a plan -------------------------------
printf '{}' > "$tmp/not-a-plan.json"
expect not-a-plan 2
printf 'not json' > "$tmp/garbage.json"
expect garbage 2
expect missing-file 2

# --- The summary file receives the report ------------------------------------
: > "$tmp/summary.md"
"$python" "$guard" "$tmp/incident.json" --summary "$tmp/summary.md" > /dev/null 2>&1 || true
grep -qF "Destructive changes in this plan" "$tmp/summary.md" || fail "summary: report not appended"

if ((failures > 0)); then
  echo "plan-destroy-guard tests: ${failures} failure(s)" >&2
  exit 1
fi
echo "plan-destroy-guard tests: all passed"
