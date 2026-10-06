# Terraform Agent Development Methodology

This document describes the methodology for developing OpenTofu / Terraform
modules using AI coding agents (such as Claude Code) within a human-supervised
CI/CD pipeline. The approach ensures that agents can iterate rapidly on
infrastructure code without ever holding cloud credentials, while humans
retain full approval authority over what gets provisioned.

> **Scope:** This is a general methodology shared across repositories via
> `nixos-modules`. The examples below use Cloudflare as a concrete provider,
> but the principles and workflow apply to any cloud provider. Each consuming
> repository provides its own project-specific guides (access tokens,
> bootstrapping, status plans).
>
> **Terranix support:** `.tf` files can be hand-written or generated via
> [Terranix](https://terranix.org/) (Nix expressions → HCL). The agentic
> workflow is identical either way — Terranix produces standard `.tf.json`
> files that `tofu validate`, `tofu plan`, and `tofu apply` consume normally.
> When using Terranix, agents edit `.nix` files instead of `.tf` files, and
> CI runs `terranix` before `tofu init`.

## Principles

1. **Agents never hold credentials.** All development and testing happens
   offline using mock providers and `tofu validate`. Agents never call
   real cloud APIs.

2. **Every change flows through a pull request.** There are no out-of-band
   applies. The PR is the single source of truth for what changed and why.

3. **CI produces a human-readable plan.** On every PR, the pipeline runs
   `tofu plan` with real credentials and posts the output as a PR comment.
   Reviewers see the exact infrastructure diff before approving.

4. **Apply happens only after human approval.** Merging the PR into the
   target environment branch triggers `tofu apply` for that environment.
   No agent or automation can bypass branch protection and merge review.

5. **Branches represent deployment environments.** A repository can map
   branches such as `testing`, `staging`, and `main` to matching apply
   environments. Promotion is a merge from one branch to the next. GitHub
   Environments are still useful as credential boundaries for apply jobs,
   but required Environment reviewers are an optional project-specific
   control, not the default approval mechanism.

---

## Workflow Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│  AGENT (no credentials)                                                  │
│                                                                          │
│  1. Write / modify .tf files (or .nix files when using Terranix)          │
│  2. Write .tftest.hcl tests with mock_provider                           │
│  3. Run: tofu validate                                                   │
│  4. Run: tofu test                                                       │
│  5. Open PR                                                              │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │  push
                             v
┌──────────────────────────────────────────────────────────────────────────┐
│  CI — PR checks (automated, real credentials via agenix)                 │
│                                                                          │
│  6. tofu validate                                                        │
│  7. tofu fmt --check                                                     │
│  8. tofu test              (mock providers — offline)                     │
│  9. tofu plan              (real credentials — read-only)                 │
│ 10. Post plan output as PR comment                                       │
│ 11. Optionally: tflint, checkov / trivy                                  │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │
                             v
┌──────────────────────────────────────────────────────────────────────────┐
│  AGENT monitors CI results (via `gh` CLI)                                │
│                                                                          │
│ 12. Poll workflow status: gh run watch / gh run view                     │
│ 13. Read plan comment: gh pr view --comments                             │
│ 14. If CI failed or plan shows issues → fix, push, go to step 6         │
│ 15. If plan is clean → agent is done, request human review               │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │  agent satisfied with plan
                             v
┌──────────────────────────────────────────────────────────────────────────┐
│  HUMAN SUPERVISOR                                                        │
│                                                                          │
│ 16. Review the PR diff (code)                                            │
│ 17. Review the plan comment (infrastructure diff)                        │
│ 18. Approve and merge                                                    │
└────────────────────────────┬─────────────────────────────────────────────┘
                             │  merge to target branch
                             v
┌──────────────────────────────────────────────────────────────────────────┐
│  CI — post-merge (automated, real credentials)                           │
│                                                                          │
│ 19. tofu apply             (for the branch's target environment)         │
│ 20. Post apply result as commit status or comment                        │
│                                                                          │
│  Note: Branches map to environments. For example, merging to `testing`   │
│  applies testing, then merging testing into `main` applies production.   │
│  Projects without a lower environment can map `main` directly to prod.   │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: Agent Development (Offline)

The agent works locally (or in a sandboxed CI environment) with no cloud
credentials. Its job is to produce correct `.tf` files and matching test
files.

### What the agent does

1. **Reads existing configuration** — understands the current modules,
   variables, outputs, and provider setup.

2. **Writes or modifies `.tf` files** (or `.nix` files when using
   Terranix) — implements the requested infrastructure change.

3. **Writes `.tftest.hcl` tests** — every non-trivial change should
   include at least one test file that exercises the logic with a mocked
   provider. Tests should verify:
   - Resource attributes match the intent (names, types, values).
   - Variable validation and defaults behave correctly.
   - Conditional logic (`count`, `for_each`, dynamic blocks) produces the
     expected resource set.
   - Outputs expose the right values.

4. **Runs offline validation:**

   ```bash
   tofu init -backend=false          # init providers without a backend
   tofu validate                     # syntax + type checking
   tofu test                         # run mock-provider tests
   ```

5. **Opens a pull request** with a clear description of the intent.

6. **Monitors CI results via `gh`** — after pushing, the agent uses the
   GitHub CLI to poll the workflow run and read the plan output:

   ```bash
   # Wait for the CI workflow to complete
   gh run watch

   # Check the outcome
   gh run view --json conclusion,jobs

   # Read the plan posted as a PR comment
   gh pr view --comments
   ```

7. **Iterates until the plan is clean** — if CI fails (validation error,
   test failure) or the plan shows unexpected changes, the agent:
   - Reads the failure logs: `gh run view --log-failed`
   - Reads the plan comment: `gh pr view --comments`
   - Fixes the `.tf` or `.tftest.hcl` files
   - Re-runs `tofu validate` and `tofu test` locally
   - Pushes the fix (CI re-runs automatically)
   - Repeats until the plan shows only the expected changes

   The agent considers its work done when:
   - All CI checks pass (validate, fmt, lint, test).
   - The plan comment shows only the intended resource changes.
   - No unexpected destroys, replacements, or drifted attributes.

### What the agent must NOT do

- Call `tofu plan` or `tofu apply` with real credentials.
- Modify state files.
- Commit `.tfstate`, credential files, or private keys.
- Bypass validation failures (e.g. skip tests to "fix later").

### Agent guardrails

To enforce these boundaries:

- The agent's environment does not contain any provider credentials
  (e.g. `CLOUDFLARE_API_TOKEN`, `AWS_ACCESS_KEY_ID`,
  `GOOGLE_APPLICATION_CREDENTIALS`).
- The `.gitignore` already excludes `*.tfstate`, `*.tfvars`, and
  `.terraform/`.
- Pre-commit hooks (if configured) can enforce `tofu validate` and
  `tofu fmt --check` before allowing a commit.

---

## Phase 2: CI — Pull Request Checks

When the agent (or any contributor) pushes a PR, CI runs the full
validation pipeline. This is implemented using GitHub Actions.

> **Security note:** The PR plan job uses a **read-only** API token (or
> equivalent credentials) that cannot modify resources. The write token is
> only available in the post-merge apply job for the target branch's GitHub
> Environment. See the consuming repository's access token guide for
> project-specific token configuration.

### Pipeline steps

| Step        | Tool                 | Credentials         | Purpose                        |
| ----------- | -------------------- | ------------------- | ------------------------------ |
| Checkout    | `actions/checkout`   | None                | Get the code                   |
| Init        | `tofu init`          | Backend creds       | Initialize providers + backend |
| Format      | `tofu fmt --check`   | None                | Enforce consistent formatting  |
| Validate    | `tofu validate`      | None                | Syntax and type checks         |
| Lint        | `tflint`             | None                | Best-practice checks           |
| Security    | `checkov` or `trivy` | None                | Policy / misconfiguration scan |
| Denylist    | grep / conftest      | None                | Block dangerous HCL constructs |
| Unit test   | `tofu test`          | None                | Mock-provider tests            |
| Plan        | `tofu plan`          | **Read-only** creds | Real infrastructure diff       |
| Plan safety | plan analysis        | None                | Block destroys/replacements    |
| Comment     | PR comment action    | `GITHUB_TOKEN`      | Post plan to PR                |

### Plan-as-PR-comment

We use the [`dflook/tofu-plan`](https://github.com/dflook/tofu-plan)
GitHub Action to run `tofu plan` and automatically post the output as a
collapsible PR comment. This gives reviewers a human-readable view of
exactly what will change.

Key features:

- Updates a single comment on each push (no comment spam).
- Shows resource counts: `to_add`, `to_change`, `to_destroy`.
- Collapses long plans behind a `<details>` toggle.
- The companion [`dflook/tofu-apply`](https://github.com/dflook/tofu-apply)
  action can apply the exact plan that was reviewed, rejecting the apply
  if the plan has changed since the comment was posted.

### Example workflow (PR checks)

> The following example uses Cloudflare as the provider. Adapt the paths,
> provider credentials, and token names for your project.

```yaml
name: 'Terraform PR'
on:
  pull_request:
    paths:
      - 'cloudflare/**'
      - 'backends/**'
      - '.terraform.lock.hcl'
      - '.github/workflows/terraform*.yml'

permissions:
  contents: read
  pull-requests: write

jobs:
  # Offline checks run on all PRs (including forks).
  # IMPORTANT: Use GitHub-hosted runners for fork PRs to prevent runner
  # compromise from untrusted code. Self-hosted runners must never run
  # untrusted fork code, even without secrets.
  offline-checks:
    runs-on:
      ${{ github.event.pull_request.head.repo.full_name == github.repository
      && fromJSON('["self-hosted", "Linux", "x86-64-v2"]')
      || 'ubuntu-latest' }}
    steps:
      # Pin actions by commit SHA to reduce supply-chain risk
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

      - name: Format check
        run: tofu fmt -check -recursive cloudflare/

      - name: Validate
        run: |
          cd cloudflare && tofu init -backend=false
          tofu validate

      # Block dangerous HCL constructs (see "IaC Denylist Policy" below)
      - name: Denylist check
        run: |
          if grep -rE \
            '(data\s+"external"|provisioner\s+"(local-exec|remote-exec)"|resource\s+"null_resource")' \
            cloudflare/; then
            echo "::error::Forbidden HCL constructs detected. See docs/Terraform-Agent-Development-Methodology.md."
            exit 1
          fi

      - name: Unit tests
        run: cd cloudflare && tofu test

  # Credentialed plan only runs on same-repo PRs (never forks).
  # Job-level guard ensures no secrets are decrypted for untrusted code.
  credentialed-plan:
    needs: offline-checks
    if: github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ['self-hosted', 'Linux', 'x86-64-v2']
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

      # Decrypt the READ-ONLY plan token (cannot modify resources)
      - name: Decrypt provider credentials
        run: |
          install -m 600 /dev/null "$RUNNER_TEMP/ci-key"
          echo "${{ secrets.AGENIX_CI_PRIVATE_KEY }}" > "$RUNNER_TEMP/ci-key"

          CLOUDFLARE_API_TOKEN="$(age -d -i "$RUNNER_TEMP/ci-key" \
            machines/<machine>/secrets/cloudflare/api_token_plan.age)"
          echo "::add-mask::$CLOUDFLARE_API_TOKEN"
          echo "CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN" >> "$GITHUB_ENV"

      - uses: dflook/tofu-plan@2b0b0a4074e31e43c19ca5a0e76d8f8956e6cc27 # v2
        id: plan
        with:
          path: cloudflare
          label: cloudflare
          backend_config_file: ${{ vars.BACKEND_CONFIG_FILE }}

      # Block plans that destroy or replace resources unless explicitly allowed
      - name: Plan safety gate
        if: steps.plan.outputs.to_destroy > 0 || steps.plan.outputs.to_replace > 0
        run: |
          if ! gh pr view "${{ github.event.pull_request.number }}" --json labels -q '.labels[].name' | grep -q 'allow-destroy'; then
            echo "::error::Plan includes destroy/replace actions. Add the 'allow-destroy' label and get extra approval to proceed."
            exit 1
          fi

      - name: Cleanup
        if: always()
        run: rm -f "$RUNNER_TEMP/ci-key"
```

> **Note on SHA pinning:** All third-party GitHub Actions should be pinned by
> commit SHA (not just version tag) to prevent supply-chain compromises. Add a
> comment with the version tag for readability. Update SHAs when upgrading
> action versions, and verify checksums match the expected release.

> **Note on backend config:** All workflows reference the backend config
> file via the repository variable `BACKEND_CONFIG_FILE` (set in
> **Settings > Variables** to e.g. `backends/gcs.hcl`). This keeps the
> backend choice centralized: switching backends requires changing one
> variable, rather than editing every workflow file. Plan, apply, and
> drift detection all use the same variable, preventing mismatches.

---

## Phase 3: Human Review

The human supervisor reviews two things:

1. **The code diff** — is the `.tf` change correct, well-structured, and
   does it match the intent?

2. **The plan comment** — does the infrastructure diff look safe? Are only
   the expected resources being added / changed / destroyed?

Review checklist:

- [ ] No secrets or credentials in the diff.
- [ ] Resource names follow naming conventions.
- [ ] New resources have appropriate tags/labels.
- [ ] No unexpected destroys or replacements.
- [ ] Blast radius is acceptable (how many resources change?).
- [ ] Tests cover the new/changed logic.
- [ ] The plan comment shows "No changes" for unrelated resources.

In the typical agentic workflow, the agent will have already iterated on
CI failures and plan issues before the human sees the PR. By the time a
human reviews, the plan should be clean. If the reviewer still spots
issues, they request changes via a PR comment. The agent reads the
feedback (`gh pr view --comments`), pushes fixes, and the cycle repeats.

---

## Phase 4: Apply on Merge

After approval and merge to the target environment branch, CI runs
`tofu apply` to provision the changes for that environment.

### Safety mechanisms

- **Plan comparison:** The `dflook/tofu-apply` action re-generates the
  plan and compares it to the one posted in the PR comment. If anything
  has changed (e.g. due to concurrent merges or external drift), the
  apply is rejected with a `plan-changed` failure. This prevents
  applying a plan that no human has reviewed.

- **State locking:** The backend (GCS or HCP Terraform) locks the state
  during apply, preventing concurrent writes.

- **Single pipeline (Layer 1):** For agent-managed infrastructure, only
  the post-merge CI job can apply. No human or agent runs `tofu apply`
  locally. Exceptions: the bootstrap layer (Layer 0) is applied manually
  by human admins under a separate state, and break-glass recovery
  follows a documented runbook (see [Bootstrap layer separation](#bootstrap-layer-separation)).

- **Write token isolation:** The apply job uses a separate read-write
  token (e.g. `api_token_apply`). This token is only available in the
  GitHub Environment associated with the target branch. By default, merge
  approval is the human approval gate; repositories may add required
  Environment reviewers for exceptional high-risk environments.

- **Post-apply smoke tests:** After a successful apply, automated curl
  checks verify that key endpoints respond as expected (see
  [Post-Apply Smoke Tests](#post-apply-smoke-tests) below).

### Example workflow (apply on merge)

> Adapt paths, provider credentials, and smoke test domains for your project.

```yaml
name: 'Terraform Apply'
on:
  push:
    branches: [main]
    paths:
      - 'cloudflare/**'
      - 'backends/**'
      - '.terraform.lock.hcl'
      - '.github/workflows/terraform*.yml'

permissions:
  contents: read
  pull-requests: write

jobs:
  apply:
    runs-on: ['self-hosted', 'Linux', 'x86-64-v2']
    environment: production # scopes apply credentials for the target branch
    env:
      GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2

      # Decrypt the READ-WRITE apply token
      - name: Decrypt provider credentials
        run: |
          install -m 600 /dev/null "$RUNNER_TEMP/ci-key"
          echo "${{ secrets.AGENIX_CI_PRIVATE_KEY }}" > "$RUNNER_TEMP/ci-key"

          CLOUDFLARE_API_TOKEN="$(age -d -i "$RUNNER_TEMP/ci-key" \
            machines/<machine>/secrets/cloudflare/api_token_apply.age)"
          echo "::add-mask::$CLOUDFLARE_API_TOKEN"
          echo "CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN" >> "$GITHUB_ENV"

      - uses: dflook/tofu-apply@3d5bdd8e0ccc0e04e6b0e18f1a76e8e17a22e92a # v2
        with:
          path: cloudflare
          label: cloudflare
          backend_config_file: ${{ vars.BACKEND_CONFIG_FILE }}

      - name: Post-apply smoke tests
        run: |
          failed=0
          for domain in api.example.com status.example.com; do
            status=$(curl -fsSL -o /dev/null -w '%{http_code}' "https://${domain}/")
            if [ "$status" != "200" ]; then
              echo "::error::Smoke test FAILED: https://${domain}/ returned HTTP ${status}"
              failed=1
            else
              echo "PASS: https://${domain}/"
            fi
          done
          if [ "$failed" -eq 1 ]; then
            echo "::error::One or more smoke tests failed. See the break-glass/rollback runbook."
            exit 1
          fi

      - name: Cleanup
        if: always()
        run: rm -f "$RUNNER_TEMP/ci-key"
```

---

## Phase 5: Branch-Based Environment Promotion

For services that require staged rollouts, branches represent deployment
environments. Each target branch has its own Terraform root, backend state,
provider credentials, and GitHub Environment. Promotion is done by merging
from a lower branch into a higher branch.

### Directory structure

```
cloudflare/
  modules/              # reusable modules (no backend, no provider)
    dns/
    r2/
  envs/
    staging/            # staging environment root
      main.tf           # provider + backend + module calls
      staging.auto.tfvars
    production/         # production environment root
      main.tf
      production.auto.tfvars
  backends/
    staging-gcs.hcl
    production-gcs.hcl
```

Both `staging/main.tf` and `production/main.tf` call the same modules
from `modules/`, but with different variable values and separate state
backends. This ensures:

- Identical module code across environments.
- Independent state files (a staging apply cannot corrupt production
  state).
- Different backend credentials / access controls per environment.

### Promotion workflow

```
PR opened against testing
  │
  ├─ CI: plan testing     → PR comment (testing plan)
  │
  v
Human reviews plan, approves PR
  │
  v
Merge to testing
  │
  ├─ CI: apply testing
  │
  v
Testing verified (manual or automated smoke test)
  │
  v
PR opened from testing to main
  │
  ├─ CI: plan production  → PR comment (production plan)
  │
  v
Human reviews production plan, approves PR
  │
  v
Merge to main
  │
  └─ CI: apply production
```

### GitHub Environment credential boundaries

GitHub Actions [environments](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
bind apply credentials and deployment metadata to a named target environment:

```yaml
jobs:
  apply-production:
    runs-on: ['self-hosted', 'Linux', 'x86-64-v2']
    environment: production # exposes only production-scoped apply credentials
    steps:
      - uses: dflook/tofu-apply@v2
        with:
          path: cloudflare/envs/production
          label: production
          backend_config_file: backends/production-gcs.hcl
```

The default methodology treats the merge into the target branch as the
deployment approval. If a repository configures required reviewers on the
GitHub Environment, the job pauses for an additional approval in the GitHub UI;
that should be a deliberate project-specific exception.

### Staging semantics

Some providers/services do not have a built-in staging environment. In
those cases, "staging" means one of:

- A separate environment/account/zone/namespace if available.
- A separate hostname or prefix within the same scope.
- If neither exists, staging is omitted and merging to the production branch
  applies production directly.

Document which approach applies for each project so reviewers know what
protections exist.

---

## Risk Controls

### PR trust boundary

The credentialed plan step decrypts secrets and calls real APIs, so it must
not run on untrusted code. Hardening measures:

- **Same-repo PRs only:** The PR workflow must skip the entire credentialed
  plan **job** for PRs from forks — use a job-level `if` guard, not just a
  step-level conditional. This ensures no secrets are decrypted for untrusted
  code. Fork PRs still get the offline checks (validate, fmt, test, denylist)
  in a separate job that requires no credentials:
  ```yaml
  credentialed-plan:
    if: github.event.pull_request.head.repo.full_name == github.repository
  ```
- **Fork PRs must not run on self-hosted runners.** Even without secrets,
  untrusted fork code can compromise a persistent self-hosted runner,
  potentially exposing secrets in later jobs. The offline-checks job must
  use GitHub-hosted runners (or a truly ephemeral environment) for fork PRs.
  Use a conditional `runs-on` expression to select the runner based on PR
  origin.
- **CODEOWNERS:** Require a qualified infrastructure reviewer for changes to
  `cloudflare/`, `.github/workflows/terraform*.yml`, `backends/`, and the
  provider lockfile. Create a `CODEOWNERS` file:
  ```
  /cloudflare/                     @<org>/<infra-reviewers-team>
  /bootstrap/                      @<org>/<infra-reviewers-team>
  /backends/                       @<org>/<infra-reviewers-team>
  .github/workflows/terraform*.yml @<org>/<infra-reviewers-team>
  .terraform.lock.hcl              @<org>/<infra-reviewers-team>
  ```
- **Branch protection:** Enable required reviews and status checks on `main`
  so no PR merges without passing CI and an approved review.

### Self-hosted runner hardening

The CI plan and apply jobs run on self-hosted runners, which introduces
risks not present with GitHub-hosted runners. GitHub's docs are explicit
that jobs on self-hosted runners are **not** isolated containers, even
when GitHub Environments are used. Environment protection rules and
branch-scoped credentials are release-control mechanisms, not a sandbox.

- **Ephemeral runners (required):** Run Terraform jobs in ephemeral
  containers or VMs that are destroyed after each job. This ensures
  secrets do not persist between runs and prevents a compromised runner
  from affecting subsequent jobs. At minimum, the workflow cleans up the
  decrypted key file in an `always()` step, but ephemeral runners are
  the proper solution.
- **Network egress restrictions:** Restrict outbound traffic from the
  runner to only the relevant cloud provider APIs, the Terraform
  registry (`registry.terraform.io`), and the state backend. This
  limits exfiltration paths if a malicious construct runs during plan.
- **Dedicated runner group:** Use a separate runner group (or labels) for
  infrastructure jobs so they do not share an environment with
  general-purpose CI builds.

### IaC denylist policy

Agent-written HCL can include constructs that execute code at plan time,
which is dangerous because the plan job runs with real (read-only)
credentials. The CI pipeline must block these constructs:

| Blocked construct           | Reason                                                                                                                                                            |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `data "external"`           | Runs an arbitrary local program                                                                                                                                   |
| `provisioner "local-exec"`  | Runs shell commands on the CI runner                                                                                                                              |
| `provisioner "remote-exec"` | Runs commands on remote hosts                                                                                                                                     |
| `resource "null_resource"`  | Typically used with exec provisioners                                                                                                                             |
| Unlisted providers          | Only providers in the project's allowlist (define per-repo)                                                                                                       |
| Remote `source` without pin | `source = "github.com/..."` or any remote module source must use an immutable ref (commit SHA or tag + checksum); unpinned remote sources are a supply-chain risk |

Enforcement options (from simplest to most robust):

1. **grep-based check** in CI (already shown in the PR workflow example).
2. **OPA/conftest** policies that parse the HCL AST and reject forbidden
   blocks.
3. **Checkov custom policies** that extend the existing security scan step.

### Plan safety gates

Even with human review, mistakes happen — especially during import
milestones. CI should fail by default if the plan includes:

- **Any resource deletions** (`to_destroy > 0`).
- **Any resource replacements** (delete + create, `to_replace > 0`).
- **Changes to sensitive resource types** (zone settings, rulesets).

To allow an intentional destructive change, the PR must have:

1. An `allow-destroy` label.
2. An additional approval from a designated infrastructure reviewer.

For changes that touch **sensitive resource types** — specifically
`cloudflare_ruleset` or `cloudflare_zone_settings_override` — the PR must
carry a `sensitive-change` label and require infra-owner approval, even if
no resources are being destroyed. This is particularly important for ruleset
changes, which can break live traffic if the rewrite expression is wrong.

The PR workflow example above implements the destroy/replace gate using
`steps.plan.outputs.to_destroy` and `steps.plan.outputs.to_replace` from
`dflook/tofu-plan`.

### Plan JSON policy gate

For fine-grained policy enforcement beyond simple resource counts, generate
a structured plan and run policies against it:

1. Generate the plan: `tofu plan -out=plan.tfplan`
2. Convert to JSON: `tofu show -json plan.tfplan > plan.json`
3. Run structured checks against `plan.json`:
   - "No changes to `cloudflare_zone_settings_override` unless approved"
   - "No deletes/replaces unless `allow-destroy` label present"
   - "Ruleset changes must only touch expected hostnames"
   - "Import-only PRs must show zero resource modifications"
   - "No remote object is imported to multiple addresses" (OpenTofu warns
     this leads to unwanted behavior)
   - "Only one `cloudflare_ruleset` per phase per zone" (single-owner check)

This catches "looks fine in text" mistakes that humans miss when scanning
large plan diffs. Implement using conftest/OPA or a simple `jq`-based
script. This gate is **required for import milestones** (M2–M5) and
recommended for all other PRs. It is a natural evolution of the
grep-based denylist toward full policy-as-code on parsed plan output.

**Milestone-scoped rules:** For import milestones, scope the policy to
only allow changes to resource types relevant to that milestone. For
example, an M2 PR should only touch `cloudflare_r2_bucket` + imports;
if the plan shows changes to DNS or rulesets, fail the check unless a
`scope-expansion` label is present. This prevents accidental scope creep
and makes review easier.

**Blast-radius declaration:** Every agent PR should include a
machine-readable expected outcome in the PR description (or a structured
file), declaring: expected resource types touched, expected
`to_add` / `to_change` / `to_destroy` counts, whether imports are
expected, and whether rulesets are touched. CI compares this declaration
against the structured plan and fails if they diverge. This makes review
much easier and catches "agent over-eagerness" early.

### Drift detection

Out-of-band changes (Cloudflare dashboard edits during incidents, provider
behavioral drift) will happen. A scheduled plan job on `main` catches this
early.

```yaml
name: 'Terraform Drift Detection'
on:
  schedule:
    - cron: '0 6 * * 1' # weekly on Monday at 06:00 UTC

jobs:
  drift-check:
    runs-on: ['self-hosted', 'Linux', 'x86-64-v2']
    env:
      BACKEND_CONFIG_FILE: ${{ vars.BACKEND_CONFIG_FILE }}
    steps:
      - uses: actions/checkout@v4
      - name: Decrypt credentials
        run: |
          install -m 600 /dev/null "$RUNNER_TEMP/ci-key"
          echo "${{ secrets.AGENIX_CI_PRIVATE_KEY }}" > "$RUNNER_TEMP/ci-key"
          CLOUDFLARE_API_TOKEN="$(age -d -i "$RUNNER_TEMP/ci-key" \
            machines/<machine>/secrets/cloudflare/api_token_plan.age)"
          echo "::add-mask::$CLOUDFLARE_API_TOKEN"
          echo "CLOUDFLARE_API_TOKEN=$CLOUDFLARE_API_TOKEN" >> "$GITHUB_ENV"
      - name: Detect drift
        run: |
          cd cloudflare && tofu init -backend-config="../$BACKEND_CONFIG_FILE"
          tofu plan -detailed-exitcode || {
            if [ $? -eq 2 ]; then
              echo "::warning::Drift detected! Infrastructure has changed outside of OpenTofu."
              # Optionally open a GitHub issue:
              # gh issue create --title "Infrastructure drift detected" --body "..."
            fi
          }
      - name: Cleanup
        if: always()
        run: rm -f "$RUNNER_TEMP/ci-key"
```

### Post-apply smoke tests

After every apply, automated checks verify that key endpoints work as
expected. This catches semantic errors that are syntactically valid (e.g.
wrong transform rule expression, wrong phase):

```bash
# Example: verify R2 custom domains serve index.html
for domain in api.example.com status.example.com; do
  status=$(curl -fsSL -o /dev/null -w '%{http_code}' "https://${domain}/")
  content_type=$(curl -fsSL -o /dev/null -w '%{content_type}' "https://${domain}/")
  if [ "$status" != "200" ] || [[ "$content_type" != *"text/html"* ]]; then
    echo "FAIL: https://${domain}/ — HTTP ${status}, Content-Type: ${content_type}"
    exit 1
  fi
  echo "PASS: https://${domain}/"
done
```

### Agent GitHub identity

When agents use the `gh` CLI to create branches and PRs, they act under a
GitHub identity. To limit risk:

- Use a dedicated GitHub App or bot account with minimal permissions:
  create branches, create/update PRs, read PR comments and CI status.
- The agent identity must **not** be able to: approve PRs, merge PRs, change
  GitHub Environment protection rules, or edit workflow files / CODEOWNERS.
- For changes in sensitive paths, require **2 human approvals** — the
  agent cannot substitute for a human reviewer. Sensitive paths include:
  - `bootstrap/**`
  - `.github/workflows/**`
  - `backends/**`
  - `.terraform.lock.hcl`
  - `cloudflare/**/ruleset*` (or wherever rulesets live)
  - `CODEOWNERS`

This ensures the separation of duties: agents write code, humans approve
and merge.

### Refactor safety (`moved` blocks)

After import milestones, agents may need to rename resources, reorganize
files, or switch from individual resource blocks to `for_each`. These
structural refactors can accidentally trigger destroy/recreate if the
resource address changes.

**Policy:** Any rename or structural refactor after import MUST include
`moved` blocks to preserve state continuity. Do not change `for_each`
keys after import unless you also provide `moved` blocks.

```hcl
# Example: renaming a resource after import
moved {
  from = cloudflare_r2_bucket.terraform_managed_resource_abc123
  to   = cloudflare_r2_bucket.apt
}

# Example: migrating from individual resources to for_each
moved {
  from = cloudflare_r2_bucket.apt
  to   = cloudflare_r2_bucket.this["apt"]
}
```

Prefer `moved` blocks over `tofu state mv` because:

- `moved` blocks are reviewable in PRs (code, not CLI commands).
- They are declarative and idempotent.
- They compose correctly with CI plan/apply workflows.
- After one successful apply, the `moved` blocks can be removed.

The plan safety gate will catch accidental replacements — but using
`moved` blocks prevents them from happening in the first place.

### Bootstrap layer separation

Infrastructure that the CI/CD pipeline depends on — the state backend
bucket, IAM roles, CI runner configuration, GitHub Environment settings,
and the agenix keypair — must **never** be managed by the same CI
pipeline or state file as agent-produced code. If a faulty agent change
destroys the state bucket or the CI runner IAM role, the pipeline cannot
run `tofu apply` to fix itself.

**Pattern:** Separate infrastructure into layers with independent state
files. Both layers use Terraform/OpenTofu, but the bootstrap layer is
applied manually by humans — never through the CI pipeline it enables:

| Layer                   | Contents                                                                             | Applied by                       | State            |
| ----------------------- | ------------------------------------------------------------------------------------ | -------------------------------- | ---------------- |
| **Layer 0 (bootstrap)** | State bucket, IAM, CI keypair, OIDC, break-glass roles                               | Human admin (`tofu apply` local) | Separate backend |
| **Layer 1+ (managed)**  | Everything else — cloud resources, application infra, SaaS and GitHub org governance | CI pipeline (agent PRs)          | CI-managed       |

The split is by _dependency_, not by importance or blast radius: Layer 0 is
what the pipeline needs in order to run, and nothing else. A large, org-wide,
high-consequence root is still Layer 1+ — plan review, the sensitive-change
label, and the destroy/replace gates are what bound it. See
[root layering](./Terraform-Root-Layering.md#which-layer-a-root-belongs-to).

The critical property is **state isolation**: the bootstrap state is
never touched by the CI pipeline, so agent-produced code cannot corrupt
or destroy it. Even if Layer 1 state becomes unrecoverable, the bootstrap
infrastructure remains intact and humans can rebuild Layer 1 from scratch.

**Bootstrap layer setup:**

1. Create a `bootstrap/` directory with its own backend configuration
   (separate GCS prefix, separate bucket, or even local state).
2. **Exclude `bootstrap/` from CI triggers** — the CI workflow path
   filters must not include `bootstrap/**`. Changes to `bootstrap/` are
   reviewed and applied manually by human admins.
3. Apply manually: `cd bootstrap && tofu plan && tofu apply`.
4. Use `prevent_destroy = true` on critical resources (state bucket,
   OIDC provider, CI runner role) so that an accidental `tofu destroy`
   requires explicit override.
5. Add `bootstrap/` to CODEOWNERS requiring infrastructure admin approval.
6. Keep a separate "break-glass" IAM role (with MFA) that allows human
   admins to apply any layer manually in an emergency, independent of
   the CI pipeline credentials.

> **Why not just CLI commands?** Using Terraform for the bootstrap layer
> (instead of raw `gcloud` / `aws` CLI commands) gives you state tracking,
> drift detection, and reproducibility for these critical resources. The
> tradeoff is a small chicken-and-egg at initial setup: the very first
> `tofu apply` uses local state, then migrates to remote after the bucket
> exists. After that one-time bootstrap, the layer is self-contained.

**Recovery procedure when CI is broken:**

1. Authorized admin clones the repo and authenticates using break-glass
   credentials (stored in a secure vault, not in CI).
2. Runs `tofu init` and `tofu plan` / `tofu apply` locally, targeting
   the broken layer.
3. Commits the fix so that CI (once restored) does not revert the manual
   change. Terraform has no native rollback — recovery is always a
   roll-forward (apply a known-good configuration).

### Version pinning

Repositories using this methodology pin all tooling via a **Nix flake**
(`flake.nix` + `flake.lock`) — including `opentofu`, `terranix`,
cloud-provider CLIs, `agenix`, `age`, and other dev shell dependencies. Both local development (`nix develop`)
and CI self-hosted runners use the same flake, so tool versions are
identical everywhere. The `update-flake-lock.yml` workflow proposes
`flake.lock` updates as reviewed PRs (weekly or on upstream push), ensuring
upgrades are deliberate and auditable.

What the Nix flake does **not** pin is the Terraform **provider** version.
That is handled by Terraform's own mechanisms:

- **Pin provider versions** in `required_providers` (e.g. `~> 5.1`).
- **Commit `.terraform.lock.hcl`** to version control after the first
  `tofu init`. This locks the exact provider build hash and ensures
  reproducible plans across machines.
- **Upgrade providers via dedicated PRs** so upgrades get their own plan
  review. The flake lock update workflow already models this pattern for
  Nix inputs — provider upgrades follow the same discipline.

### Backend secrets

**Hard rule:** Never place credentials or sensitive values in
`backends/*.hcl` files or pass them via `-backend-config` on the command
line. OpenTofu writes backend configuration supplied this way in plain
text to local files, and backend information can end up in plan
artifacts. Backend config files should contain only non-secret values
(bucket name, prefix). Authentication to the backend should use
environment variables (`GOOGLE_APPLICATION_CREDENTIALS`), Workload
Identity Federation, or `gcloud auth application-default login` — never
inline credentials.

### Human cloud credential profiles

Human-operated bootstrap and break-glass commands need a credential selection
mechanism that is ergonomic, auditable, and safe to reuse across many
infrastructure repositories. The standard pattern is:

1. Use one local CLI profile per repository, cloud account, and privilege
   level. Example AWS names: `example-prod-admin`, `example-prod-readonly`,
   `customer-a-bootstrap`. Avoid relying on the ambient default profile.
2. Have the Nix dev shell select the repository's default human profile by
   exporting the provider-specific profile environment variable, such as
   `AWS_PROFILE`, and print the selected profile when the shell starts.
3. Make credentialed scripts fail loudly when the expected profile variable is
   missing. This usually means the command is running outside the repository
   dev shell or the operator has not made an explicit profile choice.
4. Keep deployment facts in git, not in the operator environment. Account ID,
   region, state backend names, repository identity, protected branch names,
   and notification recipients are part of the deployment contract. Scripts
   should compare the authenticated caller identity with the tracked account ID
   before running a credentialed plan or apply.
5. Keep `.env` files gitignored and limited to local operator overrides such
   as choosing a different profile for this checkout. Do not put deployment
   facts, tokens, state backend secrets, or provider credentials in `.env`.
6. Prefer short-lived, browser- or identity-provider-backed credentials over
   long-lived access keys. For AWS accounts that do not use IAM Identity
   Center, prefer `aws login --profile <profile> --region <region>` with AWS
   CLI v2.32.0 or newer. IAM Identity Center (`aws sso login`) remains a valid
   alternative when the account is configured for it.
7. Assume not every Terraform/OpenTofu provider or wrapper understands the
   cloud CLI's newest profile format. If necessary, export short-lived
   credentials into the subprocess environment immediately before invoking
   OpenTofu. For AWS console-login profiles, use:

   ```bash
   eval "$(aws configure export-credentials --profile "$AWS_PROFILE" --format env)"
   tofu plan
   ```

   Never print this output, commit it, or store it in a file. Treat it as
   process-local credential material.

8. For stronger separation between different customers or companies, profile
   names are usually enough. If hard local isolation is required, set
   provider-specific config/cache locations per checkout, such as
   `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE`, and
   `AWS_LOGIN_CACHE_DIRECTORY`.

For AWS console-login profiles, the non-secret profile mapping lives in
`~/.aws/config` and temporary login cache material lives under
`~/.aws/login/cache` by default. Those locations are workstation state, not
repository state.

---

## Agent Prompt Guidelines

When instructing an AI agent to work on Terraform modules, include these
guidelines in the prompt or in a `CLAUDE.md` file:

```markdown
## Terraform development rules

- You do NOT have cloud credentials. Do not attempt `tofu plan` or
  `tofu apply` with real providers.
- Always run `tofu validate` and `tofu test` before opening a PR.
- Every new resource or module must have a `.tftest.hcl` file with
  `mock_provider` tests.
- Use `command = plan` in test run blocks (never `apply` against real
  providers).
- Do not commit `.tfstate` files, `.tfvars` files, or credentials.
- Do not inspect, print, or modify local cloud credential caches such as
  `~/.aws/login/cache`. Human credential setup belongs in runbooks and
  operator scripts, not in agent-authored infrastructure changes.
- Follow the existing naming conventions and directory structure.
- Include a clear PR description explaining the intent and expected
  infrastructure changes.
- If `tofu validate` or `tofu test` fails, fix the issue before
  opening the PR. Do not skip or disable tests.
- No opportunistic refactors: do not rename resources, reorganize
  files, or "clean up" code outside the scope of the current task.
  Import PRs must contain only resource blocks + import blocks.
  Cleanup and refactors go in separate follow-up PRs.

## CI monitoring rules

- After opening or pushing to a PR, wait for CI to complete:
  gh run watch
- Check the result:
  gh run view --json conclusion,jobs
- If CI failed, read the logs and fix:
  gh run view --log-failed
- After CI passes, read the plan comment:
  gh pr view --comments
- Verify the plan shows ONLY the expected changes. If there are
  unexpected diffs (wrong attributes, unintended destroys, extra
  resources), fix the .tf files, push, and wait for CI again.
- Repeat until:
  1. All CI checks are green.
  2. The plan comment matches the intended infrastructure change.
- Then mark the PR as ready for human review:
  gh pr ready
- Do NOT approve or merge the PR yourself.
```

---

## Security Model Summary

| Actor          | Provider credentials | Can plan            | Can apply | Can approve |
| -------------- | -------------------- | ------------------- | --------- | ----------- |
| AI agent       | None                 | Offline only (mock) | No        | No          |
| CI (PR job)    | Read-only (`plan`)   | Yes                 | No        | No          |
| CI (merge job) | Read-write (`apply`) | Yes                 | Yes       | No          |
| Human reviewer | None (sees plan)     | No                  | No        | Yes         |

The key insight: **no single actor can both produce and approve an
infrastructure change.** The agent writes code, CI produces the plan,
and a human approves it. This separation of duties prevents accidental
or malicious provisioning.

Additional security boundaries:

- **Token isolation:** The read-only plan token cannot modify resources
  even if leaked. The write token is only accessible in the GitHub
  Environment associated with the target deployment branch.
- **Action SHA pinning:** All third-party GitHub Actions are pinned by
  commit SHA to prevent supply-chain compromises via tag mutation.
- **Denylist policy:** CI blocks `data "external"`, `local-exec`,
  `remote-exec`, `null_resource`, and unpinned remote module sources
  that could execute arbitrary code during plan or introduce
  supply-chain risk.
- **Plan safety gates:** Destructive plans (delete/replace) require an
  explicit `allow-destroy` label. Sensitive resource changes (rulesets,
  zone settings) require a `sensitive-change` label.
- **Plan JSON policy gate:** Structured plan analysis via `tofu show -json`
  enables fine-grained policy checks beyond simple resource counts.
  Required for import milestones (M2–M5).
- **Drift detection:** A scheduled plan on `main` alerts when
  infrastructure drifts from the committed configuration.
- **PR trust boundary:** Credentialed plan runs in a separate job that is
  skipped entirely for fork PRs (job-level guard). Fork PRs run offline
  checks on GitHub-hosted runners only. CODEOWNERS requires a qualified
  reviewer for infra changes.
- **Runner hardening:** Self-hosted runners must be ephemeral (destroyed
  after each job), restrict network egress, and use a dedicated runner
  group. Fork PRs must never run on self-hosted runners.
- **Agent identity:** Agents use a dedicated GitHub App with minimal
  permissions (create branches/PRs only). They cannot approve PRs, merge,
  or change deployment controls.
- **Refactor safety:** Post-import renames and structural changes require
  `moved` blocks to prevent accidental destroy/recreate.
- **Bootstrap layer separation:** CI prerequisites (state bucket, IAM,
  keypair) live in a separate state from agent-managed resources and are
  applied manually by human admins. Agent-produced code cannot break the
  infrastructure needed to roll it back.

---

## Iterative Development Loop

The typical development cycle when an agent is working on a task:

```
 1.  Agent receives task (e.g. "add DNS record for api.example.com")
 2.  Agent reads existing .tf files and tests
 3.  Agent writes/modifies .tf files
 4.  Agent writes .tftest.hcl with mock_provider
 5.  Agent runs: tofu init -backend=false
 6.  Agent runs: tofu validate
     ├─ FAIL → agent fixes the issue, go to step 5
     └─ PASS ↓
 7.  Agent runs: tofu test
     ├─ FAIL → agent fixes the issue, go to step 5
     └─ PASS ↓
 8.  Agent opens PR:
       gh pr create --title "Add DNS record for api" --body "..."
 9.  Agent waits for CI:
       gh run watch
10.  Agent reads CI result:
       gh run view --json conclusion,jobs
     ├─ CI FAILED → agent reads logs:
     │    gh run view --log-failed
     │    agent fixes the issue, pushes, go to step 9
     └─ CI PASSED ↓
11.  Agent reads plan comment:
       gh pr view --comments
     ├─ Plan shows unexpected changes → agent fixes, pushes, go to step 9
     └─ Plan is clean ↓
12.  Agent marks PR as ready for review (if draft):
       gh pr ready
13.  Human reviews plan comment + code diff, approves and merges
14.  Merge → CI applies to the target branch's environment
15.  If testing/staging exists: verify there, then promote by merging onward
     If no lower environment exists: merge to the production branch directly
```

Steps 2–7 happen entirely offline with no credentials. Steps 8–12 use
only the `gh` CLI (which requires a `GITHUB_TOKEN` but no cloud
credentials). The agent can iterate as many times as needed without any
risk to live infrastructure.

### `gh` commands reference for agents

| Task                       | Command                                              |
| -------------------------- | ---------------------------------------------------- |
| Create a PR                | `gh pr create --title "..." --body "..."`            |
| Create a draft PR          | `gh pr create --draft --title "..." --body "..."`    |
| Watch a running workflow   | `gh run watch`                                       |
| View workflow result       | `gh run view --json conclusion,jobs`                 |
| Read failed step logs      | `gh run view --log-failed`                           |
| Read PR comments (plan)    | `gh pr view --comments`                              |
| Read a specific PR comment | `gh api repos/{owner}/{repo}/issues/{pr}/comments`   |
| Push a fix                 | `git add -A && git commit -m "fix: ..." && git push` |
| Mark PR as ready           | `gh pr ready`                                        |
| Check PR status checks     | `gh pr checks`                                       |

---

## Useful Links

- [OpenTofu test command](https://opentofu.org/docs/cli/commands/test/)
- [OpenTofu mock providers](https://developer.hashicorp.com/terraform/language/tests/mocking)
- [Terranix — Nix to Terraform JSON](https://terranix.org/)
- [dflook/tofu-plan](https://github.com/dflook/tofu-plan) — GitHub Action for plan-as-PR-comment
- [dflook/tofu-apply](https://github.com/dflook/tofu-apply) — GitHub Action for gated apply
- [GitHub Environments](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
- [AWS CLI console login](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html)
- [AWS CLI export-credentials](https://docs.aws.amazon.com/cli/latest/reference/configure/export-credentials.html)
- [Terraform Testing Guide](Terraform-Testing.md)

Project-specific guides (in consuming repositories):

- Access token setup — see the consuming repo's contributor docs
- Provider bootstrapping — see the consuming repo's bootstrapping guide
