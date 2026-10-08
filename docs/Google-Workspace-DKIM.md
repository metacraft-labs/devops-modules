# Google Workspace DKIM

Company-agnostic procedure for turning on DKIM signing for mail a Google
Workspace tenant sends from one of its domains, publishing the key through a
Terraform-managed Cloudflare zone, and rotating it later. Each infra repo keeps
a thin overlay with its own facts: the domains, the data file, and the DMARC
policy.

Time: a minute of console work and one command, plus CI and DNS propagation.

## 1. Run the tool

```sh
nix run github:metacraft-labs/devops-modules#google-workspace-dkim -- \
  publish --domain example.com --data terraform/cloudflare/<root>/mail-auth.json \
  --post-edit <the root's census hook> --merge
```

A consumer repo wraps this in a recipe (`just google-dkim <domain>` or similar)
that fills in `--data` and `--post-edit`. The tool walks you through the two
console clicks Google has no API for and does everything else; §3 says what,
step by step. Afterwards:

```sh
google-workspace-dkim check --domain example.com --expect-file …/mail-auth.json
```

Re-running `publish` is safe at any point: a value already on the base branch
skips to the DNS wait, and an open PR for the same branch is resumed.

Once per domain, before the first run, the domain has to be **declared** in the
data file with the Cloudflare zone that holds it (§4). The tool refuses an
undeclared domain and prints the one-line `jq` that declares it; the zone id is
on the zone's Overview page in the Cloudflare dashboard.

## 2. Why it matters, and why part of it stays manual

Until DKIM is turned on for a domain, Gmail signs that domain's outgoing mail
with a key of Google's own (`d=<domain>.<suffix>.gappssmtp.com`). Receivers then
**cannot align DKIM with the From domain**, so DMARC passes only on aligned SPF.
SPF does not survive forwarding — a mailing list, a recipient's auto-forward, a
ticketing system — and under a `p=quarantine` or `p=reject` DMARC policy such
mail is then junked or bounced. A domain-aligned DKIM signature survives
forwarding and is what DMARC is designed around.

DKIM is **per sending service**: each service signs with its own key under its
own **selector** (`<selector>._domainkey.<domain>`). Google's key coexists with
keys published for a transactional-mail provider or any other sender; adding
Google's does not displace them, and SPF and MX are unaffected.

At the time of writing Google publishes no Admin SDK API for generating a Gmail
DKIM key or for starting authentication; both are Admin console actions. The
DNS half is ordinary Terraform. That is the line the tool draws: it prompts for
the two console clicks and automates the rest. Re-check this before following
the runbook: if an API has appeared, the console steps belong in the tool.

**Prerequisites.**

- An admin with the **Gmail settings** privilege (super admin, or a custom role
  that includes Services → Gmail → Settings) for the console clicks.
- The domain is a primary, secondary or alias domain of the tenant, and Gmail
  has been active on it for a while: Google may not offer key generation for
  roughly 24–72 hours after Gmail is first enabled for a domain.
- The domain's zone is managed by a Terraform root that renders the shared
  helper `terraform/cloudflare/mail-auth.nix` from a JSON data file (§4), and
  you can open PRs against its repo with `gh` (`gh auth login`).

## 3. What `publish` does, step by step

