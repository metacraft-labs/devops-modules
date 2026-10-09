# Google Workspace domains

Company-agnostic procedure for putting another domain on an existing Google
Workspace tenant so that it **receives and sends** mail: add it as a domain
alias, prove ownership through DNS, move its MX to Google, and publish SPF,
DMARC and DKIM for it — with every DNS change going through a Terraform-managed
Cloudflare zone and a reviewed PR. Each infra repo keeps a thin overlay with its
own facts: the domains, the data file, the parent domain, the report mailbox.

Time: one command per domain, plus two rounds of CI and DNS propagation, plus
two console clicks Google has no API for (Activate Gmail, and DKIM's).

> [!NOTE]
> The commands below assume `google-workspace-domains`, `google-workspace-dkim`
> and `gcloud` are on `PATH`: they are in this repository's dev shell, and a
> consumer repo gets them by adding
> `inputs'.nixos-modules.packages.workspace-admin-tools` to its own dev shell.
> Outside one, prefix a command with
> `nix run github:metacraft-labs/devops-modules#google-workspace-domains --`.

## 1. Run the tool

```sh
google-workspace-domains onboard \
  --domain example.org --parent example.com \
  --data terraform/cloudflare/<root>/mail-auth.json \
  --key "$KEY" --subject admin@example.com \
  --post-edit '<the root census hook>' --dmarc-rua dmarc@example.com --merge
```

A consumer wraps this in a recipe (`just google-domain-onboard <domain>` or
similar) that fills in everything but the domain. `--key` is the decrypted
service-account key of
[Google-Workspace-Admin-API-Access.md](./Google-Workspace-Admin-API-Access.md),
`--subject` the super admin it acts as; `$GOOGLE_WORKSPACE_KEY` and
`$GOOGLE_WORKSPACE_SUBJECT` work too. Re-running is safe at any point: every
step checks whether it is already done, a change already on the base branch
skips to its DNS wait, and an open PR for the same change is resumed.

Afterwards, and at any time:

```sh
google-workspace-domains status --domain example.org --data …/mail-auth.json [--key … --subject …]
google-workspace-domains status --all --data …/mail-auth.json
```

prints, per domain, whether the tenant has it and has verified it, and whether
public DNS serves the MX, SPF, DMARC, verification and DKIM records the data
file declares. It exits non-zero on any difference.

**Before the first run**, once per domain, the domain has to be **declared** in
the data file with its Cloudflare zone (§4) — a person's reviewed change, like
the DKIM tool's. The tool refuses an undeclared domain and prints the `jq` that
declares it.

**Prerequisites.**

- The delegation of the service account includes
  `https://www.googleapis.com/auth/admin.directory.domain` and
  `https://www.googleapis.com/auth/siteverification` (§5), and its project has
  the Site Verification API enabled (`google-workspace-dwd setup` enables it).
- `--subject` is a **super admin**: adding a domain and verifying it are
  super-admin privileges, and the verification token is issued to that user.
- `gh auth login`, with permission to open PRs on the consumer repo.

## 2. What `onboard` does, step by step

**2.1 Add the domain alias.** Directory API
`domainAliases.insert(parentDomainName = --parent, domainAliasName = --domain)`
(scope `admin.directory.domain`). If the tenant already has the domain — as its
primary domain, a secondary domain or an alias — nothing is added; an alias of
a _different_ parent is refused.

**2.2 Get a verification token.** Unless the tenant reports the domain verified
already: Site Verification API `webResource.getToken` with
`site = {type: INET_DOMAIN, identifier: <domain>}` and method `DNS_TXT` (scope
`siteverification`). The token is a TXT value
`google-site-verification=<…>` that belongs to the `--subject` user.

**2.3 First PR: the token.** The token is appended to
`.domains[<domain>].google_verification` in the data file (which becomes
version 2 if it was version 1), the consumer's `--post-edit` hook runs, and the
change goes out as **its own PR**, branch `mail/<domain>-verification`, exactly
as the DKIM tool publishes a key (that code is shared,
`scripts/lib/pr-publish.sh`): commit in a temporary worktree so the operator's
checkout is never touched, stage only the data file and what the hook changed,
watch every check _and_ every workflow run of the PR's head, merge with
`--merge` only at that head (`gh pr merge --match-head-commit`), then wait until
the zone's own nameservers and then the public resolvers serve the token (the
DKIM runbook's §3.6 explains why in that order). Without `--merge` the tool
stops after the checks; merge by hand and re-run.

**2.4 Verify.** `webResource.insert` (method `DNS_TXT`) makes Google look up
the TXT record and record `--subject` as a verified owner; Google then marks the
domain alias verified. The tool polls `domainAliases.get` until it says
`verified: true` (up to `--verify-timeout`, default 900 s).

**2.5 Second PR: the mail records.** Only now, as a separate PR
(`mail/<domain>-records`):

- `mx` becomes `--mx` — default `1:smtp.google.com`, the single MX record Google
  now documents for every tenant. An MX set that already points entirely at
  Google (the legacy `aspmx.l.google.com` + `alt1`–`alt4` set) is kept unless
  `--mx` is given; Google still supports it.
- `spf` gains `include:_spf.google.com` and keeps the includes it had, except
  each `--spf-drop <host>`; `--spf-replace` (or a domain with no SPF) makes it
  Google's alone, `~all`.
- `dmarc` is set to `p=none` with `rua=mailto:<--dmarc-rua>` if the domain has
  none; an existing policy is kept.

Then it waits until MX, SPF and DMARC are served.

**2.6 What has no API.** The tool ends by printing them (§3).

### Why two PRs: no MX before verification

Google's help for adding a user alias domain orders it: add the domain, verify
it, and only "after your domain is verified … find the new domain and click
**Activate Gmail**", whose instructions are the MX records. Gmail activation for
a domain requires its ownership to be verified first. An MX pointing at Google
before that delivers the domain's mail to servers that do not accept it for
the tenant yet, so it bounces. Verification itself needs only the TXT record,
which changes nothing about mail. Hence one PR that cannot break mail (the
token), a verification that Google confirms, and only then the PR that moves
mail — with the order enforced by the tool rather than by a reviewer.

### What the hook gets

`--post-edit CMD` runs in the repository root after each edit, with `DOMAIN`,
`PHASE` (`verification` or `records`), `DATA_FILE`, and
`RECORD_ADDRESSES_ADDED` / `RECORD_ADDRESSES_REMOVED`: newline-separated
`cloudflare_dns_record` addresses the edit adds or drops, as the helper renders
them with its default resource names — e.g.
`cloudflare_dns_record.mail_auth["example.org|MX|1"]`. A root with a reviewed
plan census updates it from these.

## 3. The steps that stay manual

- **Activate Gmail.** Admin console → **Account → Domains → Manage domains**
  (<https://admin.google.com/ac/domains/manage>). If the alias offers
  **Activate Gmail**, click it; Google checks the MX records it now finds.
  Google publishes no API for this.
- **DKIM**, so that mail sent as `@<domain>` carries a signature aligned with
  it: `google-workspace-dkim publish --domain <domain> …`
  ([Google-Workspace-DKIM.md](./Google-Workspace-DKIM.md)). The key is
  generated in the console (no API), and Google may not offer it for a day or
  so after Gmail starts on the domain. Each domain — alias or not — has its own
  key under `google._domainkey.<domain>`.
- **Send-as addresses** (§6).

## 4. The data file and the Terraform side

The same data file as the DKIM runbook's, rendered by
[`terraform/cloudflare/mail-auth.nix`](../terraform/cloudflare/README.md#mail-authnix--mail-dns-records-from-a-json-data-file)
(its header is the contract). Version 2 adds, per domain:

```json
{
  "version": 2,
  "domains": {
    "example.org": {
      "zone_id": "<32 hex>",
      "dkim": { "google": "v=DKIM1; k=rsa; p=…" },
      "google_verification": ["google-site-verification=…"],
      "mx": [{ "priority": 1, "host": "smtp.google.com" }],
      "spf": { "include": ["_spf.google.com"], "all": "~all" },
      "dmarc": { "p": "none", "rua": ["mailto:dmarc@example.com"] }
    }
  }
}
```

Record keys are stable: `<domain>|MX|<n>` (by position, so replacing a mail host
is an **in-place update** and the zone is never without MX),
`<domain>|TXT|spf`, `<domain>|TXT|<token value>`, `_dmarc.<domain>|TXT` — all in
`cloudflare_dns_record.mail_auth`; DKIM keeps `mail_auth_dkim`. A zone whose id
the root resolves with a `data "cloudflare_zone"` lookup is declared with
`"zone_lookup": "<data source key>"` instead of `zone_id`, and its records get
resources of their own (`mail_auth_<key>`), so excluding the lookup from an
offline plan excludes only them. When DMARC reports go to a mailbox in another
domain declared in the same file, the `<domain>._report._dmarc.<report-domain>`
authorisation record (RFC 7489 §7.1) is rendered automatically.

**Adopting existing records.** A root that already manages a domain's MX/SPF/
DMARC/verification records some other way moves them under the helper with
Terraform `moved {}` blocks from the old address to the helper's key, in the
same commit that declares them in the data file. Put the data in the data file
exactly as the records are today (the helper renders non-DKIM TXT quoted, the
form Cloudflare's dashboard stores), and the plan shows moves — plus in-place
updates for whatever the helper normalises (its comment, automatic TTL) — and
never a destroy and create.

## 5. Delegation scopes

`onboard` and `status` mint one token per call for exactly the scope the call
needs, so a missing scope is named in the error:

| Call                                          | Scope                                                    |
| --------------------------------------------- | -------------------------------------------------------- |
| `domains.get`, `domainAliases.get`, `.insert` | `https://www.googleapis.com/auth/admin.directory.domain` |
| `webResource.getToken`, `webResource.insert`  | `https://www.googleapis.com/auth/siteverification`       |

Add both to the service account's entry at
<https://admin.google.com/ac/owl/domainwidedelegation> (edit the existing
client id's scope list; the list replaces, so keep the scopes already there).
`admin.directory.domain` supersedes `admin.directory.domain.readonly` for these
calls; keep the read-only one if other automation asks for it by name.

| Error                                                    | Cause and remedy                                                             |
| -------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `token refused (unauthorized_client) for scope X`        | X is not in the delegation (or not approved yet): add it                     |
| `the siteverification.googleapis.com API is not enabled` | `gcloud services enable siteverification.googleapis.com --project <project>` |
| `HTTP 403 … lacks the privilege`                         | `--subject` is not a super admin                                             |
| `Google could not find the verification TXT record`      | public DNS does not serve the token yet; re-run once `status` shows it       |

## 6. Aliases, secondary domains and sending

- A **domain alias** gives every user an address at the alias domain
  (`user@alias` reaches `user@parent`) at no cost and with no new accounts. A
  **secondary domain** has its own users. This runbook adds aliases; the tool
  leaves a domain that is already secondary as it is.
- **Receiving** works once MX points at Google and the alias is verified (and
  Gmail is activated for it).
- **Sending** as `user@alias` is a Gmail "Send mail as" address: the user adds
  it under Gmail settings → Accounts (Google pre-verifies alias addresses of the
  user's own account), or an admin adds it through the Gmail API
  (`users.settings.sendAs.create`, scope `gmail.settings.sharing`).
- **Alignment.** DMARC passes when SPF or DKIM passes _and aligns_ with the
  From domain. SPF can align only when the envelope sender is in the alias
  domain, which the sending path decides and forwarding breaks, so do not
  count on it. DKIM is the alignment that holds: it does once the alias has
  its own Google DKIM key (§3). Until then Google signs with a
  `*.gappssmtp.com` key, which never aligns. Publish DKIM, and check the
  aggregate reports, before tightening DMARC past `p=none`.

## 7. Cutover consequences

Switching MX moves **all** of the domain's incoming mail to Google from the
moment the second PR is applied (within the old MX TTL). Mailboxes on the
previous mail server stop receiving: export what matters from them first, and
create the users or groups at the parent domain that the old addresses should
reach (an address that exists nowhere bounces). Records that pointed at the old
server for other reasons — an `A` record named `mail.<domain>`, say — are left
as they are; only the MX records stop naming them.

## 8. Rollback

- **Mail records:** revert the second PR (or edit `mx`/`spf` back in the data
  file) and let CI apply it. Because MX is keyed by position, a revert is an
  in-place update of the same records. Mail that arrived at Google meanwhile
  stays in Google's mailboxes.
- **Verification:** removing the token record un-proves ownership only for new
  checks; Google keeps the domain verified. Removing the alias is a console (or
  `domainAliases.delete`) action, and it fails while users still use addresses
  in it.
- **DMARC:** set `p` back to `none`, or drop `dmarc` to remove the record.
