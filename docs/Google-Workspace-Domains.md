# Google Workspace domains

Company-agnostic procedure for putting more domains on an existing Google
Workspace tenant so that each one **receives and sends** mail in production:
add it as a **secondary domain** or a **domain alias**, prove ownership through
DNS, move its MX to Google, publish SPF, DKIM, DMARC and TLS-RPT, and give the
right users addresses there that they can send from. Every DNS change goes
through a Terraform-managed Cloudflare zone and a reviewed PR. Each infra repo
keeps a thin overlay with its own facts: the domains and their kinds, the data
file, the users, the report mailbox.

> [!NOTE]
> The commands below assume `google-workspace-setup`, `google-workspace-domains`,
> `google-workspace-dkim` and `gcloud` are on `PATH`: they are in this
> repository's dev shell, and a consumer repo gets them by adding
> `inputs'.nixos-modules.packages.workspace-admin-tools` to its own dev shell,
> or runs one pinned revision with `nix run <this flake>/<rev>#<tool> --`.

## 1. Run the guided setup

```sh
google-workspace-setup run \
  --data terraform/cloudflare/<root>/mail-auth.json \
  --key "$KEY" --subject admin@example.com \
  --base main --dmarc-rua dmarc-reports@example.com --group dmarc-reports@example.com \
  --post-edit '<census hook>' --dkim-post-edit '<census hook>' \
  --scopes '<every scope the delegation must carry>' --test-to someone@elsewhere.example
```

A consumer wraps this in recipes (`just google-setup`, and one per step) that
fill in everything. The wizard is written for a narrow terminal pane: guidance
on stdout, wrapped at 78 columns, URLs and values to paste never broken. For
every step that needs the Admin console it prints **the page (a deep link),
what to click, the exact value to paste, and what success looks like**, then
waits — `Enter` = done, verify now; `s` = skip; `q` = quit — and **verifies
the result itself** before moving on, printing the guidance again when the
check fails. Everything is checked live first, so a re-run skips what is done
and resumes where the last one stopped.

| Step             | What it does                                                                                                                                                                                                                                                                                            | Verified by                                                                |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `scopes`         | Mints a token per scope; for the missing ones prints the client id, the console page and the **complete** replacement scope line (granted + missing, one comma-separated line, and one per box)                                                                                                         | a token for every scope                                                    |
| `dmarc-group`    | Sets the report group's `whoCanPostMessage` to `ANYONE_CAN_POST`, `spamModerationLevel` to `ALLOW` and `messageModerationLevel` to `MODERATE_NONE` (no report held for a moderator); guides through enabling the Groups Settings API, or the organisation's Groups sharing setting, when Google refuses | the group's settings, read back                                            |
| `onboard-all`    | Every declared domain, in the order of §1.1: onboard (§4), Activate Gmail (console), the users' addresses (§3)                                                                                                                                                                                          | `status` of the domain; the Directory and Gmail APIs                       |
| `user-addresses` | Every `google_users` user's aliases and send-as entries on every domain                                                                                                                                                                                                                                 | the Directory and Gmail APIs; `pending` re-checked after the user clicks   |
| `dkim-all`       | Every domain on Google without a DKIM key: the console steps (domain, 2048 bits, selector `google`), the paste, the PR, the DNS wait, "Start authentication"                                                                                                                                            | DNS serves the key; with `--test-to`, a message sent through the Gmail API |
| `smtp-relay`     | The SMTP relay rule for automated sending (§5), console only                                                                                                                                                                                                                                            | with `--test-to` and an app password, a message sent through the relay     |
| `status`         | One line per domain                                                                                                                                                                                                                                                                                     | —                                                                          |

`run` (the default) does all of them in that order, with DKIM inside each
domain's turn.

### 1.1 The order

From the data and live DNS, per domain:

1. the tenant's **primary** domain (records only);
2. domains whose mail is **already on Google** — no routing change;
3. domains with **no MX** — nothing to lose;
4. domains whose MX names a host elsewhere that **does not resolve** (it may
   only be down for now), then
