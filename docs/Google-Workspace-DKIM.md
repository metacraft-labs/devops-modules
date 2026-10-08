# Google Workspace DKIM

Company-agnostic procedure for turning on DKIM signing for mail a Google
Workspace tenant sends from one of its domains, publishing the key through a
Terraform-managed DNS zone, and rotating it later. Each infra repo keeps a thin
overlay with its own facts: the domains, the DNS root, and the DMARC policy.

Time: ten minutes of console and PR work, plus DNS propagation.

## 1. Why it matters

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

## 2. Why this is a runbook and not Terraform

At the time of writing Google publishes no Admin SDK API for generating a Gmail
DKIM key or for starting authentication; both are Admin console actions. The
**DNS** half is ordinary Terraform. The ceiling for automation is therefore:
the console steps by a person, or by browser automation signed in as an admin
with the Gmail-settings privilege; everything else in a PR. Re-check this before
following the runbook: if an API has appeared, the console steps belong in code.

## 3. Prerequisites

- An admin with the **Gmail settings** privilege (super admin, or a custom role
  that includes Services → Gmail → Settings).
- The domain is a primary, secondary or alias domain of the tenant, and Gmail
  has been active on it for a while: Google may not offer key generation for
  roughly 24–72 hours after Gmail is first enabled for a domain.
- The domain's zone is managed by a Terraform root you can open a PR against.

## 4. Generate the key (Admin console)

1. Admin console → **Apps → Google Workspace → Gmail → Authenticate email**
   (<https://admin.google.com/ac/apps/gmail/authenticateemail>).
2. **Selected domain**: pick the domain. Each domain has its own key and status.
3. **Generate new record**:
   - **DKIM key bit length: 2048.** Choose 1024 only if the DNS host cannot
     publish a TXT value longer than 255 characters — any Terraform-managed
     provider can.
   - **Prefix selector:** keep `google` for the first key. Use a dated selector
     (`google2026`) when rotating (§7), so old and new can be published side by
     side.
4. Copy the **DNS Host name** (`<selector>._domainkey`) and the **TXT record
   value** (`v=DKIM1; k=rsa; p=…`). The value is a **public** key: it is not a
   secret and can go into the PR as is.

Do **not** click _Start authentication_ yet: until the record resolves, Google
refuses with "the DKIM record has not been published yet" — harmless, but
starting before DNS is live just costs a second pass.

## 5. Publish it (Terraform PR)

Add one TXT record to the zone's root:

| Field   | Value                                                                   |
| ------- | ----------------------------------------------------------------------- |
| Type    | `TXT`                                                                   |
| Name    | `<selector>._domainkey.<domain>` (e.g. `google._domainkey.example.com`) |
| Content | the TXT value from §4.4, exactly, as one string                         |
| TTL     | automatic / 3600                                                        |

Notes:

- **Long values.** A 2048-bit key is about 400 characters, more than one DNS
  character-string (255). Most providers (Cloudflare among them) accept the whole
  value and split it into strings on the wire; do not insert quotes or spaces
  yourself unless the provider's documentation says to. Verify with `dig` (§6).
- **Proxying does not apply** to TXT records; leave any proxy flag off.
- Merge through the root's normal plan/apply path, then wait for the record to
  resolve from a public resolver:
  ```sh
  dig +short TXT <selector>._domainkey.<domain> @1.1.1.1
  ```
  The answer must reassemble to exactly the console's value (concatenate the
  quoted strings).

## 6. Start authentication, then verify

1. Back in **Authenticate email**, select the domain, **Start authentication**.
   The status should read _Authenticating email with DKIM_.
2. Send a message from a user on that domain to an external mailbox you can read
   raw (any consumer webmail's "show original"). Check:
   - a `DKIM-Signature:` header with `d=<domain>` and `s=<selector>`;
   - `Authentication-Results:` containing `dkim=pass header.d=<domain>`, and
     `dmarc=pass`.
3. If the status will not change, the record does not resolve as published:
   compare `dig` output with the console value character by character (a lost
   `;`, an added space, a truncated split are the usual causes).

## 7. Rotate

Rotate on a schedule (yearly is common) or at once if the key may be exposed —
Google holds the private key, so exposure is rare; rotation is mostly hygiene.

1. Generate a new record with a **new selector** (§4.3).
2. Publish it **alongside** the old one (§5); wait for it to resolve.
3. Start authentication with the new key in the console. Google signs with the
   new selector from then on.
4. Keep the old TXT record for about a week, so mail signed with the old key
   that is still queued or being forwarded keeps verifying, then remove it in a
   second PR.

## 8. DMARC alongside

- Turn DKIM on **before** tightening a domain's DMARC policy, and check
  aggregate reports (the `rua=` address) for sources that still fail alignment.
- With `adkim=s` (strict), the signature's `d=` must equal the From domain
  exactly; Google's signature satisfies that for each domain it signs. Mail
  another service sends from a **subdomain** under a strict parent policy must
  use a From address on that same subdomain, or the parent policy needs relaxed
  alignment (`adkim=r`).
- A domain with no DMARC record should get one, starting at `p=none` with
  reporting, then moving to `quarantine`/`reject` once the reports are clean.
