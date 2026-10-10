# Shared Cloudflare Terraform library

Company-agnostic tooling for adopting and managing Cloudflare via
Terraform/OpenTofu. Consumers supply their own zones, accounts, and reviewed
adoption set; this directory ships reusable inventory, token, and import
tooling. See the [import-phase methodology](../../docs/Terraform-Import-Phase.md).

## `cloudflare-inventory` — read-only inventory

Captures the live Cloudflare state (zones, DNS, Pages projects/domains, R2
buckets, account-scoped resources) into `.result/` as raw JSON plus a redacted
Markdown inventory. Read-only (GET only); never prints credentials.

```bash
# API token (preferred)
CLOUDFLARE_API_TOKEN=… CF_ZONES="example.com example.dev" \
  "${nixos-modules-tf}/terraform/cloudflare/cloudflare-inventory" --account-id <id>

# or interactive Wrangler login
"${nixos-modules-tf}/terraform/cloudflare/cloudflare-inventory" --login --zone example.com
```

Nothing is hardcoded: pass `--zone` (repeatable) or `CF_ZONES`, `--account-id`
(repeatable) or `CF_ACCOUNT_ID`, `--all-zones` for every accessible zone, and
`CF_WRANGLER_CMD` / `CF_WRANGLER_SCOPES` to tune the Wrangler fallback.

## `cloudflare-token` — parametric API-token deep-links (shared engine)

Builds a Cloudflare dashboard "create token" deep-link whose **permission groups
are derived from the `cloudflare_*` resource types a repo actually manages** —
least-privilege by construction, no per-repo scope list to maintain. The canonical
`resource-type → permission-group` mapping lives in the script; each infra repo
(metacraft / agent-harbor / blocksense) calls it with only its token **name** +
account/zone.

```sh
cloudflare-token plan  --scan terraform/cloudflare/metacraft-prod --name "Metacraft Terraform" --open
cloudflare-token apply --scan terraform/cloudflare/metacraft-prod --name "Metacraft Terraform"
cloudflare-token import --scan terraform/cloudflare/metacraft-prod --name "Metacraft Terraform"
```

`--scan DIR` discovers managed types from the root's `resource "…"` / `to = …`
blocks; `--resource-types a,b` overrides. `plan` = read on every managed group,
`apply` = edit on writable groups + `zone:read`, `import` = broad read for
inventory. Managing zone-level settings? add `--zone-writable`.

## `mail-auth.nix` — mail DNS records from a JSON data file

A Terranix helper that renders a domain's mail records for Cloudflare zones —
DKIM keys and, from data version 2, MX, SPF, DMARC and the Google
site-verification token — from a data file the consumer keeps in its root. It
is the Terraform half of the
[Google Workspace DKIM runbook](../../docs/Google-Workspace-DKIM.md) and the
[Google Workspace domains runbook](../../docs/Google-Workspace-Domains.md),
whose `google-workspace-dkim publish` and `google-workspace-domains onboard`
tools edit the same file. The version-1 shape below is still accepted and
renders exactly as before; the helper's header documents version 2 in full.

```json
{
  "version": 1,
  "domains": {
    "example.com": {
      "zone_id": "<32 hex>",
      "dkim": { "google": "v=DKIM1; k=rsa; p=MIIB…" }
    }
  }
}
```

```nix
let
  devops-modules = builtins.fetchGit {
    url = "https://github.com/metacraft-labs/devops-modules";
    rev = "<a revision carrying mail-auth.nix>";
  };
  mailAuth = import "${devops-modules}/terraform/cloudflare/mail-auth.nix" {
    data = builtins.fromJSON (builtins.readFile ./mail-auth.json);
    resourceName = "mail_auth_dkim"; # default
    comment = "DKIM (docs/runbooks/…)"; # optional
  };
in
{
  imports = [ mailAuth ];
  # … the rest of the root
}
```

It renders one `resource.cloudflare_dns_record.<resourceName>` (provider v5)
with a `for_each` keyed `"<selector>._domainkey.<domain>|TXT"`: TXT, unproxied,
`ttl = 1` (automatic), `comment`. Addresses are therefore
`cloudflare_dns_record.mail_auth_dkim["google._domainkey.example.com|TXT"]`, and
they are stable — adding a domain or a selector adds one address and re-keys
none. With no DKIM value anywhere it renders nothing at all, so declaring
domains before their keys exist leaves the plan unchanged. Values are one
unquoted string each; Cloudflare splits values over 255 characters on the wire.

Evaluation fails, naming the entry, on an unknown `version`, a zone id that is
not 32 lowercase hex, a domain or selector that is not a lowercase DNS name or
label, and a value that does not start with `v=DKIM1;` or uses a character
outside the DKIM tag alphabet (which also keeps Terraform template sequences
out of the rendered JSON).

**Version 2** adds, per domain, `google_verification` (a list of
`google-site-verification=…` values), `mx` (`[{priority, host}]`), `spf`
(`{include, all}`), `dmarc` (`{p, sp?, pct?, rua?, ruf?, fo?, adkim?, aspf?}`)
and `zone_lookup` (the key of a consumer-declared `data "cloudflare_zone"`, in
place of `zone_id`). They render into a second resource,
`cloudflare_dns_record.<recordsResourceName>` (default `mail_auth`), keyed
`<domain>|MX|<n>` (by position: a changed host is an in-place update),
`<domain>|TXT|spf`, `<domain>|TXT|<verification value>`, `_dmarc.<domain>|TXT`
and, for DMARC reports sent to another declared domain,
`<domain>._report._dmarc.<report-domain>|TXT`. Non-DKIM TXT values are rendered
as one quoted string. A `zone_lookup` domain's records go to
`mail_auth_<key>` / `mail_auth_dkim_<key>` with
`zone_id = "${data.cloudflare_zone.<key>.id}"`, so an offline plan that excludes
the lookup loses only those.