5. domains whose mail **goes elsewhere today**. Before the first domain of 4
   or 5 is switched, the wizard asks the operator to confirm that a message
   sent from **outside** the tenant arrived at an address on a secondary or
   alias domain already moved to `smtp.google.com`; and before each, that the
   old mailboxes are exported and every address in use exists on the tenant.
   Without the confirmation — or with no such domain to send it to — the
   domain is skipped, untouched.

An alias always comes after its parent (Google needs the parent first), and
`onboard` leaves an alias's mail records alone until its parent is verified.
Domains declared `zone_pending` are listed and skipped (§6.2).

### 1.2 The tools underneath

The wizard only orchestrates; each step is a command of its own:

```sh
google-workspace-domains scopes [--scopes S,S,…] [--guide]
google-workspace-domains dmarc-group --group G [--guide]
google-workspace-domains onboard --domain D --data FILE [--kind secondary|alias --parent P] …
google-workspace-domains user-addresses (--user U | --all) (--domain D | --all-domains) --data FILE [--local L]…
google-workspace-domains status (--domain D | --all) --data FILE [--user U] [--table]
google-workspace-dkim publish --domain D --data FILE …          # docs/Google-Workspace-DKIM.md
```

`--key`/`--subject` (or `$GOOGLE_WORKSPACE_KEY`/`$GOOGLE_WORKSPACE_SUBJECT`)
are the decrypted service-account key of
[Google-Workspace-Admin-API-Access.md](./Google-Workspace-Admin-API-Access.md)
and the super admin it acts as. `status` without them checks DNS only.

## 2. Secondary domain or domain alias

| You want                                                                                    | Kind          |
| ------------------------------------------------------------------------------------------- | ------------- |
| Separate identities: some users (or groups) get addresses there, chosen one by one          | **secondary** |
| A user whose **primary** address is in that domain                                          | **secondary** |
| Every user of a domain reachable at the same name in another domain, with nothing to manage | **alias**     |
| A second spelling of a domain (`example-labs.com` / `examplelabs.com`), or a new TLD        | **alias**     |

- A **secondary domain** gives nobody an address by itself. Users and groups
  are created there, or given **user aliases** there (§3). Users can be created
  with their primary address in it.
- A **domain alias** belongs to a parent domain — the primary or a secondary
  domain — and every user and group of the parent automatically receives mail
  at the same local part in the alias. Nobody can have a primary address in an
  alias domain, and its addresses cannot be removed one by one.
- Both cost nothing extra, and both need their own verification, MX, SPF, DKIM
  and DMARC: each domain is its own mail domain on the internet.
- Google cannot turn one kind into the other. The tool refuses a domain the
  tenant has as the other kind, and says what to delete in the console first.

