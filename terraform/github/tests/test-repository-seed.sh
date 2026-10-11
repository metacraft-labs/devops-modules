#!/usr/bin/env bash
# Gate for Terraform-only repository creation (`seed`, README "Creating a
# repository with Terraform alone"; Sovereign-CI-Fleet milestone O6).
#
# Proves, offline and with no credentials:
#   1. golden/no-diff: an unseeded model renders no terraform_data and no
#      depends_on, and adding a seeded repository leaves every resource of the
#      existing repository byte-identical;
#   2. ordering: every resource naming the seeded repository (by `repository`
#      or by the `repository_id` node reference) depends on the seed, and the
#      plan graph carries the edge github_branch_default -> terraform_data;
#   3. the seed never names `main`, and the repository uses neither auto_init
#      nor template;
#   4. a mock-provider `tofu test` apply runs the REAL provisioner, which pushes
#      to a local bare repository: afterwards it holds exactly refs/heads/dev
#      (no main), and re-running the seed script is a no-op;
#   5. eval refuses a seed without an author and a seed on an archived repo.
#
# Mock justification: see repository-seed/seed.tftest.hcl (github provider
# only; git, the filesystem and the provisioner are real).
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
src="${here}/repository-seed"
fail=0

render() { nix eval --json --impure --expr "import ${src}/model.nix { $1 }"; }

seeded="$(render "")"
unseeded="$(render "withNewRepository = false;")"
# shellcheck disable=SC2034 # read through ${!name} below
example="$(nix eval --json --impure --expr "import ${here}/../governance.example.nix")"

# --- 1. golden / no-diff ------------------------------------------------------
for name in unseeded example; do
  json="${!name}"
  [[ "$(jq '.resource | has("terraform_data")' <<<"$json")" == "false" ]] \
    || { echo "FAIL: ${name} render must not contain terraform_data"; fail=1; }
  [[ "$(jq '[.resource[][] | select(has("depends_on"))] | length' <<<"$json")" == "0" ]] \
    || { echo "FAIL: ${name} render must not add depends_on anywhere"; fail=1; }
done
# Every resource of the existing repository, in both renders, compared as JSON.
infra_only='[.resource | to_entries[] | .key as $t | .value | to_entries[]
  | select((.value.repository? == "infra") or (.value.name? == "infra" and $t == "github_repository"))
  | {t: $t, k: .key, v: .value}] | sort_by(.t, .k)'
if ! diff <(jq -S "$infra_only" <<<"$unseeded") <(jq -S "$infra_only" <<<"$seeded") >/dev/null; then
  echo "FAIL: adding a seeded repository changed the existing repository's resources"; fail=1
fi
[[ "$(jq "$infra_only | length" <<<"$seeded")" -ge 5 ]] \
  || { echo "FAIL: golden comparison covers too few infra resources"; fail=1; }

# --- 2. ordering in the render ------------------------------------------------
dep='terraform_data.seed_new_tool'
for addr in github_branch_default.branch_default_new_tool \
  github_repository_ruleset.repository_ruleset_new_tool_no_main_branch \
  github_branch_protection.branch_protection_new_tool_dev \
  github_team_repository.team_repository_infra_new_tool \
  github_repository_vulnerability_alerts.vulnerability_alerts_new_tool; do
  t="${addr%%.*}" k="${addr#*.}"
  jq -e --arg t "$t" --arg k "$k" --arg d "$dep" '.resource[$t][$k].depends_on | index($d) != null' \
    <<<"$seeded" >/dev/null || { echo "FAIL: ${addr} must depend on ${dep}"; fail=1; }
done
[[ "$(jq '[.resource[][] | select(.depends_on? and (.repository? == "infra"))] | length' <<<"$seeded")" == "0" ]] \
  || { echo "FAIL: an infra resource was ordered after a seed"; fail=1; }
[[ "$(jq -r '.resource.terraform_data.seed_new_tool.triggers_replace[0]' <<<"$seeded")" == '${github_repository.repo_new_tool.node_id}' ]] \
  || { echo "FAIL: the seed must reference the repository it seeds"; fail=1; }

# --- 3. never `main`; no auto_init / template ---------------------------------
if jq -c '.resource.terraform_data.seed_new_tool' <<<"$seeded" | grep -qw main; then
  echo "FAIL: the seed resource mentions main"; fail=1
