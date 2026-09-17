#!/usr/bin/env bash
# Gate `t_github_budget_enterprise` — ENTERPRISE-scope $0 cap.
#
# Proves the $0 budget engine (../actions-budgets.nix) can target an ENTERPRISE
# (not just an org): one budget resource per (enterprise, SKU), each an
# enterprise-scoped $0 hard stop on the /enterprises/<slug>/… collection with
# budget_entity_name pinned to the slug and the correct distinct
# budget_product_sku / budget_type across all FIVE capped SKUs (actions,
# packages, codespaces → ProductPricing; ai_credits → BundlePricing;
# git_lfs_storage → SkuPricing). AND that an org-scoped budget rendered in the
# same call stays organization-scoped with an empty entity_name — the two axes
# do not bleed.
#
# Offline: the engine is pure builtins, so `nix eval --json` renders it with no
# credentials, network, or provider plugins. Mirrors tests/test-budget-all-skus.sh.
set -euo pipefail
gate="t_github_budget_enterprise"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fail=0
err() { echo "FAIL[$gate]: $*" >&2; fail=1; }

json="$(nix eval --json --impure --expr "import ${here}/actions-budgets-enterprise/default.nix {}")"
res() { jq -c ".resource.restful_resource${1}" <<<"$json"; }

slug="schelling-point-labs"
pfx="schelling_point_labs_" # slug with '-' -> '_' (resource-label sanitizer)

# --- (1) the enterprise emits exactly FIVE uniquely named budgets -------------
ent_names="$(jq -r ".resource.restful_resource | keys[] | select(startswith(\"${pfx}\"))" <<<"$json" | sort)"
n_ent="$(wc -l <<<"$ent_names" | tr -d ' ')"
[[ "$n_ent" == "5" ]] || err "expected 5 enterprise budgets, got ${n_ent}: ${ent_names//$'\n'/,}"

want_names="schelling_point_labs_actions
schelling_point_labs_ai_credits
schelling_point_labs_codespaces
schelling_point_labs_git_lfs_storage
schelling_point_labs_packages"
[[ "$ent_names" == "$want_names" ]] || err "enterprise resource names wrong/not-unique: got [${ent_names//$'\n'/,}]"

# Total = 5 enterprise + 1 org. listToAttrs would collapse duplicate labels, so
# a length of 6 also proves no (entity,SKU) label collision.
n_total="$(jq '.resource.restful_resource | length' <<<"$json")"
[[ "$n_total" == "6" ]] || err "expected 6 total budget resources (5 enterprise + 1 org), got ${n_total}"

# --- (2) each enterprise budget is a $0 enterprise-scoped hard stop -----------
# name -> expected (sku, budget_type)
check_ent() {
  local name="$1" want_sku="$2" want_type="$3" r b
  r="$(res ".${name}")"
  b="$(jq -c '.body' <<<"$r")"
  [[ "$(jq -r '.path' <<<"$r")" == "/enterprises/${slug}/settings/billing/budgets" ]] \
    || err "${name}: path must be the enterprise collection, got $(jq -r '.path' <<<"$r")"
  [[ "$(jq -r '.read_path' <<<"$r")" == '$(path)/$(body.id)' ]] \
    || err "${name}: read_path must resolve the single budget under the collection"
  [[ "$(jq -r '.prevent_further_usage' <<<"$b")" == "true" ]] || err "${name}: prevent_further_usage must be true"
  [[ "$(jq -r '.budget_amount' <<<"$b")" == "0" ]] || err "${name}: budget_amount must be 0"
  [[ "$(jq -r '.budget_scope' <<<"$b")" == "enterprise" ]] || err "${name}: budget_scope must be enterprise"
  [[ "$(jq -r '.budget_entity_name' <<<"$b")" == "${slug}" ]] \
    || err "${name}: budget_entity_name must be the slug '${slug}' (immutable-field pin), got $(jq -r '.budget_entity_name' <<<"$b")"
  [[ "$(jq -r '.budget_product_sku' <<<"$b")" == "$want_sku" ]] || err "${name}: budget_product_sku must be ${want_sku}"
  [[ "$(jq -r '.budget_type' <<<"$b")" == "$want_type" ]] || err "${name}: budget_type must be ${want_type} (got $(jq -r '.budget_type' <<<"$b"))"
}
check_ent "${pfx}actions"         actions         ProductPricing
check_ent "${pfx}packages"        packages        ProductPricing
check_ent "${pfx}codespaces"      codespaces      ProductPricing
check_ent "${pfx}ai_credits"      ai_credits      BundlePricing   # metered bundle
check_ent "${pfx}git_lfs_storage" git_lfs_storage SkuPricing      # LFS leaf SKU

# The five SKUs are distinct.
distinct="$(jq -r ".resource.restful_resource | to_entries[] | select(.key|startswith(\"${pfx}\")) | .value.body.budget_product_sku" <<<"$json" | sort -u | wc -l | tr -d ' ')"
[[ "$distinct" == "5" ]] || err "the five enterprise budgets must carry distinct budget_product_sku values"

# There must be at least two distinct budget_type values across the five (i.e.
# the SKU->type mapping is not a constant) — non-tautological.
distinct_types="$(jq -r ".resource.restful_resource | to_entries[] | select(.key|startswith(\"${pfx}\")) | .value.body.budget_type" <<<"$json" | sort -u | wc -l | tr -d ' ')"
[[ "$distinct_types" == "3" ]] || err "expected 3 distinct budget_type values (ProductPricing/BundlePricing/SkuPricing), got ${distinct_types}"

# --- (3) scope isolation: the org-scoped budget stays organization/"" ----------
o="$(res ".example_org")"
[[ "$(jq -r '.path' <<<"$o")" == "/organizations/example-org/settings/billing/budgets" ]] \
  || err "org budget must use the /organizations/… collection"
[[ "$(jq -r '.body.budget_scope' <<<"$o")" == "organization" ]] || err "org budget must stay organization-scoped"
[[ "$(jq -r '.body.budget_entity_name' <<<"$o")" == "" ]] \
  || err "org budget budget_entity_name must stay \"\" by default (no bleed from the enterprise pin)"

if [[ "$fail" == "0" ]]; then
  echo "PASS: $gate (5 enterprise budgets on /enterprises/${slug}, entity=slug, types ProductPricing/BundlePricing/SkuPricing; org budget isolated)"
else
  exit 1
fi
