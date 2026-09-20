# Terraform Import / Adoption Phase

Company-agnostic methodology for adopting **existing** infrastructure into
Terraform without recreating it — the one-time "import phase" every infra repo
goes through before steady-state management. It complements the
[bootstrap runbook](./Terraform-Bootstrap-Runbook.md) (which stands up Layer 0
from nothing) and the
[methodology](./Terraform-Agent-Development-Methodology.md): bootstrap creates
net-new state/roles; the import phase brings **already-existing** org resources
(GitHub repos/teams/settings, Cloudflare zones/DNS/R2, …) under management.

The guiding principle: **inventory with read-only credentials, model the
reviewed reality as data, generate import blocks with no credentials, prove the
plan is import-only, then apply once.** Steady-state changes afterward use the
normal PR/plan/apply workflow.

## The ladder (M0 → M7)

Each stage is gated on the previous one. Stages M1 and M6 are the only ones that
touch credentials; everything in between is offline and reviewable in a PR.

### M0 — Boundary and change freeze

Pick the exact resource surface to adopt (one provider/root at a time) and
freeze manual changes to it while the import is in flight. Record who holds the
operator credentials and which account/org owns the state backend. Adoption is
per-root: do GitHub governance and Cloudflare as separate passes.

### M1 — Read-only inventory _(credentials)_

Run the shared inventory tool with **read-only** operator credentials to capture
the live state. Output is raw JSON plus a redacted human-readable summary under
`.result/` (never committed); secret **values** are never read — only names and
metadata.

```bash
# GitHub (needs gh auth or GITHUB_TOKEN with org read)
GITHUB_OWNER=<org> "${nixos-modules-tf}/terraform/github/github-inventory" --owner <org> --all-repos
# Cloudflare (needs CLOUDFLARE_API_TOKEN or `--login`)
CF_ZONES="<zone-a> <zone-b>" "${nixos-modules-tf}/terraform/cloudflare/cloudflare-inventory" --account-id <id>
```

Review the redacted `inventory.md` — this is the human checkpoint that decides
what is in scope.

### M2 — Reviewed data model

Translate the reviewed inventory into a **committed data model** in the repo:

- GitHub: `terraform/github/<org>-governance-prod/governance.nix` — the repos,
  teams, memberships, branch protection, Environments, Actions permissions and
  variables, and labels to manage. Feeds the shared
  [`governance.nix` engine](../terraform/github/README.md). The governance root
  is a **managed** root: org policy is not something the pipeline depends on to
  run, so it lives under `terraform/` and is PR-driven (see
  [root layering](./Terraform-Root-Layering.md#which-layer-a-root-belongs-to)).
  During M5/M6 it is held out of the steady-state matrix by
  `adoption_pending: true`, not by living in `bootstrap/`.
- Cloudflare: `terraform/cloudflare/<name>-prod/inventory.md` — the reviewed
  zones/DNS/Pages/R2 adoption set (Cloudflare's adoption set is inherently
  per-repo data).

Anything intentionally left out is recorded as **deferred** so the exclusion is
explicit, not an oversight.

### M3 — Secret backup and rotation

Before importing secret resources, back up and (where policy requires) rotate the
underlying credentials into agenix `.age` files. Secret **values** never enter
Terraform state as plaintext — only GitHub-encrypted payloads (M4). See the
per-repo secret manifest (`secrets/manifest.nix`) and the
[secret-rotation methodology](./GitHub-Secret-Rotation.md).

### M4 — Encrypted payload rendering

Render the GitHub-encrypted (libsodium sealed-box) payloads from the `.age`
sources with `github-governance-secrets-render`, producing the
`secrets/payloads.generated.nix` + `secrets/managed.generated.nix` the engine
consumes. This keeps plaintext out of state and out of the process table.

### M5 — Generate import blocks _(no credentials)_

Generate credential-free `import {}` blocks from the reviewed data model:

```bash
"${nixos-modules-tf}/terraform/github/github-governance-import-blocks" \
  --owner <org> --root-config github/<org>-governance-prod \
  --root-dir "$PWD" --scope all
```

The output lands in `.result/terraform/github/<org>-governance-prod/imports.tf`
(the generator mirrors whichever layer holds the root) and is **never committed** — its presence would make OpenTofu's mocked test
context attempt provider imports, breaking offline tests. Each root's
`IMPORTS.md` documents the resource-class-by-resource-class import IDs and an
imperative `tofu import` fallback.

Only resources that already exist on GitHub may get an import block: an import
of something absent fails the entire plan, not just that resource. For most
classes existence is implied by a server-assigned `id` in the model, and the
generator skips id-less entries so the first apply creates them instead.
Branch protections have no such id — theirs is the derivable `<repo>:<pattern>`
— so a declared-but-not-yet-created one must say so explicitly:

```nix
{
  repository = "new-repo";
  pattern = "dev";
  exists = false; # no import block; the first apply creates it
  # ...
}
```

Without it the plan aborts with `could not find a branch protection rule with
the pattern '<pattern>'`, and no other resource in the root can be planned.
Drop the `exists = false` once the rule has been created.

For Cloudflare, the shared `cloudflare-import-blocks` generator does the same
from the root's reviewed **import-id data model** — `import-ids.json`, a list of
`{ "to": "<resource address>", "id": "<composite Cloudflare id>" }` captured from
the M1 inventory (the address matches the Terranix `for_each` key; the id is the
Cloudflare composite id, e.g. `<zone_id>/<record_id>`):

```bash
"${nixos-modules-tf}/terraform/cloudflare/cloudflare-import-blocks" \
  --config cloudflare/<name>-prod --root-dir "$PWD" --scope all
```

Output lands in `.result/terraform/cloudflare/<name>-prod/imports.tf` and is
**never committed** for the same reason. The generator is shared; the id data
model is per-repo (each org's zones/records differ) — the same engine/config
split as GitHub governance.

### M6 — Import-only apply _(credentials, gated)_

Run the protected apply path — a dispatchable `workflow_dispatch` job
(`github-governance-import.yml` / `cloudflare-import.yml`), or the equivalent
`just` target. Each provider has a shared import-only apply harness —
`github-governance-import-ci` and `cloudflare-import-ci` — and both **refuse any
plan that is not import-only**: ≥1 import action, exactly 0 add/change/destroy/
replace, and (for apply) a typed confirmation (`apply-reviewed-imports`). This is
the safety property that makes the import phase a true no-op adoption: state
changes, reality does not. The PR-mode job posts the import/add/change/destroy/
replace count table as an idempotent PR comment; it never commits generated
files.

The only permitted non-import creates are the GitHub governance-app org secrets
(`GH_GOVERNANCE_APP_*`), bootstrapped separately via
`just github-governance-app-secrets-apply` — and a consumer that bootstraps them
through that targeted path, rather than through the governance plan, permits
_none_, so its allow-set is legitimately empty.

**This gate is an M6 fixture, not the steady-state design.** It exists to make
adoption a provable no-op: state changes, reality does not. It has nothing to
say about ordinary governance changes, and it must not be widened to let them
through. A change that genuinely adds or updates resources is not part of the
import — it is an M7 change and goes through the normal PR plan/apply path,
with the reusable workflow's own destroy/replace/policy/sensitive gates. If the
reviewed model carries entries that do not exist yet (no import id, so they
plan as creates), do not relax the gate for them: land them as an ordinary PR
after M6. Leaving them in the import run is what makes an import plan
unappliable.

### M7 — Drift detection and steady state

Once imported, remove `adoption_pending: true` from the root's `metadata.json`
so it **rejoins the steady-state CI matrix**. During M5/M6 the root carries that
flag, which excludes it from the steady-state `terraform-ci-matrix` — otherwise a
steady-state plan/apply on the still-empty state would try to (re)create the live
resources the import is adopting. With the flag removed, the normal workflow
takes over: changes land as PRs, plan on PR, apply on merge through the
`production` Environment. The import blocks are not needed again unless you adopt
a new resource class — regenerate on demand.

## Why import blocks are never committed

The generated `imports.tf` lives only under `.result/` (gitignored). The
adoption is a one-time bootstrap enforced by **process** (the import-only apply
gate), not by committing then deleting files. This keeps the repo's offline
`tofu test` clean, because mocked test runs would otherwise try to import.

## Why config is hand-authored data, not `-generate-config-out`

Resource configuration is authored as **reviewed data** — Terranix `for_each`
over the inventory attrsets in the root's `default.nix` — and **never** via
`tofu plan -generate-config-out`. `generate-config-out` emits an unreviewed
provider dump, couples authoring to live (write-capable) credentials, and
produces flat raw HCL that diverges from the data-model style the rest of the
estate uses. Modelling the reviewed reality as data and proving safety through
the import-only gate is what makes adoption a true no-op; `-generate-config-out`
appears nowhere in the methodology by design. A Cloudflare root therefore ships
a Terranix `default.nix` (hand-authored `for_each` over the reviewed inventory)
plus `import-ids.json` — not committed `.tf` resource bodies and not committed
import blocks.

## What is shared vs per-repo

| Piece                                                                                                                                     | Where                                                   |
| ----------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| Inventory tools, GitHub **and** Cloudflare import-block generators, import-only CI harnesses                                              | shared — `nixos-modules/terraform/{github,cloudflare}/` |
| This methodology + root-layering                                                                                                          | shared — `nixos-modules/docs/`                          |
| `governance.nix` data model, Cloudflare `default.nix` + `import-ids.json`, `inventory.md`, `IMPORTS.md`, secret manifest, `.age` material | per-repo (the org's reviewed reality)                   |

Both providers use the same engine/config split: the import-block generator and
the import-only apply harness are **shared** (`github-governance-import-{blocks,ci}`,
`cloudflare-import-{blocks,ci}`); the reviewed adoption data is **per-repo** —
GitHub's `governance.nix` and Cloudflare's `default.nix` + `import-ids.json`
(each org's zones and accounts differ). This is the symmetry to preserve when a
third org adopts the workflow: never fork the engine, only supply new data.

Crucially, orgs manage **entirely different resource surfaces** — not just
different values, but different resource **types**, instance **counts**, and mixes
(one org runs Pages + R2; another runs load balancers, Zero Trust, D1, Queues).
The engine is agnostic to this by construction: the generator emits exactly what
the per-repo `default.nix` / `import-ids.json` declare, `--scope` accepts any
`cloudflare_<type>` (not a fixed taxonomy), and the import-only harness counts
plan actions generically. The one place types map to shared knowledge is the
**token-scope engine** (`cloudflare-token`), which derives API permission groups
from the managed resource types via a canonical table and **warns loudly on any
type it does not yet know** — the fix is to extend that shared table (every org
benefits), never to fork it per repo.
