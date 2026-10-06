#!/usr/bin/env bash
# Negative control for the collaborator-affiliation defect.
#
# `GET /repos/{o}/{r}/collaborators?affiliation=all` returns EFFECTIVE access:
# direct grants plus team-derived plus organization-owner-derived. A
# `github_repository_collaborator` resource is a DIRECT grant and nothing else.
# An adoption transform that reads the `all` response as if it were direct
# invents collaborator rows for access that is really a team grant:
#
#   * the rows cannot be imported, because no direct collaboration exists, so
#     the import phase fails on them; and
#   * had they been created instead, removing someone from a team would no
#     longer revoke their access, which defeats team-based revocation entirely.
#
# metacraft-labs hit exactly this: 480 phantom rows derived from `all`, against
# 14 real direct grants. This test pins the shape of the fix so a future edit
# cannot quietly reintroduce it.
#
# Offline: greps the inventory script. No credentials, no network.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
tool="${here}/../github-inventory"
fail=0

# The file the adoption transform reads for direct grants must be fetched with
# affiliation=direct.
if ! grep -q 'collaborators?affiliation=direct.*repo-collaborators-\${safe}\.json' "$tool"; then
  echo "FAIL: repo-collaborators-*.json must be fetched with affiliation=direct"
  fail=1
fi

# affiliation=all may still be captured — it is genuinely useful for auditing
# effective access — but never under the name the transform reads.
if grep -q 'collaborators?affiliation=all.*repo-collaborators-\${safe}\.json' "$tool"; then
  echo "FAIL: affiliation=all must not be written to repo-collaborators-*.json (it is effective access, not direct grants)"
  fail=1
fi

if grep -q 'affiliation=all' "$tool" && ! grep -q 'affiliation=all.*repo-effective-access-' "$tool"; then
  echo "FAIL: affiliation=all must land in repo-effective-access-*.json so it cannot be mistaken for a resource inventory"
  fail=1
fi

# The inventory report must say which affiliation a collaborator row came from,
# so a reviewer can tell the two apart without reading the script.
if ! grep -q 'github_repository_collaborator .*affiliation=direct' "$tool"; then
  echo "FAIL: the github_repository_collaborator inventory row must record affiliation=direct"
  fail=1
fi

if [[ "$fail" == 0 ]]; then
  echo "OK: collaborator inventory is derived from affiliation=direct"
else
  exit 1
fi
