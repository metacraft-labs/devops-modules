# Shared GitHub Terraform library

Company-agnostic Terranix helpers for managing GitHub via Terraform/OpenTofu.
Consumers supply their own data (repositories, policy, credentials); this
directory ships only the reusable logic. Pairs with the reusable Terraform CI
workflow (`.github/workflows/reusable-terraform-ci.yml`) and the plan policy in
`scripts/tofu-plan-policy.py`.

## `branch-protection.nix` — branch-protection rulesets

Renders `github_repository_ruleset` resources from a **branch-protection
policy** plus per-repository configuration. It standardizes on repository
rulesets (not classic branch protection), which is what lets a single
wildcard rule protect _every_ branch.

The policy is org-agnostic and best kept as shared data (for Metacraft this is
`metacraft-dev-guidelines/policies/branch-protection-policy.json`, consumed as a
`flake = false` input — no flake needed in the source repo). The policy fixes
_which branch classes gate on CI_; the caller passes each repository's concrete
required-check contexts.

### Usage

```nix
let
  branchProtection = import ./branch-protection.nix { inherit lib; };
in
branchProtection.mkRulesets {
  policy = builtins.fromJSON (builtins.readFile
    "${inputs.dev-guidelines}/policies/branch-protection-policy.json");
  repositories = {
    "my-product" = {
      repoClass = "product";                      # product | spec | infra | product-adapted-fork
      checks = {
        dev = [ "ci / build" "ci / test" ];       # concrete required-check contexts
        stable = [ "release" ];
      };
    };
    "my-infra" = {
      repoClass = "infra";
      checks.live = [ "terraform / plan" "lint" ];
    };
  };
}
```

`mkRulesets` returns `{ resource.github_repository_ruleset = { ... }; }`,
mergeable into a Terranix root that also declares the `github` provider.

### What it emits

- **One baseline ruleset per repository** targeting `~ALL` branches, blocking
  force pushes and deletions (`non_fast_forward` / `deletion`) — this is the
  "every branch protected from force push" universal rule.
- **One ruleset per applicable branch class** (matched by `repoClass`) that
  gates on CI: `required_status_checks` with the repo's contexts, plus
  `pull_request` review when the class requires it. Classes that require
  neither (e.g. `agents`) emit no extra ruleset and rely on the baseline — so
  `agents` is protected from force-push but does **not** gate on CI, matching
  the branching policy.

### Validate offline

```bash
nix-instantiate --eval --strict --json example/config.nix > example/config.tf.json
cd example && tofu init -backend=false && tofu validate
```

The example is validated against the real `integrations/github` provider
schema (`tofu validate` → `Success`). A real consumer swaps the fixture for the
shared policy file and its own repository list.

## `mainline-protection.nix` — mainline PR-only rulesets for `governance.nix`

Renders one `mainline-protect` repository ruleset per repository whose
**mainline** branch (every policy branch class with `role = "mainline"`: product
`dev`, spec `latest`, infra `live`) is protectable, as plain entries in the
engine's `repositoryRulesets` schema. Each ruleset forbids deletion and
force-push, keeps an `OrganizationAdmin` bypass (not `enforce_admins`), and pins
**no** required status checks. It also requires a pull request (PR-only) unless
the mainline's policy class sets `requirePullRequest = false` (absent means
`true`, so older policies stay PR-only) or the caller lists the repository in
`directPushRepos`; such mainlines keep deletion + force-push protection only.
The `agents` integration branch is never targeted.

```nix
let
  mainline = import "${devops-modules}/terraform/github/mainline-protection.nix" {
    policy = builtins.fromJSON (builtins.readFile ./branch-protection-policy.json);
    repositories = inventory.repositories;
    overrides = { product = "dev"; };   # real mainline != inventory default branch
    excludeRepos = [ "some-fork" ];      # rebased onto upstream (force-push)
    directPushRepos = [ "workspace" ];   # tooling pushes directly: no PR rule
    visibilities = [ "public" ];         # GitHub Free: rulesets 403 on private
    enforcement = "evaluate";            # Enterprise: dry-run a cycle first
    requiredApprovingReviewCount = 0;    # null = derive from the policy class
  };
in
{
  governance = inventory // {
    repositoryRulesets = inventory.repositoryRulesets ++ mainline.rulesets;
  };
}
```

It also returns `protectedRepos`, `prOnlyRepos`, `directPushRepos` (named by the
caller), `policyDirectPushRepos` (on a `requirePullRequest = false` class),
`directPushClasses`, `mainlines` and `uncovered` (repo -> reason) for the
caller's coverage report; the three repo lists partition `protectedRepos`. Unknown repo
names in the corrections, and overrides naming a non-mainline branch, fail the
evaluation. Unlike `branch-protection.nix` (raw resources for a hand-written
map), these entries flow through `governance.nix` and any caller-side filter,
such as an import-only adoption window. Tested offline by
[`tests/test-mainline-protection.sh`](./tests/test-mainline-protection.sh).

