{ ... }:
# Offline gate fixture for the ENTERPRISE-scope $0 cap: the budget engine must
# emit enterprise-scoped budgets (budget_scope="enterprise",
# path=/enterprises/<slug>/…, budget_entity_name=<slug>) across ALL FIVE capped
# SKUs, each with the correct budget_type — while org-scoped callers are
# untouched. This mirrors the schelling-point-labs enterprise root in infra.
#
# One enterprise, five SKUs, one render:
#   * example-ent — productSkus = actions + packages + codespaces + ai_credits +
#     git_lfs_storage → five uniquely named enterprise budget resources with,
#     respectively, ProductPricing / ProductPricing / ProductPricing /
#     BundlePricing / SkuPricing budget types.
#
# A single org-scoped budget is included alongside to assert the two scopes do
# not bleed into each other (org keeps path=/organizations/… and
# budget_entity_name="" by default).
#
# No credentials, no network; the engine is pure builtins so `nix eval --json`
# renders it directly. useS3Backend = false keeps the render backend-less.
import ../../actions-budgets.nix {
  useS3Backend = false;
  enterprises = {
    # The full $0-everywhere shape for an enterprise. Exactly FIVE SKUs so the
    # gate can assert "five enterprise budgets, distinct SKUs, correct types".
    "schelling-point-labs" = {
      productSkus = [
        "actions" # minutes + actions storage/cache   (ProductPricing)
        "packages" # Packages storage + bandwidth       (ProductPricing)
        "codespaces" # Codespaces compute + storage       (ProductPricing)
        "ai_credits" # Copilot / Models metered credits   (BundlePricing)
        "git_lfs_storage" # Git LFS storage, a leaf SKU        (SkuPricing)
      ];
    };
  };
  # An org-scoped budget rendered in the SAME call: it must stay organization
  # scoped with an empty entity_name, proving the enterprise axis is isolated.
  budgets = {
    "example-org" = {
      id = "852e9d35-0000-0000-0000-000000000000";
    };
  };
}
