# Reusable, company-agnostic Terraform (terranix) engine that brings an
# organization's GitHub Actions spending BUDGET under management.
#
# WHY THIS EXISTS: the `integrations/github` provider has NO budget /
# spending-limit resource, and GitHub's legacy "spending limit" API was
# replaced by the Budgets subsystem on the enhanced billing platform. Budgets
# are therefore managed through the GitHub Budgets REST API
# (`/organizations/{org}/settings/billing/budgets`, header
# `X-GitHub-Api-Version: 2026-03-10`) driven from Terraform via the third-party
# `magodo/restful` provider, which gives a real CRUD lifecycle + drift
# detection + import (unlike a `null_resource`/curl shim).
#
# This module is GENERAL: no company/org names, tokens, or budget IDs are baked
# in. A concrete consumer (e.g. infra's `terraform/github-budgets/<env>`) calls
# it with the org->budget map and the name of the terraform variable that
# carries a billing-scoped token. Same toolkit-vs-policy split the other shared
# terraform engines use (see actions-secrets.nix).
#
# USAGE (from a concrete terranix root):
#
#   { ... }:
#   import "${nixos-modules}/terraform/github/actions-budgets.nix" {
#     budgets = {
#       "metacraft-labs"     = { id = "852e9d35-…"; };   # existing → import
#       "blocksense-network" = { id = "fc1603e0-…"; };   # existing → import
#       "agent-harbor"       = { id = null;         };   # create once migrated
#     };
#   }
#
# ALL-SKU $0 CAP (milestone B2). A single Actions-only budget stops paid Actions
# MINUTES but leaves artifact/cache/Packages storage and Git LFS to leak spend.
# To hard-stop those too, give an org a list of SKUs via `productSkus` — one
# budget resource is emitted per (org, SKU). The exact GitHub Budgets product /
# SKU strings (source: docs.github.com/en/billing/reference/product-and-sku-names
# and the Budgets REST reference) are:
#
#   * budget_type = "ProductPricing" caps EVERY child SKU of a product. The only
#     documented products are "actions" (covers actions_linux/…/actions_storage/
#     actions_cache_storage) and "packages" (covers packages_storage/
#     packages_bandwidth). So actions-storage/cache is already inside "actions";
#     "packages" adds the Packages storage/bandwidth dimension.
#   * Git LFS has NO product identifier — its spend lives only in the leaf SKUs
#     "git_lfs_storage" and "git_lfs_bandwidth", which must be budgeted with
#     budget_type = "SkuPricing". There is NO "shared_storage"/"storage"/
#     "git_lfs" product; those are not valid budget_product_sku values.
#
# So the $0-everywhere shape for an org is:
#
#   "agent-harbor" = {
#     productSkus = [
#       "actions"            # minutes + actions_storage + actions_cache_storage
#       "packages"           # Packages storage + bandwidth
#       "git_lfs_storage"    # Git LFS storage      (SkuPricing, auto-detected)
#       "git_lfs_bandwidth"  # Git LFS bandwidth    (SkuPricing, auto-detected)
#     ];
#   };
#
# Each SKU entry may instead be an attrset carrying its own existing-budget id
# (for import of a pre-existing budget) and/or per-SKU overrides:
#
#     productSkus = [
#       { sku = "actions"; id = "852e9d35-…"; }   # existing → import
#       { sku = "packages"; }                     # create (id defaults to null)
#       "git_lfs_storage"                         # bare string == { sku = …; }
#     ];
#
# `budgetType` is inferred (git_lfs* → SkuPricing, ai_credits → BundlePricing,
# else ProductPricing) but can be set explicitly per entry. Omitting
# `productSkus` keeps the legacy single-SKU shape (`{ id; amount?; productSku? }`)
# and renders byte-for-byte as before: one org-named resource on the "actions"
# product.
#
# ENTERPRISE SCOPE. Some GitHub billing lives on an ENTERPRISE, not an org: two
# enterprise-plan orgs that share one enterprise pool their spend, so an
# org-scoped cap is not the authoritative ceiling — the enterprise budget is.
# Pass `enterprises` (same value shape as `budgets`, keyed by enterprise slug) to
# emit enterprise-scoped budgets:
#
#   * `budget_scope       = "enterprise"`,
#   * `path               = /enterprises/{slug}/settings/billing/budgets`,
#   * `budget_entity_name = {slug}` — pinned to the slug GitHub stores.
#
# `budget_entity_name` is IMMUTABLE on GitHub's side: a PATCH that CHANGES it
# 400s, and magodo/restful sends the whole body on every PATCH. So enterprise
# budgets ALWAYS carry the slug (never ""), and org budgets can opt into pinning
# their login via `pinOrgEntityName = true`. The default stays "" so existing
# org callers (e.g. metacraft-prod, which pins the login itself in a post-pass)
# render byte-for-byte as before.
#
# The full $0-everywhere shape for an enterprise (all five capped SKUs):
#
#   enterprises."schelling-point-labs" = {
#     productSkus = [
#       "actions"          # minutes + actions storage/cache   (ProductPricing)
#       "packages"         # Packages storage + bandwidth       (ProductPricing)
#       "codespaces"       # Codespaces compute + storage       (ProductPricing)
#       "ai_credits"       # Copilot / Models metered credits   (BundlePricing)
#       "git_lfs_storage"  # Git LFS storage, a leaf SKU        (SkuPricing)
#     ];
#   };
#
# The token reaches the provider through a terraform variable (default
# `github_billing_token`). Point the root's metadata.json at an agenix token
# exported as `TF_VAR_<tokenVar>` (credential_mode = "agenix-token") so the
# value is NEVER written to a tfvars file, the plan, or state. The token must be
# an org admin / billing manager credential (classic PAT `admin:org`, or a
# fine-grained token / GitHub App install token with org "Administration" or
# billing write). `GITHUB_TOKEN` cannot manage budgets.
{
  # attrset: orgLogin -> either
  #   * the legacy single-SKU shape
  #       { id = <existing budget uuid | null>; amount ? 0;
  #         preventFurtherUsage ? true; productSku ? "actions"; }
  #   * or the multi-SKU shape
  #       { productSkus = [ <sku-string | { sku; id ? null; amount ?;
  #                          preventFurtherUsage ?; budgetType ? <inferred> }> … ];
  #         amount ? 0; preventFurtherUsage ? true; }
  #     where amount/preventFurtherUsage act as per-org defaults each SKU entry
  #     may override. See the header comment for the valid SKU strings.
  budgets ? { },
  # attrset: enterpriseSlug -> the SAME value shape as a `budgets` entry (legacy
  # single-SKU or multi-SKU `productSkus`). Each yields ENTERPRISE-scoped budget
  # resources: budget_scope="enterprise", path=/enterprises/<slug>/…, and
  # budget_entity_name pinned to <slug> (the immutable value GitHub stores).
  enterprises ? { },
  # Opt-in: pin an ORGANIZATION budget's budget_entity_name to its org login
  # (matching what GitHub stores for an org-scoped budget) instead of the "" the
  # engine has always emitted. Off by default so existing org callers render
  # byte-for-byte as before; enterprise budgets ALWAYS pin (see header).
  pinOrgEntityName ? false,
  # Terraform variable name carrying the billing-scoped token. The concrete
  # root's metadata.json must set credentials_env_name = "TF_VAR_<this>".
  tokenVar ? "github_billing_token",
  # GitHub API host. Override for GHES.
  apiBaseUrl ? "https://api.github.com",
  # Budgets API version header. Pin it — the schema is versioned.
  apiVersion ? "2026-03-10",
  # magodo/restful provider version constraint.
  restfulVersion ? "~> 0.25",
  # Whether the root uses the shared S3 backend (true) or is offline/local.
  useS3Backend ? true,
}:
# Returns a plain terranix config attrset (only builtins used, so it composes
# like actions-secrets.nix — the concrete root is just
# `{ ... }: import ./this { params }`).
let
  # Resource-name sanitizer: terraform resource labels can't carry "-"/".".
  sanitize = builtins.replaceStrings [ "-" "." ] [ "_" "_" ];

  # A ProductPricing budget caps every child SKU of a product, but Git LFS is
  # billed only through the leaf SKUs git_lfs_storage / git_lfs_bandwidth, which
  # belong to NO product — so an LFS entry has to be a single-SKU (SkuPricing)
  # budget. `ai_credits` is a metered BUNDLE (Copilot / Models credits), billed
  # as BundlePricing rather than a product. Everything else defaults to the
  # product-wide ProductPricing budget.
  inferBudgetType =
    sku:
    if builtins.match "git_lfs.*" sku != null then
      "SkuPricing"
    else if sku == "ai_credits" then
      "BundlePricing"
    else
      "ProductPricing";

  # Normalize one SKU entry (bare string == { sku = <string>; }) against the
  # org-level amount / preventFurtherUsage defaults.
  normSku =
    cfg: entry:
    let
      e = if builtins.isString entry then { sku = entry; } else entry;
    in
    {
      sku = e.sku;
      budgetType = e.budgetType or (inferBudgetType e.sku);
      id = e.id or null;
      amount = e.amount or (cfg.amount or 0);
      preventFurtherUsage = e.preventFurtherUsage or (cfg.preventFurtherUsage or true);
    };

  # Per-entity effective settings with defaults. Yields a LIST of budget entries:
  # the multi-SKU shape maps `productSkus`; the legacy shape yields exactly one
  # actions/ProductPricing entry named after the entity, byte-for-byte as before.
  # `scope` ("organization" | "enterprise") and `entity` (org login | enterprise
  # slug) travel on each entry so budgetResource can render the right path/scope/
  # entity_name. For an ORGANIZATION entity this is identical to the pre-change
  # behavior; the only new axis is the scope tag.
  norm =
    scope: entity: cfg:
    let
      legacy = !(cfg ? productSkus);
      skuEntries =
        if legacy then
          [
            {
              sku = cfg.productSku or "actions";
              budgetType = "ProductPricing";
              id = cfg.id or null;
              amount = cfg.amount or 0;
              preventFurtherUsage = cfg.preventFurtherUsage or true;
            }
          ]
        else
          builtins.map (normSku cfg) cfg.productSkus;
    in
    builtins.map (
      e:
      e
      // {
        inherit scope entity;
        # Legacy callers keep the bare entity-named resource; multi-SKU callers get
        # a unique <entity>_<sku> label per (entity, SKU).
        name = sanitize (if legacy then entity else "${entity}_${e.sku}");
      }
    ) skuEntries;

  mkEntries =
    scope: set: builtins.concatLists (builtins.attrValues (builtins.mapAttrs (norm scope) set));

  entries = (mkEntries "organization" budgets) ++ (mkEntries "enterprise" enterprises);

  # One restful_resource per (entity, SKU). `path` is the entity's budgets
  # collection — org- or enterprise-scoped; a POST creates the budget and returns
  # its `id`; `read_path` then GETs the single budget by that id. The resource's
  # terraform `id` (used for `terraform import`) is exactly that resolved read
  # path — i.e.
  #   /organizations/<org>/settings/billing/budgets/<budget-uuid>            (org)
  #   /enterprises/<slug>/settings/billing/budgets/<budget-uuid>      (enterprise)
  # which is why the import ids use the full path, not the bare uuid.
  budgetResource =
    e:
    let
      enterprise = e.scope == "enterprise";
      collectionPath =
        if enterprise then
          "/enterprises/${e.entity}/settings/billing/budgets"
        else
          "/organizations/${e.entity}/settings/billing/budgets";
      # Enterprise budgets ALWAYS pin the slug (immutable field, whole-body PATCH).
      # Org budgets keep "" unless the caller opts into pinning the login.
      entityName =
        if enterprise then
          e.entity
        else if pinOrgEntityName then
          e.entity
        else
          "";
    in
    {
      name = e.name;
      value = {
        path = collectionPath;

        create_method = "POST";
        update_method = "PATCH";
        # Read a single budget by the id returned from the create response.
        read_path = "$(path)/$(body.id)";

        # The declarative budget. `budget_type=ProductPricing` on a product SKU
        # (e.g. actions/packages) caps every child SKU of that product; a leaf SKU
        # (e.g. git_lfs_storage) uses `budget_type=SkuPricing`; a metered bundle
        # (ai_credits) uses `budget_type=BundlePricing`. `budget_amount=0` +
        # `prevent_further_usage` is the hard-stop $0 cap (GitHub refuses to START
        # further paid usage).
        body = {
          budget_amount = e.amount;
          prevent_further_usage = e.preventFurtherUsage;
          budget_scope = if enterprise then "enterprise" else "organization";
          budget_entity_name = entityName;
          budget_type = e.budgetType;
          budget_product_sku = e.sku;
          budget_alerting = {
            will_alert = false;
            alert_recipients = [ ];
          };
        };

        # These are sent on create/update but NOT tracked for drift: GitHub's GET
        # representation of the budget metadata (entity name / alerting envelope)
        # is not guaranteed to echo the write shape byte-for-byte, and we only
        # care that scope/type/sku/amount/prevent_further_usage stay pinned. This
        # keeps the post-import plan clean. If a real import shows drift on a
        # tracked field (e.g. GitHub returns a capitalized scope), move that field
        # here too and re-plan.
        write_only_attrs = [
          "budget_entity_name"
          "budget_alerting"
        ];
      };
    };
in
{
  terraform = {
    required_version = ">= 1.8.0";
    required_providers.restful = {
      source = "magodo/restful";
      version = restfulVersion;
    };
  }
  // (if useS3Backend then { backend.s3 = { }; } else { });

  # Billing-scoped token, injected via TF_VAR_<tokenVar> by the CI/operator
  # path. Never persisted to tfvars or the plan; state stores no token because
  # the provider block reads it at runtime only.
  variable.${tokenVar} = {
    type = "string";
    sensitive = true;
    description = "Org admin / billing-manager GitHub token used to manage Actions spending budgets via the Budgets REST API.";
  };

  provider.restful = {
    base_url = apiBaseUrl;
    security = {
      http.token = {
        token = "\${var.${tokenVar}}";
        scheme = "Bearer";
      };
    };
    header = {
      "Accept" = "application/vnd.github+json";
      "X-GitHub-Api-Version" = apiVersion;
    };
  };

  resource.restful_resource = builtins.listToAttrs (builtins.map budgetResource entries);
}