fi
[[ "$(jq '.resource.github_repository.repo_new_tool | has("auto_init") or has("template") or has("default_branch")' <<<"$seeded")" == "false" ]] \
  || { echo "FAIL: seeded repository must not set auto_init/template/default_branch"; fail=1; }

# --- 5. eval-time refusals ----------------------------------------------------
refused() { # $1 = model args, $2 = expected message fragment
  local err
  if err="$(render "$1" 2>&1 >/dev/null)"; then
    echo "FAIL: render with { $1 } must be refused"; fail=1
  elif ! grep -q "$2" <<<"$err"; then
    echo "FAIL: render with { $1 } refused for the wrong reason:"; echo "$err"; fail=1
  fi
}
refused 'seed = { authorName = "x"; };' "seed needs authorName and authorEmail"
refused 'archived = true;' "an archived repository cannot be seeded"

[[ "$fail" == 0 ]] || exit 1

# --- 2b + 4. plan graph edge, then a mock-provider apply with a real push -----
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# The engine declares an (empty) s3 backend for the real root; an offline graph
# and test need local state, so the copy under test drops it.
terranix "${src}/default.nix" | jq 'del(.terraform.backend)' >"${work}/config.tf.json"
cp "${src}"/*.tftest.hcl "${work}/"
git init -q --bare "${work}/remote.git"
(
  cd "$work"
  tofu init -input=false -backend=false >/dev/null
  tofu graph -type=plan >graph.dot
)
edge() { grep -qF "\"[root] $1 (expand)\" -> \"[root] $2 (expand)\"" "${work}/graph.dot" \
  || { echo "FAIL: plan graph lacks the edge $1 -> $2"; exit 1; }; }
edge github_branch_default.branch_default_new_tool terraform_data.seed_new_tool
edge github_repository_ruleset.repository_ruleset_new_tool_no_main_branch terraform_data.seed_new_tool
edge terraform_data.seed_new_tool github_repository.repo_new_tool

( cd "$work" && GOVERNANCE_SEED_REMOTE="${work}/remote.git" tofu test )

refs="$(git -C "${work}/remote.git" for-each-ref --format='%(refname)')"
[[ "$refs" == "refs/heads/dev" ]] \
  || { echo "FAIL: after apply the remote must hold exactly refs/heads/dev, got: ${refs}"; exit 1; }
[[ "$(git -C "${work}/remote.git" log -1 --format='%an <%ae>|%s' dev)" == "Example Operator <operator@example.invalid>|Initial commit" ]] \
  || { echo "FAIL: seed commit identity/message not carried through"; exit 1; }
git -C "${work}/remote.git" show dev:README.md | grep -q '^# new-tool$' \
  || { echo "FAIL: seed README missing"; exit 1; }

# Idempotency: re-run the rendered script against the now-seeded remote.
script="$(jq -r '.resource.terraform_data.seed_new_tool.provisioner[0]["local-exec"].command' "${work}/config.tf.json")"
envs=()
while IFS= read -r kv; do envs+=("$kv"); done < <(jq -r \
  '.resource.terraform_data.seed_new_tool.provisioner[0]["local-exec"].environment | to_entries[] | select(.key != "SEED_README") | "\(.key)=\(.value)"' \
  "${work}/config.tf.json")
before="$(git -C "${work}/remote.git" rev-parse dev)"
out="$(env "${envs[@]}" SEED_README=x GOVERNANCE_SEED_REMOTE="${work}/remote.git" bash -c "$script")"
grep -q "already has dev; nothing to do" <<<"$out" || { echo "FAIL: re-run was not a no-op: ${out}"; exit 1; }
[[ "$(git -C "${work}/remote.git" rev-parse dev)" == "$before" ]] || { echo "FAIL: re-run moved dev"; exit 1; }

# A repository with other branches but no mainline is refused, not pushed to.
git init -q --bare "${work}/other.git"
git -C "${work}/remote.git" push -q "${work}/other.git" dev:refs/heads/topic
if env "${envs[@]}" SEED_README=x GOVERNANCE_SEED_REMOTE="${work}/other.git" bash -c "$script" 2>/dev/null; then
  echo "FAIL: seeding a non-empty repository without the mainline must fail"; exit 1
fi
[[ "$(git -C "${work}/other.git" for-each-ref --format='%(refname)')" == "refs/heads/topic" ]] \
  || { echo "FAIL: refused seed still pushed"; exit 1; }

echo "PASS: repository seed"
