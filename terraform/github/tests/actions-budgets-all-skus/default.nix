{ ... }:
# Offline gate fixture for milestone B2 (Sovereign-CI-Fleet): the $0 budget
# engine must extend the prevent_further_usage cap beyond Actions minutes to
# storage/Packages AND Git LFS, emitting one budget resource per (org, SKU) —
# while a legacy single-SKU caller still renders exactly one actions budget,
# byte-for-byte as before.
#
# Two orgs, one render:
#   * example-multi  — productSkus = actions + packages (storage) + git_lfs_*
#     → three (four with the second LFS SKU) uniquely named budget resources.
#   * example-legacy — the legacy { id; } shape → exactly one org-named actions
#     budget, unchanged.
#
# No credentials, no network; the engine is pure builtins so `nix eval --json`
# renders it directly. useS3Backend = false keeps the render backend-less.
import ../../actions-budgets.nix {
  useS3Backend = false;
  budgets = {
    # Multi-SKU org: the full $0-everywhere shape. Exactly THREE SKUs so the
    # gate can assert "three budgets, distinct SKUs": actions (minutes + actions
    # storage/cache), packages (Packages storage/bandwidth), git_lfs_storage
    # (Git LFS storage, a leaf SKU → SkuPricing).
    "example-multi" = {
      productSkus = [
        "actions"
        "packages"
        "git_lfs_storage"
      ];
    };

    # Legacy single-SKU caller: the pre-B2 shape must render identically.
    "example-legacy" = {
      id = "852e9d35-0000-0000-0000-000000000000";
    };
  };
}
