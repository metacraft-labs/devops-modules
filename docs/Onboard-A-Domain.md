# Onboard a domain

Company-agnostic, end-to-end procedure for bringing a domain into production
mail on an existing Google Workspace tenant: from the registrar transfer to a
Cloudflare zone owned by Terraform, to a Workspace secondary domain or domain
alias with MX, SPF, DKIM, DMARC and TLS-RPT, verified, and hardened later.
Each step leads with the command; what happens behind it follows. Each
consumer (infra) repo keeps a thin overlay with its own facts: the tenant,
the data file, the recipes, the CI check names and labels.

The reference documents behind it:

- [Google-Workspace-Admin-API-Access.md](./Google-Workspace-Admin-API-Access.md):
  the service account, its delegation and key (done once per tenant);
- [Google-Workspace-Domains.md](./Google-Workspace-Domains.md): the tools, the
  data file, the state file, every API call and scope;
- [Google-Workspace-DKIM.md](./Google-Workspace-DKIM.md): the DKIM key, its
  validation and rotation;
- [Terraform-Import-Phase.md](./Terraform-Import-Phase.md): adopting existing
  resources into Terraform by import.

> [!NOTE]
> The commands assume the tools are on `PATH` (`workspace-admin-tools` in the
> consumer's dev shell, or `nix run <this flake>/<rev>#<tool> --`). `SETUP` below
> stands for `google-workspace-setup` with the consumer's arguments
> (`--data <mail-auth.json> --base <branch> --dmarc-rua … --post-edit …`); a
> consumer wraps each line in a recipe.

## At a glance

| #   | Step                                   | Command                                                                     | Operator time | Wall time             |
| --- | -------------------------------------- | --------------------------------------------------------------------------- | ------------- | --------------------- |
| 1   | Registrar transfer, nameservers        | registrar's console; `google-workspace-domains registrar-debris --domain D` | minutes       | hours to days         |
| 2   | Cloudflare zone                        | Cloudflare dashboard or API                                                 | minutes       | minutes               |
| 3   | Own the zone in Terraform              | a reviewed PR (create, or adopt by import)                                  | an hour       | a CI cycle or two     |
| 4   | Declare the domain for Workspace       | one entry in the data file (kind: secondary or alias)                       | minutes       | one CI cycle          |
| 5   | Tokens, verification, mail records     | `SETUP run`, then the background `follow` it starts                         | minutes       | hours                 |
| 6   | The inbound test, then live mail moved | `SETUP inbound-test`                                                        | minutes       | a CI cycle            |
| 7   | Activate Gmail, then DKIM              | console, then `SETUP dkim-collect`                                          | minutes       | a CI cycle (+24-48 h) |
| 8   | Start authentication                   | console, once the follower says DNS serves the keys                         | a minute      | up to 48 h to sign    |
| 9   | Verify                                 | `SETUP status`                                                              | a minute      | —                     |
| 10  | Harden (DMARC enforcement, MTA-STS)    | data-file edits, after weeks of reports                                     | minutes       | weeks                 |

Many domains go through steps 4-8 together: every batch below carries every
domain that is ready for it, in ONE PR.

## 1. The registrar: transfer in, nameservers

```sh
google-workspace-domains registrar-debris --domain example.org            # public DNS
google-workspace-domains registrar-debris --domain example.org --token-file <read-only Cloudflare token file>
```

Transfer the domain to the registrar you keep, then set its nameservers to
the Cloudflare zone's (step 2):

1. **At the old registrar** (its domain list → the domain → its management
   page): turn the **transfer lock** (registrar lock) off and request the
   **auth / EPP code**; it arrives by mail to the registrant contact. A domain
   registered or transferred in the last 60 days cannot move yet.
2. **At the new registrar**: start a transfer-in with the domain and the auth
   code, pay, and approve the confirmation mail the old registrar may send.
   Success: the domain is listed in the new registrar's account, and RDAP/WHOIS
   (`whois example.org`, line `Registrar:`) names it. This takes from minutes
   to five days.
3. **Nameservers**: at whichever registrar holds the domain, set the two
   nameservers of its Cloudflare zone (step 2; a registrar that is Cloudflare
   itself sets them alone). Success: `dig +short NS example.org @1.1.1.1`
   answers exactly that pair (resolvers may need the old NS TTL, up to 48 h).
   A registrar that also hosts the zone (Cloudflare Registrar, for one)
   accepts a transfer only once the zone is active: there, do this at the old
   registrar BEFORE step 2.

Before and after, run `registrar-debris`: it lists what the old registrar
left that shadows or breaks our records:

- **NS delegations of names inside the zone to other nameservers.** A
  registrar that SUSPENDS a domain — typically for an unverified WHOIS or
  registrant contact — delegates `_dmarc`, `_domainkey`, `www`, `mail`, … to its
  suspension servers (`failed-whois-verification.namecheap.com`,
  `verify-contact-details.namecheap.com`). If the zone is copied over with
  them (the scan of the old DNS when the Cloudflare zone is created copies
  whatever the old servers answer), resolvers follow the delegation
  and never see our TXT/MX records at those names: DMARC and DKIM look absent
  although the zone has them.
- **A/AAAA records at the registrar's parking address** (`198.54.117.242` for
  Namecheap): a parking page instead of nothing.