Tested by `nix build .#checks.<system>.cloudflare-mail-auth`
([`tests/mail-auth.nix`](./tests/mail-auth.nix): key stability, empty
rendering, attribute values, each refusal, for both versions; plus comparisons
of [`tests/mail-auth/data.json`](./tests/mail-auth/data.json) and
[`data-v2.json`](./tests/mail-auth/data-v2.json)'s renderings with the reviewed
[`expected.json`](./tests/mail-auth/expected.json) and
[`expected-v2.json`](./tests/mail-auth/expected-v2.json), and of the tools'
`scripts/lib/mail-auth.jq` addresses with the rendering).

## `cloudflare-import-blocks` — shared import-block generator

Emits credential-free `import {}` blocks for a Cloudflare root from the root's
reviewed **import-id data model**, `terraform/cloudflare/<name>-prod/import-ids.json`:

```json
{
  "version": 1,
  "imports": [
    {
      "to": "cloudflare_dns_record.this[\"apex\"]",
      "id": "<zone_id>/<record_id>"
    },
    {
      "to": "cloudflare_r2_bucket.this[\"downloads\"]",
      "id": "<account_id>/downloads/default"
    }
  ]
}
```

```bash
"${nixos-modules-tf}/terraform/cloudflare/cloudflare-import-blocks" \
  --config cloudflare/<name>-prod --root-dir "$PWD" --scope all
# --scope accepts: all, an alias (dns|pages|r2|workers|zones), or ANY concrete
# cloudflare_<type> (e.g. cloudflare_load_balancer) for a selective import.
```

Orgs manage entirely different Cloudflare surfaces — different resource **types**,
instance **counts**, and mixes (one runs Pages + R2; another load balancers,
Zero Trust, D1, Queues). The generator is agnostic to that: it emits exactly what
the reviewed `default.nix` / `import-ids.json` declare, `--scope all` always emits
everything, and any `cloudflare_<type>` can be imported selectively. A per-type
count is printed so you can confirm your org's resources were captured.

Output lands in `.result/terraform/cloudflare/<name>-prod/imports.tf` and is
**never committed** (committed blocks make OpenTofu's mocked `tofu test` attempt
real imports). The **adoption set is per-repo data** — each org's zones, DNS
records, Pages projects, and R2 buckets differ — so `import-ids.json` lives in
the repo, but the **generator is shared** (engine/config split, mirroring GitHub
governance).

## `cloudflare-import-ci` — shared import-only apply harness

The `plan|apply` harness that the dispatchable `cloudflare-import.yml` workflow
runs: renders the Terranix root, regenerates the import blocks into `.result/`,
`tofu init` against the S3 backend, plans with `-detailed-exitcode`, counts
import/add/change/destroy/replace, and **refuses any plan that is not
import-only** (≥1 import, 0 of everything else). `apply` mode additionally
requires the typed confirmation `apply-reviewed-imports`. Company-agnostic: the
root/config/backend/token come from the environment. See the
[import-phase methodology](../../docs/Terraform-Import-Phase.md).

## Consuming the reusable import workflow

The harness + generator are driven by the shared
`.github/workflows/reusable-cloudflare-import.yml`. Each consumer repo adds a
thin caller (`.github/workflows/cloudflare-import.yml`) — this is the entire
per-repo surface; blocksense (the third org) copies it verbatim and changes only
the four `with:` data values:

```yaml
name: Cloudflare Import
on:
  pull_request:
    branches: [live]
    paths:
      [
        'terraform/cloudflare/**',
        'backends/cloudflare-*',
        '.github/workflows/cloudflare-import.yml',
      ]
  workflow_dispatch:
    inputs:
      mode: { type: choice, options: [plan, apply], default: plan }
      scope:
        {
          type: choice,
          options: [all, dns, pages, r2, workers, zones],
          default: all,
        }
      confirm_apply: { type: string, required: false }
jobs:
  import:
    uses: metacraft-labs/devops-modules/.github/workflows/reusable-cloudflare-import.yml@dev
    with:
      root_config: cloudflare/<name>-prod
      backend_config_file: backends/cloudflare-<name>-prod.hcl
      agenix_plan_secret_path: machines/ci/secrets/cloudflare/api_token_plan.age
      agenix_apply_secret_path: machines/ci/secrets/cloudflare/api_token_apply.age
      mode: ${{ inputs.mode }}
      scope: ${{ inputs.scope }}
      confirm_apply: ${{ inputs.confirm_apply }}
    secrets:
      AGENIX_CI_PRIVATE_KEY: ${{ secrets.AGENIX_CI_PRIVATE_KEY }}
      NIX_GITHUB_TOKEN: ${{ secrets.NIX_GITHUB_TOKEN }}
```

Prerequisites in the consumer repo: a Terranix root at
`terraform/<name>-prod/default.nix` (hand-authored `for_each` over the reviewed
inventory), `import-ids.json`, a committed `.terraform.lock.hcl`, a `just
build-terranix <config>` target, the AWS OIDC `AWS_TERRAFORM_{PLAN,DRIFT,APPLY}_ROLE_ARN`
vars, and the `AGENIX_CI_PRIVATE_KEY` secret.