## `tf-bootstrap.nix` — CI-enabling GitHub Layer-0 root

The GitHub counterpart of the AWS `tf-bootstrap.nix`: a value-independent module
rendering the minimal GitHub facts the CI/CD pipeline depends on to run — the
reviewer team, the deploy Environment, the AWS OIDC role-ARN Actions variables,
the Terraform safety labels, and branch protection for the deploy branch. Each
consumer's `bootstrap/github/<name>/default.nix` is a thin caller:

```nix
{ ... }:
import "${inputs.nixos-modules}/terraform/github/tf-bootstrap.nix" {
  awsAccountId = "…";
  namePrefix = "…-prod";               # state key derives: bootstrap/github/<namePrefix>.tfstate
  githubOwner = "…";                   # githubRepo defaults to "infra", protectedBranch to "live"
  reviewerTeam = {
    name = "infra";
    slug = "infra";
    description = "Maintainers for … infrastructure.";
    initialMaintainer = "…";           # the bootstrap admin username
  };
  requiredStatusCheckContexts = [ "…" ];   # the repo's real CI check contexts
}
```

Broader org governance (repositories, memberships, org secrets) is the separate
[`governance.nix`](#governancenix--github-governance-engine) engine — this module
is only the per-repo settings that unblock the pipeline. See
[`tf-bootstrap.example.nix`](./tf-bootstrap.example.nix) and
[`tests/test-bootstrap-render.sh`](./tests/test-bootstrap-render.sh). Verifying an
extraction is a no-op is the same `nix eval --json | jq -S` diff as the AWS module.

## `governance.nix` — GitHub governance engine

Maps a declarative **governance model** (repositories, memberships, teams,
branch protection, Environments, Actions permissions/variables, issue labels)
plus a **secret manifest** and the GitHub-encrypted **payloads** rendered by
`github-governance-secrets-render` into `github_*` Terraform resources, and
exposes the rich `output` block the bootstrap helper reads. It is the engine
behind each org's `terraform/github/<name>-governance-prod` root.

**That root is Layer 1+, not Layer 0.** Org governance is policy, not pipeline
plumbing: nothing the CI/CD pipeline needs in order to run lives in it, so it
carries a `metadata.json` (`credential_mode: "github-app"`), is discovered by
`terraform/ci/terraform-ci-matrix`, and is plan-comment-applied like every other
managed root. The genuinely Layer-0 slice — the Actions secrets holding the CI
App credentials and the CI agenix key — belongs in a separate, small
`bootstrap/github/<name>-governance-secrets-prod` root built on
[`actions-secrets.nix`](#actions-secretsnix--standalone-actions-secrets-engine),
so the pipeline's own credentials are never writable by the pipeline. See
[root layering](../../docs/Terraform-Root-Layering.md#which-layer-a-root-belongs-to).

Everything company-specific is a parameter; the machinery (name sanitizers,
list→resource mappers, the secret-manifest validation that throws on unknown or
missing managed/payload ids) is org-agnostic. A consumer's `root.nix` becomes a
thin caller that resolves its local generated documents and passes its own data:

```nix
{ managedFile ? ./secrets/managed.generated.nix, payloadFile ? ./secrets/payloads.generated.nix, ... }:
{ ... }:
import "${inputs.nixos-modules}/terraform/github/governance.nix" {
  awsAccountId = "…";
  awsRegion = "us-east-1";
  githubOwner = "…";                                   # githubAccessCheckRepository defaults to <owner>/infra
  githubBootstrapStateKey = "bootstrap/github/…-governance-prod.tfstate";
  governance = import ./governance.nix;                 # the org inventory model (per-company data)
  manifest = import ./secrets/manifest.nix;             # the secret registry (per-company data)
  managedDoc = if builtins.pathExists managedFile then import managedFile else { providerIds = [ ]; };
  payloadDoc = if builtins.pathExists payloadFile then import payloadFile else { payloads = { }; };
}
```

The `governance` and `manifest` documents stay in each infra repo — they are the
org's inventory and secret facts. Only the mapper is shared. See
[`governance.example.nix`](./governance.example.nix) for a minimal renderable
model and [`tests/test-render.sh`](./tests/test-render.sh) for the offline check.

### Org-wide team grants

`governance.teamRepositories` enumerates one grant per (team, repo). For an
access policy phrased as _"this team reaches **every** repo"_, enumerating is the
wrong shape: the list is correct only until the next repo is created, and the
gap it leaves is invisible — the rule still reads as "all".

`governance.orgWideTeamRepositories` states that policy once and lets the engine
expand it over `governance.repositories`:

```nix
orgWideTeamRepositories = [
  { teamSlug = "codetracer"; permission = "maintain"; }
];
```

A repository added to the model later inherits the grant with no edit to the
rule.

Where a rule and an explicit `teamRepositories` entry cover the same (team,
repo) pair, **the stronger permission wins** (`pull` < `triage` < `push` <
`maintain` < `admin`). Both directions are deliberate:

- an explicit `admin` is **not** downgraded by a blanket `maintain` rule — adding
  an org-wide floor must never quietly strip a privilege someone chose;
- an explicit `push` **is** raised to `maintain` — otherwise a single stale row
  silently falsifies a rule that claims to cover everything.

Two guardrails throw at eval rather than half-applying a rule: a rule whose
`permission` is a custom repository role (unrankable, so it could not be
compared consistently against explicit grants), and more than one rule for the
same team (the outcome would depend on list order). An _explicit_ custom role is
left exactly as written — the engine cannot know whether it outranks `maintain`,
and guessing could strip privileges or invent them.

[`tests/test-org-wide-team-grants.sh`](./tests/test-org-wide-team-grants.sh)
covers the expansion, both precedence directions, and both throws.

### Security posture the engine models

Three free-on-every-plan dimensions, all optional and all rendered only when the
consumer's inventory supplies them:

| Inventory field                      | Resource                                        | Notes                                                                                                                                                                 |
| ------------------------------------ | ----------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `repositories[].securityAndAnalysis` | `github_repository.security_and_analysis`       | `secretScanning` + `secretScanningPushProtection`, both required together. Nested block — rides the existing `github_repository` import, so it needs no import block. |
| `vulnerabilityAlerts[]`              | `github_repository_vulnerability_alerts`        | `{ repository, enabled }`, imported by bare repository name.                                                                                                          |
| `dependabotSecurityUpdates[]`        | `github_repository_dependabot_security_updates` | `{ repository, enabled }`, imported by bare repository name.                                                                                                          |

Two constraints are enforced rather than documented. `advancedSecurity` and the
other `security_and_analysis` sub-blocks are rejected at eval time: GitHub
renamed `advanced_security` to `code_security` in its responses while provider
6.12.1 still sends and reads `advanced_security`, and `code_security`,
`secret_scanning_ai_detection` and `secret_scanning_non_provider_patterns` are
schema-only — declaring any of them yields a permanent diff and no API call. And
the two sub-blocks must be supplied together, because an omitted one is left
Computed and drifts silently.

Model **every** repository in the two list-shaped dimensions, not only the
enabled ones: a disabled feature imports cleanly as `enabled = false`, whereas an
unmodelled repository is a creation waiting to happen. Seed from observed values;
enabling is a later, separately reviewed change against a populated state.

Verifying an extraction is a no-op is the same as for the AWS module: render the
original `root.nix` and the thin caller with identical data and `diff` the
`nix eval --json | jq -S` output — empty diff == zero plan diff == safe.

## Import-phase tooling

Company-agnostic tools for adopting an existing GitHub org into Terraform (the
one-time [import phase](../../docs/Terraform-Import-Phase.md)). None hardcode an
org — owner / root-config / repo-root are parameters.

- **`github-inventory`** — read-only inventory of the org (repos, branch
  protection, Environments, Actions vars/permissions, labels, team grants,
  security posture) into `.result/` as raw JSON + a redacted `inventory.md`.
  Secret values are never read. `--owner <org>` (or `GITHUB_OWNER`),
  `--all-repos`.

  Collaborators are captured under three affiliations and they are **not**
  interchangeable. `repo-collaborators-*.json` is `affiliation=direct` and is
  the only one that corresponds to a `github_repository_collaborator`;
  `repo-outside-collaborators-*.json` is `affiliation=outside`; and
  `repo-effective-access-*.json` is `affiliation=all` — effective access,
  including team-derived and owner-derived grants. Reading the last one as if it
  were the first produces import blocks for collaborations that do not exist,
  and, if applied as creations, direct grants that survive removal from the
  team. [`tests/test-collaborator-affiliation.sh`](./tests/test-collaborator-affiliation.sh)
  is the negative control.

- **`github-governance-import-blocks`** — credential-free generator that reads a
  repo's reviewed `terraform/<root-config>/governance.nix` (falling back to
  `bootstrap/<root-config>/` for a Layer-0 root) and emits OpenTofu
  `import {}` blocks. `--owner`, `--root-config`, `--root-dir`, `--scope`. Output
  stays under `.result/<layer>/<root-config>/` and is never committed. Scopes
  include `vulnerability-alerts` and `dependabot-security-updates`;
  `security_and_analysis` has no scope of its own because it is a nested block on
  `github_repository` and rides the `repositories` import.
- **`github-governance-import-ci`** — the CI harness (plan / gated apply) that
  runs the generator + plan and **refuses any non-import action** (≥1 import, 0
  add/change/destroy/replace; typed confirm for apply). Driven by env
  (`GOVERNANCE_ROOT_CONFIG`, `GOVERNANCE_ROOT`, `GOVERNANCE_RESULT_ROOT`,
  `BACKEND_CONFIG_FILE`, `GOVERNANCE_TOKEN_PATH`).

## Secret adoption + rotation tooling (M3/M4)

Company-agnostic tools for the secret side of governance — backing up, rendering,
and rotating the GitHub Actions secrets the [governance engine](#governancenix--github-governance-engine)
manages. All are parameterized by env: `GOVERNANCE_ROOT_CONFIG`
(e.g. `github/<name>-governance-prod`) and `GOVERNANCE_REPO_ROOT` (default CWD).
See the [import-phase methodology](../../docs/Terraform-Import-Phase.md) (M3/M4)
and [secret-rotation methodology](../../docs/GitHub-Secret-Rotation.md).

- **`github-governance-secrets-render`** — renders GitHub-encrypted (libsodium
  sealed-box) payloads for the managed secrets from their agenix `.age` sources,
  writing `secrets/{payloads,managed}.generated.nix`. Plaintext is decrypted only
  into a private temp dir, never onto the command line. Select with `--secret`,
  `--group`, `--all`, or `--set SET` (data-driven: matches the manifest secret's
  `sets` field — no hardcoded credential sets).
- **`github-secret-rotation-intake`** — creates/verifies the `.age` replacement
  files for rotation; never writes to GitHub, never prints values.
- **`github-secret-rotation-plan`** / **`github-secret-consumer-matrix`** —
  read-only Markdown reports (rotation groups from the manifest; consumer matrix
  from `secrets/consumers.nix`).
- **`github-secret-rotate`** — issuer-aware dispatcher. Reads the matched
  manifest secret's `rotationHandler` and execs the per-repo handler under
  `$GOVERNANCE_SECRET_HANDLERS_DIR` (default `<root>/secret-handlers`); prints the
  manifest entry and stops if none is declared. Issuer handlers stay per-repo.
- **`github-governance-token`** — CI helper that mints a short-lived GitHub App
  installation token (already org-agnostic).

To adopt secrets, a consumer adds entries to `secrets/manifest.nix` (optionally
with `sets` / `rotationHandler`), places `.age` sources under `secrets/actions/`,
then runs render → reviewed governance plan/apply.

## `actions-secrets.nix` — standalone Actions-secrets engine

Emits only `github_actions_secret` resources from rendered, GitHub-encrypted
payloads — no repos, no teams, no org settings. Two distinct uses:

- as a **managed** root (`terraform/github/secrets-<name>-prod`, `credential_mode:
github-app`) for ordinary per-repo application secrets, which are
  plan-comment-applied like anything else; and
- as the small **Layer-0** root (`bootstrap/github/<name>-governance-secrets-prod`)
  holding only the chicken-and-egg secrets the pipeline authenticates with.

Resource keys and attribute shape match `governance.nix` exactly
(`github_actions_secret.secret_<providerId>`, `key_id` + `value_encrypted`), so
state and the targeted `github-bootstrap` secret flows are interchangeable
between the two engines.

## `github-bootstrap` — GitHub Layer-0 driver

Org-admin driver for the GitHub side of Layer 0: the CI-enabling repo settings
(the `production` Environment, deploy-branch protection, OIDC role-ARN Actions
variables, CODEOWNERS) and the small governance-secrets root. Human-applied,
out-of-band — never through the pipeline it enables, because the pipeline
depends on these settings and secrets to run. It is **not** the path for the org
governance root itself: that is Layer 1+ and runs through the PR workflow.

Subcommands: `plan` / `apply` / `outputs`, plus the targeted
`governance-app-secrets-{plan,apply}` (writes the two `GH_GOVERNANCE_APP_*` org
secrets so governance CI can authenticate). Like `aws-bootstrap` it guards the
AWS account owning the shared S3 state backend via STS, verifies the GitHub
token can administer the target repo, and hardcodes nothing company-specific:

```bash
github-bootstrap plan github/<name> --root-dir <repo>
```

The backend file derives from the config (`backends/<config-slug>.hcl`,
overridable via `GITHUB_BOOTSTRAP_BACKEND_FILE`); the org for the governance
secret targets is read from the rendered outputs.