- **The domain itself delegated to suspension servers**: the registrar has
  suspended its DNS. Nothing in our zone counts until the registrant contact is
  verified AT THE REGISTRAR and the nameservers point at the zone again.

With a Cloudflare token it examines every record of the zone, without one it
probes the usual names in public DNS. Patterns and addresses are options
(`--debris-ns`, `--parking-ip`, `--allow-ns` for an intentional delegation).
Exit 0: clean; 2: something found. **Deleting** is step 3's business: records
the zone does not keep go through the API (below), records it keeps through
Terraform.

```sh
google-workspace-domains registrar-debris --domain example.org \
  --token-file <path of a token that may edit DNS> \
  --unlock '<command that decrypts that token there>' --lock '<command that removes it>' \
  [--allow-ns <intentional delegation>] --delete
```

Behind it: the token file is unlocked first (when it is not there), every
flagged record listed with its id, deleted on a typed `yes` (Cloudflare API
`DELETE /zones/<zone>/dns_records/<id>`), the zone listed again to prove it
clean, and the token locked again however the command ends. The token never
reaches a command line or the output.

A domain still suspended at the registrar is declared `"zone_pending": true`
in the data file (step 4): it renders nothing and the tools skip it, until the
registrar lifts the suspension.

## 2. The Cloudflare zone

Create the zone: <https://dash.cloudflare.com> → the account → **Add a
domain** (on the account home; or Websites → Add a domain) → enter the domain
→ keep "Quick scan for DNS records" when the domain has records worth keeping
(they are then adopted, step 3), skip it for a domain that should start empty
→ plan **Free** → review the scanned records → **Continue to activation**.
The page shows the zone's **two assigned nameservers**: take them to the
registrar (step 1.3). Success: the zone's Overview reads **Active** (Cloudflare
re-checks every few hours; "Check nameservers now" asks at once), and
`dig +short NS example.org @1.1.1.1` answers the pair. The zone id (32 hex) is
on the Overview, right column, "Zone ID".

The scan copies the old registrar's records — debris included; run
`registrar-debris` (step 1) and clean it up before or while adopting (step 3).

## 3. Own the zone in Terraform

Two ways, decided per zone:

| The zone…                                                          | Way                                                                                                                                       |
| ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| is new and empty (or only has records we do not want)              | **Create**: declare the zone and its records in the root's data; the plan creates them                                                    |
| exists with records that must survive (or was created by the scan) | **Adopt by import**: declare the zone and its records exactly as they are, with import ids; the import workflow imports them; no recreate |

**Adopt by import**, in two PRs:

1. **Import.** Remove registrar debris that the zone will not keep through
   the API first (`registrar-debris --delete`, step 1) — importing it would
   only make Terraform the owner of junk. Then declare the zone and every
   record it keeps, exactly as they are, with their ids in the root's
   import-id file; mark the root `adoption_pending` so the merge runs the
   IMPORT workflow (plan, then an import-only apply) instead of a steady-state
   apply that would try to CREATE the zone. Records the mail helper already
   manages under another address (a zone that was a `zone_lookup` before)
   move with Terraform `moved {}` blocks, in the same PR. The expected import
   plan: N imported, 0 added, 0 changed, 0 destroyed.
