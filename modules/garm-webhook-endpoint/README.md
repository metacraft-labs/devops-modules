# garm-webhook-endpoint

The public front door for the central GARM's `/webhooks` endpoint, added in
milestone **RC3** of the _Runner-Fleet-Capability-Pools-And-Remote-Driving_
campaign (gate `t_garm_webhook_delivery`).

In **scale-set** mode GARM long-polled GitHub outbound, so the fleet needed **no
inbound path**. **Pool** mode gives that property up: GitHub must POST
`workflow_job` events to a public HTTPS endpoint, HMAC-SHA256 signed. This module
re-adds a reachable endpoint **without punching an inbound hole into the private
NetBird fleet**, and leaves HMAC validation to GARM itself.

## HMAC design (validated by GARM, not here)

GitHub signs the raw request body: `X-Hub-Signature-256: sha256=<hex hmac>`.
GARM re-computes `HMAC-SHA256(secret, rawBody)` and compares in constant time
(`runner.validateHookBody`), incrementing:

- `garm_webhook_received{valid="true"}` on a match (a real queued job), and
- `garm_webhook_received{valid="false",reason="signature_invalid"}` on a
  tampered payload / secret mismatch (also `owner_unknown`, `unknown`).

The endpoint therefore must forward the body **byte-for-byte** — any rewrite
breaks the signature. In `netbird-relay` mode nginx proxies the raw body
(`proxy_request_buffering off`, no body filters). The endpoint never needs the
secret; the secret lives only with GARM (agenix) and with GitHub (the webhook
registration). The RE1b Prometheus rules `GarmWebhookHmacFailures`
(`increase(garm_webhook_received{valid="false"}[10m]) >= 1`) and
`GithubWebhookDeliveryFailing` / `GithubWebhookEndpointProbeDown` are waiting on
exactly these signals.

## Two transports — Cloudflare Tunnel vs. NetBird relay

|                       | `cloudflare-tunnel`                                        | `netbird-relay` (**default**)                   |
| --------------------- | ---------------------------------------------------------- | ----------------------------------------------- |
| Inbound firewall hole | **None** (outbound-only tunnel)                            | One TLS port (443), GitHub-IP-pinned            |
| External dependency   | **New Cloudflare account** (a 3rd party in the trust path) | **None new** — reuses NetBird, already deployed |
| GitHub-IP pinning     | Cloudflare edge WAF rule (not NixOS-expressible)           | nginx `allow`/`deny` on GitHub's hook CIDRs     |
| TLS termination       | Cloudflare edge                                            | nginx (ACME or provided cert) on the relay      |
| Shared SPOF           | Cloudflare edge + tunnel process                           | The relay host                                  |
| Security posture      | **Best** (no inbound at all)                               | Good (inbound pinned + GARM HMAC)               |

### Recommendation

**Default to `netbird-relay`.** The RC3 directive is to _minimize external
dependencies_: NetBird is already a fleet dependency, whereas a Cloudflare
account is a brand-new external dependency and adds a third party to the webhook
trust path. `netbird-relay` reaches parity on the thing that actually matters —
GitHub's HMAC-SHA256 is the security boundary either way — while keeping the
inbound surface to a single GitHub-IP-pinned TLS port with GARM's HMAC behind
it.

`cloudflare-tunnel` is fully implemented and is the **stronger no-inbound-hole
posture** (the campaign's stated end-state preference). Choose it when a
Cloudflare account is acceptable and the extra hardening (zero inbound ports) is
wanted. The research doc (`research-garm-pools-webhook-aws.md` §2) recommends
Cloudflare purely on security grounds; this module honors that as an option but
defaults to the lower-dependency choice per the RC3 directive.

## Delivery-health monitoring (the blind spots `garm_*` cannot see)

GARM only observes webhooks that **arrive**; a dead tunnel/relay looks identical
to "no jobs". Two external checks (in `garm-fleet-external-checks`) close that:

1. `github_webhook_last_delivery_ok{org,hook_id}` — reads GitHub's own delivery
   ledger `GET /orgs/{org}/hooks/{id}/deliveries` (authoritative: was the last
   delivery 2xx?).
2. `probe_success{...}` — a blackbox HTTP probe of the public endpoint: an
   unsigned POST is expected to be **rejected** (4xx) — proving the endpoint is
   alive and reachable end to end, catching a tunnel/relay/cert outage.

These feed the RE1b `GithubWebhookDeliveryFailing` / `GithubWebhookEndpointProbeDown`
alerts.

## Concrete wiring (infra)

The live public endpoint needs an operator prerequisite — **one** of:

- a **Cloudflare account** + a named tunnel + its credentials JSON (agenix), or
- a **public relay host** (a small always-on VPS on NetBird) with a TLS cert and
  the 443 port pinned to GitHub ranges.

Plus the per-org HMAC secret (agenix) and the org webhook registrations
(`/etc/garm-webhook/registration-<org>.json` renders the exact `POST
/orgs/{org}/hooks` shape). See `infra/machines/server/_high-mem-server/central-garm-webhook.nix`
(held, flag-off).
