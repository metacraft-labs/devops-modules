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

## 1. Run the setup: an interactive phase, then a background one

```sh
google-workspace-setup run \
  --data terraform/cloudflare/<root>/mail-auth.json \
  --key "$KEY" --subject admin@example.com \
  --base main --dmarc-rua dmarc-reports@example.com --group dmarc-reports@example.com \
  --post-edit '<census hook>' --dkim-post-edit '<census hook>' \
  --scopes '<every scope the delegation must carry>'
```

A consumer wraps this in recipes (`just google-setup`, `just google-setup-follow`,
`just google-setup-status`) that fill in everything. CI checks and DNS
propagation take hours over a dozen domains; the operator's part takes
minutes. So the work is split in two:

**The interactive phase (`run`) — minutes, no CI wait.** In one sitting:

1. the delegation scopes and the DMARC report group (a disabled Google API is
   enabled with `gcloud`, running `gcloud auth login` here first when its
   credentials have expired; only a missing permission ends in instructions);
2. **the decisions the background phase needs**: for every domain whose mail
   goes elsewhere today, "move its MX to Google automatically once it is
   verified?" — for all at once or one by one — kept in a local state file
   (§1.2) so the background phase never asks;
3. every declared domain added to the tenant — secondary domains, then aliases
   (an alias Google refuses before its parent is verified is added later by
   the background phase);
4. the users' addresses and send-as entries on the domains already verified;
5. **every DKIM key the console can generate now** (verified domain, mail on
   Google, no key yet): the console steps once, then one paste per domain
   (`s` skips one);
6. then **ONE commit on ONE branch** with every DNS change possible now —
   verification tokens of the unverified domains, the pasted DKIM keys, and the
   mail records of verified domains as decided — the consumer's hook run once
   for the whole batch, **ONE PR**; the background phase is started detached,
   and the command returns, saying what happens next.

**The background phase (`follow`) — hours, unattended.** Started by `run` as a
transient systemd user unit when the user manager answers, else with `nohup`
(`$GOOGLE_WORKSPACE_FOLLOW_DETACH=systemd|nohup|none` forces one), logging
beside the state file; `follow` alone runs it in the foreground, `follow
--detach` detached. Round after round:

1. watch the batch PR's checks and every workflow run of its head, and merge it
   at exactly that head (`gh pr merge --match-head-commit`);
2. wait until every record of the batch is served — each zone's own
   nameservers first, then the public resolvers (asking those earlier would
   make them cache "no such name");
3. `webResource.insert` for every domain whose token is now served, then wait
   until the Directory API reports it verified;
4. the users' addresses on the newly verified domains;
5. **the inbound test** when a domain whose mail goes elsewhere is due to move:
   a message sent through the Gmail API as the first user to their address on
   a domain already moved to `smtp.google.com`, then looked for in their inbox
   (scope `gmail.metadata`, or `gmail.readonly`);
6. **the next batch PR** with what that made possible — the mail records of the
   newly verified no-mail domains, an alias's once its parent is verified, and
   those of domains whose mail goes elsewhere once decided "move" and the
   inbound test passed — and round again, until nothing more can be published.

It ends by printing — and keeping for `status` — **what still needs the
operator**: "Activate Gmail" for the domains it moved, "Start authentication"
for the keys it published, the domains whose DKIM key can now be generated
(`run` again), the domains held by decision, the inbound test it could not do.
With `$GOOGLE_WORKSPACE_NOTIFY` set, that summary (and a stop on an error) is
piped to that command, with the title in `$NOTIFY_TITLE` — a desktop or ntfy
notifier, say.