The kind is data, per domain: `"google": {"kind": "secondary"}` or
`{"kind": "alias", "parent": "<domain>"}` (`"primary"` for the tenant's own).

## 3. Users' addresses and send-as

`user-addresses` gives each user in the data's `google_users` —
`{"<primary email>": {"local_parts": ["jane", "jane.doe"]}}` — addresses on every
domain, and lets them **send** from each:

- on every **secondary** domain: a user alias `<local>@<domain>` per local part
  (Directory API `users.aliases.insert`, scope `admin.directory.user`);
- on every **alias** domain: nothing to create — the user already receives
  mail at each of their addresses in the parent, mirrored;
- for every one of those addresses: a Gmail **send-as** entry
  (`users.settings.sendAs.create`, `treatAsAlias: true`, scope
  `gmail.settings.sharing`), made **as the user** (Gmail settings can only be
  changed by the mailbox owner, which domain-wide delegation impersonates).

Google marks a send-as entry for the user's **own** address `accepted` at once.
`pending` means Gmail mailed a confirmation link to the address — the user opens
"Gmail Confirmation - Send Mail as …" and clicks it; the tool reports it and the
guided step re-checks. Domains not yet verified on the tenant are skipped (exit
2), so the step can run any time. The user then picks the address in Gmail's
**From** menu; the primary domain's own aliases are not touched.

`status --user U` shows, per domain, every expected address with `alias` /
`mirrored` and its send-as state.

## 4. What `onboard` does, step by step

**4.1 The domain on the tenant.** Directory API `domains.insert {domainName}`
for a secondary domain, `domainAliases.insert {parentDomainName,
domainAliasName}` for an alias (scope `admin.directory.domain`). A domain the
tenant already has with the same kind is left as it is.

**4.2 A verification token.** Unless the tenant reports the domain verified:
Site Verification API `webResource.getToken`, `site = {type: INET_DOMAIN,
identifier: <domain>}`, method `DNS_TXT` (scope `siteverification`). The token
is a TXT value `google-site-verification=<…>` that belongs to the `--subject`
user.

**4.3 First PR: the token.** Appended to `.domains[<domain>].google_verification`,
the consumer's `--post-edit` hook runs, and it goes out as **its own PR**
(`mail/<domain>-verification`): committed in a temporary worktree (the
operator's checkout is never touched), staging only the data file and what the
hook changed; every check _and_ every workflow run of the PR's head watched;
merged with `--merge` only at that head (`gh pr merge --match-head-commit`);
then a wait until the zone's own nameservers and then the public resolvers
serve it. The PR flow is shared with the DKIM tool (`scripts/lib/pr-publish.sh`).

**4.4 Verify.** `webResource.insert` (`DNS_TXT`) makes Google look the record
up; the tool then polls `domains.get` / `domainAliases.get` until it reports
`verified: true` (up to `--verify-timeout`, default 900 s).

**4.5 Second PR: the mail records** (`mail/<domain>-records`), only now:

- `mx` becomes `--mx` — default `1:smtp.google.com`, the single MX record Google
  documents for every tenant. An MX set already entirely on Google (the legacy
  `aspmx.l.google.com` set) is kept unless `--mx` is given.
- `spf` gains `include:_spf.google.com` and keeps its other includes, except each
  `--spf-drop <host>`; `--spf-replace`, `"google": {"spf_replace": true}` in the
  data, or a domain without SPF makes it Google's alone, `~all`.
- `dmarc`, if the domain has none: `p=none` with `rua=mailto:<--dmarc-rua>`.
- `tls_rpt`, if the domain has none: `rua=mailto:<--tls-rpt-rua>` (default: the
  DMARC mailbox).

Then it waits until MX, SPF, DMARC and TLS-RPT are served, and prints what has
no API: **Activate Gmail** (Admin console → Account → Domains → Manage domains,
<https://admin.google.com/ac/domains/manage>), DKIM, and `user-addresses`.

### Why two PRs: no MX before verification

Gmail activation for a domain requires its ownership to be verified first: an
MX pointing at Google before that delivers the domain's mail to servers that do
not accept it for the tenant yet, so it bounces. Verification itself needs only
the TXT record, which changes nothing about mail. Hence a PR that cannot break
mail (the token), a verification Google confirms, and only then the PR that
moves mail — the order enforced by the tool rather than by a reviewer.

### What the hook gets

`--post-edit CMD` runs in the repository root after each edit, with `DOMAIN`,
`PHASE` (`verification` or `records`), `DATA_FILE`, and
`RECORD_ADDRESSES_ADDED` / `RECORD_ADDRESSES_REMOVED`: newline-separated
`cloudflare_dns_record` addresses the edit adds or drops, as the helper renders
them — e.g. `cloudflare_dns_record.mail_auth["example.org|MX|1"]`, and
`mail_auth_<key>[…]` for a `zone_lookup` domain. `google-workspace-dkim`
exports the same two variables, so one census hook serves both tools.

## 5. Sending automatically through Google

Two routes, both through the tenant's own servers, so SPF (`_spf.google.com`)
and DKIM (the domain's own key) align:

- **Gmail API as a user.** A program holding the delegated service-account key
  acts as a user (scope `gmail.send`) and calls `users.messages.send`, with
  `From:` one of the user's send-as addresses. No console setting; the message
  lands in the user's Sent folder. The API helper's `send-test USER FROM TO`
  (`scripts/google-workspace-domains-api.py`) does exactly this. Good for
  application mail sent "as someone".
- **SMTP relay** (`smtp-relay.gmail.com`, port 587, STARTTLS) for servers and
  appliances that speak SMTP. Console only — Apps → Google Workspace → Gmail →
  **Routing** → SMTP relay service (<https://admin.google.com/ac/apps/gmail/routing>):
  allowed senders **Only addresses in my domains**, **Require SMTP
  Authentication**, **Require TLS encryption**; log in as a Workspace user with
  an **app password** (needs 2-Step Verification). `google-workspace-setup
smtp-relay` prints these steps and, given `--test-to` and an app password
  (typed hidden, never printed), sends a test through the relay and explains a
  refusal (bad credentials vs. relay not configured or not active yet — changes
  take up to an hour).

Limits (Google's published defaults; check the current "Gmail sending limits
in Google Workspace" page): about **2,000 messages per user per day** and
**10,000 recipients per day** through Gmail and the API; the SMTP relay allows
**10,000 recipients per user per day** and has per-domain caps on top. Bulk or
marketing mail belongs on a dedicated sending service with its own SPF include
and DKIM selector.

## 6. The data file and the Terraform side

The same data file as the DKIM runbook's, rendered by
[`terraform/cloudflare/mail-auth.nix`](../terraform/cloudflare/README.md#mail-authnix--mail-dns-records-from-a-json-data-file)
(its header is the contract). Per domain, version 2:

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
      "dmarc": { "p": "none", "rua": ["mailto:dmarc-reports@example.com"] },
      "tls_rpt": { "rua": ["mailto:dmarc-reports@example.com"] },
      "mta_sts": { "enabled": false, "id": "20261011", "mode": "testing" },
      "google": { "kind": "secondary" }
    },
    "example.net": {
      "zone_pending": true,
      "dkim": {},
      "google": { "kind": "alias", "parent": "example.org" }
    }
  },
  "google_users": { "jane@example.com": { "local_parts": ["jane"] } }
}
```

Record keys are stable: `<domain>|MX|<n>` (by position, so replacing a mail host
is an **in-place update** and the zone is never without MX), `<domain>|TXT|spf`,
`<domain>|TXT|<token>`, `_dmarc.<domain>|TXT`, `_smtp._tls.<domain>|TXT`,
`_mta-sts.<domain>|TXT` — all in `cloudflare_dns_record.mail_auth`; DKIM keeps
`mail_auth_dkim`. A zone resolved by a `data "cloudflare_zone"` lookup is
declared with `"zone_lookup": "<key>"` and gets resources of its own
(`mail_auth_<key>`). When DMARC reports go to a mailbox in another declared
domain, the `<domain>._report._dmarc.<report-domain>` authorisation record (RFC
7489 §7.1) is rendered into the report domain's zone. `google` and
`google_users` render nothing.

**6.1 Adopting existing records.** Move them under the helper with Terraform
`moved {}` blocks from the old address to the helper's key, in the commit that
declares them in the data file, with the data exactly as the records are today:
the plan shows moves plus in-place updates for what the helper normalises (its
comment, automatic TTL), never a destroy and create.

**6.2 A domain whose DNS is not in Cloudflare yet** (being transferred, say) is
declared `"zone_pending": true` with its kind and the records it will get, and
no zone. It renders **nothing** — not even the report-authorisation record
another zone would hold for it — `status` skips it and `onboard` refuses it.
Once its zone exists, replace `zone_pending` with the zone in a reviewed change
and onboard it.

**6.3 What is safe to publish before onboarding.** DMARC `p=none` and TLS-RPT
change nothing about delivery — they only ask receivers for reports — so they
can be declared for every domain at once, ahead of the per-domain onboarding.
MX and SPF changes cannot: they wait for the second PR of §4.

## 7. DMARC, TLS-RPT and MTA-STS

**DMARC progression.** Start at `p=none` with `rua` (aggregate reports), as
`onboard` does. Read the reports for a few weeks: every legitimate source must
pass SPF or DKIM _aligned_ with the From domain. For mail through Google that
means the domain's **own** DKIM key (§1, `dkim-all`) — before it, Google signs
with a `*.gappssmtp.com` key that never aligns — and SPF only when the envelope
sender is in the domain. Then `p=quarantine` (optionally `pct=25` → `100`), then
`p=reject`, by hand in the data file. A domain that sends no mail at all can go
straight to `p=reject`. The report mailbox must accept mail from outside (the
`dmarc-group` step); for a mailbox in another domain the authorisation record of
§6 is required, or receivers drop the reports.

**TLS-RPT** (RFC 8460) asks sending servers to report daily on the TLS they
negotiated with the domain's MX — failures included — to the `rua` mailbox. It
needs no authorisation record and changes nothing about delivery; it is how an
MTA-STS rollout is watched.

**MTA-STS (the next step, not deployed by these tools).** It makes senders
_require_ TLS to the listed MX hosts. It needs an HTTPS host
`mta-sts.<domain>` with a valid certificate serving
`/.well-known/mta-sts.txt`:

```text
version: STSv1
mode: testing
mx: smtp.google.com
max_age: 604800
```

(the legacy set lists `aspmx.l.google.com` and `*.aspmx.l.google.com`). Only
once that serves, set `"mta_sts": {"enabled": true, "id": "<new id>", "mode":
"testing"}` — the helper then renders `_mta-sts.<domain>` TXT `v=STSv1;
id=<id>`, and `status` checks it. Watch TLS-RPT, move the policy to `enforce`,
and change `id` with every policy change. `mode` and `max_age` live in the data
so the policy host can be generated from it.

## 8. Delegation scopes

Every call mints one token for exactly the scope it needs, so a missing scope is
named in the error; `scopes` checks them all.

| Call                                                 | Scope (`https://www.googleapis.com/auth/…`)                     |
| ---------------------------------------------------- | --------------------------------------------------------------- |
| `domains.get`, `domainAliases.get` (`status`)        | `admin.directory.domain.readonly` (or `admin.directory.domain`) |
| `domains.insert`, `domainAliases.insert` (`onboard`) | `admin.directory.domain`                                        |
| `webResource.getToken`, `webResource.insert`         | `siteverification`                                              |
| `users.get`                                          | `admin.directory.user.readonly` (or `admin.directory.user`)     |
| `users.aliases.insert`                               | `admin.directory.user`                                          |
| `sendAs.list` (as the user)                          | `gmail.settings.basic` (or `gmail.settings.sharing`)            |
| `sendAs.create` (as the user)                        | `gmail.settings.sharing`                                        |
| `messages.send` (as the user; tests, automation)     | `gmail.send`                                                    |
| Groups Settings `groups.get` / `.patch`              | `apps.groups.settings`                                          |

Edit the client id's entry at
<https://admin.google.com/ac/owl/domainwidedelegation>. **The saved list
replaces the old one**: paste the complete line `scopes` prints (it includes
every scope it checked, granted or not), plus any other scope the entry carries
for other automation. The project needs the Admin SDK, Gmail, Site Verification
and Groups Settings APIs enabled (`google-workspace-dwd setup` enables them).

| Error                                             | Cause and remedy                                                            |
| ------------------------------------------------- | --------------------------------------------------------------------------- |
| `token refused (unauthorized_client) for scope X` | X is not in the delegation (or not approved yet): add it                    |
| `the <api> API is not enabled`                    | `gcloud services enable <api> --project <project>` (printed in full)        |
| `HTTP 403 … lacks the privilege`                  | `--subject` is not a super admin                                            |
| `Google could not find the verification TXT`      | public DNS does not serve the token yet; re-run once `status` shows it      |
| `Google cannot turn one into the other`           | the tenant has the domain as the other kind: delete it in the console first |

## 9. Cutover consequences and rollback

Switching MX moves **all** of a domain's incoming mail to Google from the moment
the second PR is applied (within the old MX TTL). Mailboxes on the previous
server stop receiving: export what matters first, and make every address in use
exist on the tenant (an address that exists nowhere bounces). Records that
pointed at the old server for other reasons (`mail.<domain>` A records,
webmail CNAMEs) stay until removed in their own change.

- **Mail records:** revert the second PR; MX is keyed by position, so it is an
  in-place update. Mail that reached Google meanwhile stays there.
- **Verification:** removing the token does not un-verify the domain. Removing
  the domain or alias is a console action, refused while it is in use.
- **DMARC:** set `p` back to `none`, or drop `dmarc`.

**Status.** `google-workspace-domains status` treats Cloudflare's proxied-MX
substitute as equivalent: when a declared mail host in the zone has a
**proxied** A record, Cloudflare serves the MX as `_dc-mx.<hex>.<domain>` (a
DNS-only name it maintains), and `status` reports `OK` with that label rather
than a difference.