**3.1 Console: generate the key.** The tool prints, and opens in a browser when
it can, Admin console → **Apps → Google Workspace → Gmail → Authenticate email**
(<https://admin.google.com/ac/apps/gmail/authenticateemail>), and tells you to:

- select the domain (each domain has its own key and status);
- **Generate new record** with **DKIM key bit length 2048** and the **prefix
  selector** it names — `google` by default, or the `--selector` you passed (use
  a dated one, `google2026`, when rotating, §5);
- copy the **TXT record value** (`v=DKIM1; k=rsa; p=…`). It is a **public** key,
  not a secret: pasting it into a terminal or a PR is fine.

Do **not** click _Start authentication_ yet: until the record resolves, Google
refuses with "the DKIM record has not been published yet".

**3.2 Validate the pasted value.** Paste it and press Enter on an empty line (or
pass `--value`). Surrounding quotes and the DNS multi-string form
(`"v=DKIM1; k=rsa; " "p=…"`) are reassembled into one string. The tool then
checks: the value starts with `v=DKIM1;`; it carries `k=rsa`; `p=` is base64
that decodes (`openssl rsa -pubin -inform DER`) to an RSA public key; and the key
is at least 2048 bits. It reports the bit length and refuses less unless
`--allow-1024` — choose 1024 in the console only if a DNS host cannot publish a
TXT value longer than 255 characters, which no Terraform-managed provider has
trouble with. `google-workspace-dkim validate` runs this step alone.

**3.3 Set it in the data file.** With `jq`, `.domains[<domain>].dkim[<selector>]
= <value>`, nothing else. The tool never adds a domain (§4). A selector that
already holds the **same** value is reported and skipped; one that holds a
**different** value is refused — a new key goes under a new selector (§5) —
unless `--replace` says to overwrite it deliberately.

**3.4 Run the consumer's hook.** `--post-edit CMD` runs in the repository root
with `DOMAIN`, `SELECTOR`, `RECORD_NAME` (`<selector>._domainkey.<domain>`),
`RECORD_KEY` (`RECORD_NAME|TXT`) and `DATA_FILE` exported, for whatever else
must change in the same commit — typically a reviewed plan census.

**3.5 PR.** Unless `--no-pr` (which stops after editing the file in place), the
tool does 3.3–3.4 in a **temporary git worktree** on branch
`dkim/<domain>-<selector>` from `origin/<base>` (`--base`, default the
repository's default branch), so your checkout and its uncommitted work are
never touched. It stages the data file and exactly the files the hook changed
(compared by `git status` before and after — never `git add -A`), commits
(re-staging once if a formatting hook rewrote them), pushes, opens the PR with
`gh pr create`, and watches `gh pr checks --watch`. With `--merge` it merges
only when every check passed, and only at the head commit it watched
(`gh pr merge --match-head-commit`); without it, merge by hand and re-run. If
the repository requires review approval the merge is refused, and the tool says
so.

**3.6 Wait for DNS.** Once the value is on the base branch, CI applies the root
(plan on PR, apply on merge). The tool polls `dig +short TXT <name>` on 1.1.1.1
and 8.8.8.8 (`GOOGLE_WORKSPACE_DKIM_RESOLVERS` overrides) every 30 s, for up to
`--dns-timeout` seconds (default 1800), printing what each resolver answers.
It is done when every resolver returns exactly one TXT record whose strings,
concatenated, equal the console value byte for byte.

Long values: a 2048-bit key is about 410 characters, more than one DNS
character-string (255). Cloudflare accepts the whole value and splits it on the
wire; the data file holds it as **one unquoted string**, and `dig` shows the
split, which the tool reassembles.

**3.7 Console: start authentication.** The tool prints the link again: select
the domain and click **Start authentication**. The status should read
_Authenticating email with DKIM_.

## 4. The data file and the Terraform side

The data file is plain JSON so the tool can edit it and a reviewer can read it:

```json
{
  "version": 1,
  "domains": {
    "example.com": {
      "zone_id": "<32 hex: the Cloudflare zone holding example.com>",
      "dkim": { "google": "v=DKIM1; k=rsa; p=MIIBIjANBg…" }
    }
  }
}
```

The consumer's Terranix root renders it with the shared helper
[`terraform/cloudflare/mail-auth.nix`](../terraform/cloudflare/README.md#mail-authnix--dkim-txt-records-from-a-json-data-file):
one `cloudflare_dns_record` per `(domain, selector)`, keyed
`"<selector>._domainkey.<domain>|TXT"`, TXT, unproxied, TTL automatic. The keys
are stable: adding a domain or a selector creates one record and re-keys none,
so a rotation plans as a single create. A domain with an empty `dkim` map
renders nothing, so declaring domains ahead of their keys leaves the plan
unchanged.

Declaring a domain is a person's change, reviewed on its own:

```sh
jq --arg d example.com --arg z <ZONE_ID> \
  '.domains[$d] = {zone_id: $z, dkim: {}}' mail-auth.json > mail-auth.json.new \
  && mv mail-auth.json.new mail-auth.json
```

## 5. Verify

1. `google-workspace-dkim check --domain <domain> [--selector S] --expect-file
<data file>` looks the record up on every resolver, reassembles and validates
   it, compares it with the data file, and prints the domain's SPF and DMARC
   records for context. Non-zero on any mismatch.
2. Send a message from a user on that domain to an external mailbox you can read
   raw (any consumer webmail's "show original"). Check:
   - a `DKIM-Signature:` header with `d=<domain>` and `s=<selector>`;
   - `Authentication-Results:` containing `dkim=pass header.d=<domain>`, and
     `dmarc=pass`.
3. If the console status will not change, the record does not resolve as
   published: `check` shows what resolvers answer (a lost `;`, an added space, a
   truncated split are the usual causes).

## 6. Rotate

Rotate on a schedule (yearly is common) or at once if the key may be exposed —
Google holds the private key, so exposure is rare; rotation is mostly hygiene.

1. `publish` with a **new selector** (`--selector google2026`): the console
   generates a key under it, and the record is published **alongside** the old
   one.
2. Start authentication with the new key in the console. Google signs with the
   new selector from then on.
3. Keep the old record for about a week, so mail signed with the old key that is
   still queued or being forwarded keeps verifying, then remove its selector
   from the data file (and the consumer's census) in a second PR.

## 7. DMARC alongside

- Turn DKIM on **before** tightening a domain's DMARC policy, and check
  aggregate reports (the `rua=` address) for sources that still fail alignment.
- With `adkim=s` (strict), the signature's `d=` must equal the From domain
  exactly; Google's signature satisfies that for each domain it signs. Mail
  another service sends from a **subdomain** under a strict parent policy must
  use a From address on that same subdomain, or the parent policy needs relaxed
  alignment (`adkim=r`).
- A domain with no DMARC record should get one, starting at `p=none` with
  reporting, then moving to `quarantine`/`reject` once the reports are clean.