**`status`** prints one line per domain (§1.4's `status --table`) and the
background phase: running or not (pid or unit), the batch PR in flight and its
stage (`opening`, `checks`, `merged`, `dns`), the queued DKIM keys, the
decisions, the inbound proof, the summary of the last run and the last lines of
its log.

**Interrupted, both resume.** Everything is re-read every time — the data file
on `origin/<base>`, the tenant, DNS, the state file — so a re-run of either
phase picks up where things stand: a batch PR in flight is landed rather than
opened again, a batch already merged goes straight to its DNS wait. Re-running
`run` while a batch is in flight asks only what is new and queues it for the
next batch. A domain that another open PR changes — a per-domain one from the
tools of §1.4, or a batch made by hand, whatever its branch name: any open PR
whose head changes the domain's entry in the data file — is left to that PR,
and the background phase, when that domain still has work due, waits for the PR
to land (up to `$GOOGLE_WORKSPACE_FOREIGN_PR_WAIT` seconds, default six hours)
and carries on from what it published. Work done by hand — a domain added in
the console, a token fetched and published, a domain verified — is simply
found done.

### 1.1 The safety rules the batches keep

- **No MX before verification.** A domain's mail records go into a batch only
  once Google reports it verified, and an alias's only once its parent is too
  (§4, "Why two PRs").
- **Mail that goes elsewhere today** — an MX outside Google, resolving or not
  (the host may only be down) — moves only as the operator decided, and only
  after a domain already moved to `smtp.google.com` has received a test
  message: the inbound test of the background phase, or — without a Gmail read
  scope — the operator's confirmation of a message sent from outside, asked at
  the next `run`. Without a domain to send it to, those domains wait: the
  domains with no MX move first. Before deciding "move", export what matters
  from the old mailboxes and make every address in use there exist on the
  tenant (an address that exists nowhere bounces).
- The inbound test sends from the user to their own address on the moved
  domain, so Google delivers it inside the tenant; it proves that the tenant
  accepts mail for the domain and the address (verified, Gmail active, the
  alias in place), while the batch's DNS wait proved the MX. A message from
  outside proves both at once; that is the manual fallback.
- Domains declared `zone_pending` are listed and skipped (§6.2).

### 1.2 The state file

`${XDG_STATE_HOME:-~/.local/state}/google-workspace-setup/<tenant>.json`
(`$GOOGLE_WORKSPACE_STATE_DIR` overrides the directory), never committed, with
the background phase's log beside it (`<tenant>.log`). It holds only what is
neither in the data file, nor on the tenant, nor in DNS: the decisions
(`--redecide` asks them again), the DKIM keys pasted but not yet on the base
branch (public keys), the inbound proof, the batch in flight, the follower's
pid or unit, the console steps the batches made due (shown and confirmed at the
next `run`) and the last summary. Deleting it loses the decisions and the
queued keys, nothing else.

### 1.3 The per-domain path

The steps one by one, and the original guided run that takes the domains one
after another and waits for each PR (one PR per change, slow):

| Step             | What it does                                                                                                                                                                                                                                                                                            | Verified by                                                                |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `scopes`         | Mints a token per scope; for the missing ones prints the client id, the console page and the **complete** replacement scope line (granted + missing, one comma-separated line, and one per box)                                                                                                         | a token for every scope                                                    |
| `dmarc-group`    | Sets the report group's `whoCanPostMessage` to `ANYONE_CAN_POST`, `spamModerationLevel` to `ALLOW` and `messageModerationLevel` to `MODERATE_NONE` (no report held for a moderator); guides through enabling the Groups Settings API, or the organisation's Groups sharing setting, when Google refuses | the group's settings, read back                                            |
| `onboard-all`    | Every declared domain, in the order below: onboard (§4), Activate Gmail (console), the users' addresses (§3)                                                                                                                                                                                            | `status` of the domain; the Directory and Gmail APIs                       |
| `user-addresses` | Every `google_users` user's aliases and send-as entries on every domain                                                                                                                                                                                                                                 | the Directory and Gmail APIs; `pending` re-checked after the user clicks   |
| `dkim-all`       | Every domain on Google without a DKIM key: the console steps (domain, 2048 bits, selector `google`), the paste, the PR, the DNS wait, "Start authentication"                                                                                                                                            | DNS serves the key; with `--test-to`, a message sent through the Gmail API |
| `smtp-relay`     | The SMTP relay rule for automated sending (§5), console only                                                                                                                                                                                                                                            | with `--test-to` and an app password, a message sent through the relay     |
| `guided`         | All of the above in that order, DKIM inside each domain's turn                                                                                                                                                                                                                                          | —                                                                          |

The guided path's order, from the data and live DNS: the tenant's **primary**
domain (records only); domains whose mail is **already on Google**; domains
with **no MX**; domains whose MX names a host elsewhere that **does not
resolve**; then domains whose mail **goes elsewhere today** — each of the last
two only after the operator confirms a message from outside arrived at a domain
already moved, and that the old mailboxes are exported. An alias always comes
after its parent.

### 1.4 The tools underneath

Both phases only orchestrate; each step is a command of its own:

```sh
google-workspace-domains scopes [--scopes S,S,…] [--guide]
google-workspace-domains dmarc-group --group G [--guide]
google-workspace-domains onboard --domain D --data FILE [--kind secondary|alias --parent P] …
google-workspace-domains user-addresses (--user U | --all) (--domain D | --all-domains) --data FILE [--local L]…
google-workspace-domains status (--domain D | --all) --data FILE [--user U] [--table]
google-workspace-domains edit --domain D --data FILE --phase verification --token T | --phase records … [--dry-run]
google-workspace-dkim publish --domain D --data FILE …          # docs/Google-Workspace-DKIM.md
```

`edit` is `onboard`'s edit of the data file for one phase alone — no Google
call, no hook, no PR; the batches are made of it. `--key`/`--subject` (or
`$GOOGLE_WORKSPACE_KEY`/`$GOOGLE_WORKSPACE_SUBJECT`) are the decrypted
service-account key of
[Google-Workspace-Admin-API-Access.md](./Google-Workspace-Admin-API-Access.md)
and the super admin it acts as. `status` without them checks DNS only. The PR
flow (`scripts/lib/pr-publish.sh`) is shared: open (branch, commit, push, PR)
and land (watch the exact head, merge at it) are separate steps, so one
process can open a PR and another land it.

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
means the domain's **own** DKIM key (§1, the DKIM step of `run`) — before it, Google signs
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
| `messages.list`, `.get` (as the user; inbound test)  | `gmail.metadata` (or `gmail.readonly`)                          |
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