2. **Steady state.** Once the import has applied, clear `adoption_pending`;
   the root's normal plan must then be a no-op for the zone. Records kept only
   for the import (a registrar's parking records, say) are destroyed in their
   own PR afterwards, labelled for destruction by the consumer's CI.

A zone the mail data only needs to find, without owning it, may be declared
with `"zone_lookup": "<key>"` (the root resolves it with `data
"cloudflare_zone"`): then only the mail records are Terraform's.

Contract tests that pin per-domain record lists by hand break on every such
change: derive the expected lines from the data file instead (a census the
post-edit hook maintains, or a list computed from the rendering).

## 4. Workspace: secondary domain or domain alias

| You want                                                                                    | Kind          |
| ------------------------------------------------------------------------------------------- | ------------- |
| Separate identities: some users (or groups) get addresses there, chosen one by one          | **secondary** |
| A user whose **primary** address is in that domain                                          | **secondary** |
| Every user of a domain reachable at the same name in another domain, with nothing to manage | **alias**     |
| A second spelling of a domain (`example-labs.com` / `examplelabs.com`), or a new TLD        | **alias**     |

- A **secondary domain** gives nobody an address by itself: users and groups
  are created there, or given user aliases there (the addresses step).
- A **domain alias** belongs to a parent (the primary or a secondary domain);
  every user and group of the parent receives mail at the same local part in
  the alias. Google adds an alias **only once its parent is verified** (HTTP
  409 "Parent domain … is not verified" before), and its own verification
  comes later still — see step 5.
- Both need their own verification, MX, SPF, DKIM and DMARC. Google cannot turn
  one kind into the other: delete it in the console first.

Declare it in the data file, in a reviewed change (`"zone_id"` or
`"zone_lookup"` from step 3, the kind, and — for mail that goes elsewhere today
— its current MX and SPF exactly as served, so that the switch is an in-place
update):

```json
"example.org": { "zone_id": "<32 hex>", "dkim": {}, "google": { "kind": "secondary" } },
"example.net": { "zone_id": "<32 hex>", "dkim": {}, "google": { "kind": "alias", "parent": "example.org" } }
```

## 5. Tokens, verification, mail records: `SETUP run`

```sh
SETUP run          # interactive, minutes; ends by starting the follower
SETUP status       # the domain table, the follower, the batch in flight
SETUP follow       # the background phase in the foreground (it resumes)
```

`run`, in one sitting, without waiting for CI:

1. **The Google project**: `gcloud services list` for the service account's
   project, and `gcloud services enable` for what is missing among the Admin
   SDK, Gmail, Site Verification, Groups Settings and Org Policy APIs. An
   expired gcloud login (an organisation's reauthentication policy) is renewed
   on the spot with `gcloud auth login` — the tool runs it; the operator only
   completes the browser step. **The key**: when the service-account key is
   missing (unlocked onto a tmpfs that a restart empties), the tool offers to
   run the consumer's unlock command.
2. **The delegation scopes** (a token minted per scope; the missing ones
   printed as one complete line for the Admin console:
   <https://admin.google.com/ac/owl/domainwidedelegation> → the service
   account's client id → **Edit** → replace the scopes with the printed line
   → **Authorize**; success: `SETUP scopes` exits 0) and **the DMARC report
   group** (it must accept mail from outside; set through the Groups Settings
   API).
3. **The decisions** for every domain whose mail goes elsewhere today: "move
   its MX to Google once it is verified (and the inbound test passed)?" — all,
   none, or each. Kept in the local state file; `--redecide` asks again.
4. **Every declared domain on the tenant**: secondary domains now; an alias as
   soon as its parent is verified (the follower adds it then).
5. **The addresses** and Gmail send-as entries of the configured users, on
   every verified domain whose mail is on Google.
6. **The DKIM keys** the console can generate now (step 7) and **the inbound
   test** when one is due (step 6).
7. **ONE PR** with the batch due now, the consumer's census hook run once;
   then the follower is started detached (a systemd user unit, else `nohup`).

The follower, round after round until nothing is left:

1. waits until the batch PR's **required checks are present and passed**
   (the merge gate below), and merges it at exactly that head;
2. waits for the **apply** run on the merge commit, re-running it when it was
   cancelled or failed, then until **DNS** serves every record of the batch:
   the zone's own nameservers first, then the public resolvers (asking those
   earlier would make them cache "no such name" for the SOA minimum);
3. asks Google to **verify** every domain on the tenant whose token is served
   (`webResource.insert`), adds each **alias** once its parent is verified and
   asks again for it, and polls the Directory until each is verified — for an
   alias, for up to six hours, re-asking every ten minutes;
4. gives the users their **addresses** where the mail is now on Google;
5. opens the **next batch PR**.

**The batches**, one kind of change per PR, in this order — a later kind waits
while an earlier one is due:

| Batch            | Carries                                                                                                                           | Opened when                                                                                                |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| **verification** | the `google-site-verification=` TXT token of every declared domain not verified — aliases too, before the tenant has them         | at once (a token needs no tenant)                                                                          |
| **records**      | MX `1 smtp.google.com`, SPF with `include:_spf.google.com`, DMARC `p=none` with reports, TLS-RPT — domains with no mail elsewhere | the domain is verified (an alias: its parent verified and Site Verification accepted its token; see below) |
| **records-live** | the same, for domains whose MX points elsewhere today (resolving or not), as decided                                              | verified, decided "move", **and the inbound test passed** (step 6)                                         |
| **dkim**         | the DKIM keys pasted in one sitting                                                                                               | `run` or `dkim-collect` collected them (step 7)                                                            |

Why the order: an MX pointing at Google before Google accepts the domain
bounces its mail, and a domain that receives mail elsewhere today must not
move before a domain already moved has proven that mail from outside arrives.
A no-mail alias may go before Workspace reports it verified: its Workspace
verification lags hours behind Site Verification, the Admin console shows it
"setup incomplete" until its MX points at Google, and with no mail today
nothing can bounce that did not before.

**The merge gate.** A consumer whose CI always fails one check on a DNS
addition (an import-adoption gate that refuses creates) or runs checks
unrelated to DNS data (machine builds) names the checks that matter, and the
labels its CI needs, in the environment the tools inherit:

```sh
GOOGLE_WORKSPACE_REQUIRED_CHECKS='<check that matters>; <another, a bash pattern>'
GOOGLE_WORKSPACE_PR_LABELS='<label that unlocks the credentialed plan>'
GOOGLE_WORKSPACE_DESTROY_LABEL='<label that allows destroys>'   # added when a batch REMOVES records
GOOGLE_WORKSPACE_PLAN_CHECK='<command: does the PR'\''s plan match the change?>'
GOOGLE_WORKSPACE_APPLY_WORKFLOW='<workflow that applies on the base branch>'
```

The gate waits until **each** required check is present AND passed — not
until "nothing is pending": a job that `needs:` another registers its check
only when that one finishes, so "nothing pending" comes before the check
exists. A required check that failed, was cancelled, or was skipped because a
job it needs failed (runner timeout, full disk, cache 401) has its run's failed
jobs re-run, up to three times. The plan check gets the PR, its head and the
addresses the batch adds and removes; it answers match (0), not there yet (2)
or mismatch (anything else). Details: `scripts/lib/pr-publish.sh`, THE MERGE
GATE.

## 6. The inbound test, then live mail moves: `SETUP inbound-test`

```sh
SETUP inbound-test
```

Before the first domain whose mail goes elsewhere today is switched:

1. the tool prints an address on a domain already moved (`<user>@<moved
domain>`) and a subject marker;
2. **from a mailbox OUTSIDE the tenant** (a personal account), send a message
   there with that marker in the subject — a message from inside the tenant is
   delivered internally, without the MX, and proves nothing;
3. press Enter: the tool looks for it in the user's mailbox through the Gmail
   API (headers only, scope `gmail.metadata`), refuses one sent from a tenant
   address, and asks for your confirmation when the scope is not granted.

Then the **records-live** batch opens at once and the follower lands it. Before
saying "move" in step 5: export what matters from the old mailboxes, and make
every address in use there exist on the tenant (a user alias, a group, or the
users' addresses) — an address that exists nowhere bounces.

## 7. Activate Gmail, then DKIM: `SETUP dkim-collect`

1. **Activate Gmail** (console, per domain: Account → Domains → Manage domains,
   <https://admin.google.com/ac/domains/manage>, "Activate Gmail" on the
   domain's row) once its MX points at Google. Success: the row no longer
   offers "Activate Gmail". The follower lists the domains due; `run` and
   `dkim-collect` ask you to confirm.
2. **DKIM keys, one sitting:**

   ```sh
   SETUP dkim-collect
   ```

   For every verified domain whose mail is on Google, whose Activate Gmail is
   confirmed and that has no key: the console steps once
   (<https://admin.google.com/ac/apps/gmail/authenticateemail> → pick the
   domain → GENERATE NEW RECORD, 2048 bits, selector `google`), then one paste
   per domain. Each paste is validated (`v=DKIM1`, `k=rsa`, a 2048-bit RSA
   key; a bad paste is asked again; `s` skips a domain). All keys go out in ONE
   PR (the **dkim** batch). The console offers a key only after Gmail is
   activated — sometimes 24-48 hours after.

## 8. Start authentication

When the follower reports that DNS serves the keys ("Start authentication …
for: …", also in `status` and the notifier), click **START AUTHENTICATION** for
each of those domains on the same console page. Google refuses it before DNS
serves the key. Success: the page reads **"Authenticating email with DKIM"**
for the domain. Signing starts within 48 hours (usually an hour); a message
sent from the domain then shows `DKIM-Signature: d=<domain>` and
`dkim=pass` (Gmail: ⋮ → Show original). `run` asks you to confirm the click,
which clears the reminder.

## 9. Verify the result

```sh
SETUP status
```

```text
DOMAIN             KIND VER  MX  SPF DMARC TLS DKIM ADDR
example.org        seco yes  ok  ok  ok    ok  ok   ok
example.net        alia yes  ok  ok  ok    ok  --   ok
example.dev        seco (zone pending: not in Cloudflare yet)
```

`ok`: public DNS serves what the data declares (and the tenant reports the
domain verified, with its kind); `NO`: declared but not served, or not
verified; `--`: not declared. Then the follower's state, the batch in flight,
the decisions, the inbound proof and what is left for you. Start
authentication has no API: the reminder list is the record of it.
`google-workspace-domains status --domain D --data FILE --user U` shows one
domain in detail, with every address and its send-as state.

## 10. Harden

- **DMARC: `p=none` → `quarantine` → `reject`.** Read the aggregate reports for
  a few weeks: every legitimate sender must pass SPF or DKIM _aligned_ with the
  From domain. Through Google that means the domain's own DKIM key, signing
  (step 8) — before that, Google signs with a `*.gappssmtp.com` key that never
  aligns. Then set `"dmarc": {"p": "quarantine", "pct": 25}` → `100`, then
  `"reject"`, in the data file. A domain that sends no mail can go straight to
  `reject`. The report mailbox must accept mail from outside, and one in
  another domain needs the authorisation record the helper renders.
- **MTA-STS (next).** Senders then _require_ TLS to the listed MX: an HTTPS host
  `mta-sts.<domain>` serving `/.well-known/mta-sts.txt` (`version: STSv1`,
  `mode: testing`, `mx: smtp.google.com`, `max_age: 604800`), then
  `"mta_sts": {"enabled": true, "id": "<new id>", "mode": "testing"}` in the
  data file; watch TLS-RPT, then `enforce`. Details:
  [Google-Workspace-Domains.md §7](./Google-Workspace-Domains.md#7-dmarc-tls-rpt-and-mta-sts).

## 11. Troubleshooting

| Symptom                                                                                                            | Cause                                                                                                                 | Fix                                                                                                                                                                                           |
| ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `domainAliases.insert`: HTTP 409 "Parent domain … is not verified"                                                 | Google adds an alias only to a verified parent                                                                        | Nothing: the tool reports "waits for its parent" and the follower adds the alias once the parent is verified (the API helper exits 4 for it)                                                  |
| An alias stays "unverified" for hours although its token is served and Site Verification accepted it               | Workspace's verification of an alias lags Site Verification; one asked before the alias existed does not count        | The follower re-asks (`webResource.insert`) after adding the alias and every ten minutes, for up to six hours (`$GOOGLE_WORKSPACE_VERIFY_WAIT`); its no-mail records go out meanwhile         |
| Admin console: the alias shows "setup incomplete"                                                                  | Its MX does not point at Google yet                                                                                   | Expected until the records batch lands; then Activate Gmail if the row offers it                                                                                                              |
| DKIM: the console offers no "Generate new record" for a domain                                                     | Gmail is not activated for it (or only just: up to 24-48 h)                                                           | Activate Gmail first; `dkim-collect` leaves such domains out until you confirm it                                                                                                             |
| "Start authentication" refused                                                                                     | DNS does not serve the key yet                                                                                        | Wait for the follower's "Start authentication … DNS serves their DKIM keys now"                                                                                                               |
| A DNS-record PR fails the import-adoption gate (`import / plan` or alike)                                          | That gate refuses creates by design; every record addition fails it                                                   | Expected: the merge gate ignores it when the consumer lists its required checks (`$GOOGLE_WORKSPACE_REQUIRED_CHECKS`)                                                                         |
| The credentialed plan never runs / is skipped                                                                      | The PR lacks the label that unlocks it                                                                                | `$GOOGLE_WORKSPACE_PR_LABELS`: the tools open every PR with it                                                                                                                                |
| The apply refuses a destroy                                                                                        | A batch removes records (a second legacy MX) without the destroy label                                                | `$GOOGLE_WORKSPACE_DESTROY_LABEL`: added automatically when the edit removes records; the PR body lists them                                                                                  |
| CI jobs time out, are cancelled, run out of disk, or hit a cache 401                                               | Flaky runners                                                                                                         | The gate re-runs the failed jobs of a required check's run (three times), then stops and names the run                                                                                        |
| The follower merged before a check had even run                                                                    | Gating on "nothing pending": a dependent job registers late                                                           | Configure the required checks: the gate waits until each is present AND passed                                                                                                                |
| Merged, but DNS never serves the records                                                                           | The apply run on the base branch was cancelled or failed                                                              | With `$GOOGLE_WORKSPACE_APPLY_WORKFLOW` the follower re-runs it; by hand: re-run the failed jobs of that run                                                                                  |
| Checks of machine builds fail on a DNS-data PR                                                                     | Unrelated to the change                                                                                               | Not in the required list: ignored                                                                                                                                                             |
| A contract test fails on every mail-record change                                                                  | It pins per-domain record lines by hand                                                                               | Derive them from the data file or the census the hook maintains                                                                                                                               |
| `_dmarc`, `_domainkey`, `www` … resolve to another registrar's nameservers; DMARC/DKIM "missing" although declared | Suspension debris: NS delegations copied into the zone from a suspended domain                                        | `registrar-debris --delete` (step 1), then adopt the zone (step 3)                                                                                                                            |
| The site shows a registrar's parking page                                                                          | Parking A records copied into the zone                                                                                | Destroy them: through Terraform once the zone is adopted (destroy label), or with `registrar-debris --delete` before                                                                          |
| The whole domain resolves to the registrar's suspension servers                                                    | The registrar suspended the domain (registrant contact not verified)                                                  | Verify the contact at the registrar; meanwhile declare it `zone_pending`                                                                                                                      |
| `gcloud`: "Reauthentication failed" / "refreshing your current auth tokens"                                        | The organisation's reauthentication policy expired the login                                                          | The interactive steps run `gcloud auth login` themselves; complete the browser step. The follower cannot: it notes it, and the next `run` logs in                                             |
| "the <api> API is not enabled" / `SERVICE_DISABLED`                                                                | An API missing in the service account's project                                                                       | `run` enables the Admin SDK, Gmail, Site Verification, Groups Settings and Org Policy APIs itself; only a missing permission (`roles/serviceusage.serviceUsageAdmin`) is left to someone else |
| "the service-account key … is not there" / "is gone (a restart empties $XDG_RUNTIME_DIR …)"                        | The key was unlocked onto a tmpfs a reboot cleared                                                                    | The interactive steps offer the unlock command (`$GOOGLE_WORKSPACE_KEY_UNLOCK`); the follower stops with it — unlock, then run the follower again (it resumes)                                |
| The inbound test is "not there"                                                                                    | Sent from inside the tenant (delivered internally), MX not on Google yet, Activate Gmail missing, the address missing | Send from outside; check the moved domain's `status`; click Activate Gmail; run the addresses step                                                                                            |
| `token refused (unauthorized_client) for scope X`                                                                  | X is not in the delegation (or not approved yet)                                                                      | `SETUP scopes` prints the complete line to paste at <https://admin.google.com/ac/owl/domainwidedelegation> (step 5.2); a new scope can take minutes to be honoured                            |
| `Google cannot turn one into the other`                                                                            | The tenant has the domain as the other kind                                                                           | Delete it in the console (<https://admin.google.com/ac/domains/manage> → the row → Remove domain; it must have no users or groups), or declare the other kind                                 |
| `SETUP status` says the follower is not running, with work left                                                    | It stopped: a host restart, the key gone, a check that kept failing, its timeout                                      | Read the last lines of the log `status` names; fix what it says; `SETUP follow --detach` (or `run`) resumes the same batch PR                                                                 |
| The registrar keeps the domain delegated to its suspension servers after the transfer request                      | The transfer has not completed, or the old registrar suspended it (registrant contact not verified)                   | Verify the registrant contact (the old registrar's mail, or its dashboard's domain page); `registrar-debris` without a token reports "the domain ITSELF is delegated" until it is lifted      |
