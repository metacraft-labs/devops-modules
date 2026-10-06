# garm-fleet-alerts

A general, parametric Prometheus **alert-rule library** for a
[cloudbase/garm](https://github.com/cloudbase/garm) self-hosted GitHub Actions
runner fleet. Company-agnostic: thresholds, the scrape job name, the metric mode
(scale-set vs pool) and the external-check families are all options.

Delivered for milestone **RE1** of
`Runner-Fleet-Capability-Pools-And-Remote-Driving`. Gate:
`.#checks.<system>.t_fleet_alerting`.

## What it covers

Every link in the runner chain, mapped to metric names verified live on a real
controller (`:9997`, scale-set mode, 2026-09-08):

| Alert                                  | Signal                                                                | Severity                         |
| -------------------------------------- | --------------------------------------------------------------------- | -------------------------------- |
| `GarmControllerDown`                   | `up{job=…} == 0`                                                      | critical                         |
| `GarmControllerUnhealthy`              | `garm_health == 0`                                                    | critical                         |
| `GarmPoolManagerNotRunning`            | `garm_organization_pool_manager_status == 0`                          | critical                         |
| `GarmProviderCreateFailures`           | `increase(garm_runner_errors_total{operation="CreateInstance"}[15m])` | warning                          |
| `GarmProviderHighErrorRatio`           | `rate(errors)/rate(operations) > 0.2`                                 | critical                         |
| `GarmGithubRateLimitLow` / `…Critical` | `garm_github_rate_limit_remaining`                                    | warning / critical               |
| **`GarmFleetStarvation`**              | queued jobs vs a **saturated** class, past the bootstrap window       | **critical (the priority page)** |
| `GarmListenerSessionShortfall`         | live message sessions (created - deleted) below the declared count    | critical                         |
| `GarmListenerPollStalled`              | `GetMessage` long-poll interval far above the ~50s ceiling            | critical                         |
| `GarmFleetOverProvision`               | runners created ÷ jobs served over 1h > 2 (thundering herd, RC5)      | warning                          |
| `GithubAppTokenMintFailing`            | external: App installation token cannot be minted                     | critical                         |
| `GithubWebhookDeliveryFailing`         | external: GitHub delivery ledger non-2xx (post-Phase-C)               | critical                         |
| `GithubWebhookEndpointProbeDown`       | external: blackbox probe of the public endpoint (post-Phase-C)        | critical                         |
| `GarmWebhookHmacFailures`              | `garm_webhook_received{valid="false"}` (pool mode only)               | warning                          |

Plus two recording rules (`garm:class_saturated`, `garm:class_queued_jobs`) that
drive the starvation join, three LISTENER-LIVENESS rules
(`garm:listener_entities_declared`, `garm:message_sessions_live`,
`garm:message_session_poll_interval_seconds`) described below, and three RC5
over-provision rules
(`garm:runners_created:increase` per provider, `garm:jobs_served:increase` per
(owner, class), and the fleet `garm:overprovision_ratio`) that drive the
thundering-herd watch during the pools cutover. The over-provision ratio is a
FLEET figure by necessity: the numerator `garm_runner_operations_total` is
labelled only by (operation, provider), so there is no per-(owner, class)
creation counter in GARM to attribute a herd finer — the denominator is broken
out per (owner, class) for the dashboard, and the alert is gated on a served-jobs
floor so a warm `min-idle` floor during a quiet period never pages.

## Listener liveness

A controller in **scale-set** mode opens one GitHub _message session_ per scale
set and long-polls it with `GetMessage`. If a worker's session dies and is never
re-opened, GARM logs **nothing at all** — no error, no warning, no backoff — and
that scale set simply stops claiming jobs. Measured on a real fleet on
2026-09-02, that state lasted **four days**. The only signal that existed was
`CreateMessageSession` minus `DeleteMessageSession` against the declared entity
count, corroborated by the long-poll interval (one live session polls at ~47s;
two sessions in the same scope at ~24s, exactly half, which is how the count was
recovered).

Both alerts are **duration-gated** (`listenerShortfallFor` /
`listenerPollStalledFor`, 15m by default) because a controlled restart drops
every session in the same scrape and must not page.

`garm:listener_entities_declared` counts scale sets, and counts **pools only on
controllers that declare no scale sets**. That asymmetry is deliberate: a
**pool-mode** controller is webhook-driven and opens no message sessions at all
(measured 2026-09-15 on a live pool-mode GARM: 18 `garm_pool_info`, 8368
`garm_webhook_received`, and not one `CreateMessageSession` or `GetMessage`
series), so it has no session count to be judged against.

Note precisely what the `unless` does and does not buy. A **pool-only**
controller is already excluded from the shortfall alert by vector matching
alone: with no message-session counters there is no `garm:message_sessions_live`
series on that `instance`, and `declared - live` over a missing right-hand side
is **empty**, not `declared - 0`. Counting its pools would therefore not by
itself page (verified 2026-09-15 against the live fleet: the shipped expression
and a naive `count(garm_scaleset_info or garm_pool_info)` variant both return
zero series). What the `unless` prevents is a **mixed** controller — one
exporting both families — having its pools added on top of its scale sets, which
would invent a permanent phantom shortfall, since pools open no sessions to cover
the inflated expectation. Keeping the union at the same time means the rule
follows the **declared total** and does not silently stop counting when a fleet
retires its scale sets.

The two **external** checks are things `garm_*` cannot see; they run over metrics
published by the companion `garm-fleet-external-checks` exporter (this repo).

## Usage

```nix
services.garm-fleet-alerts = {
  enable = true;
  garmJob = "garm";        # the Prometheus job scraping garm_* :9997
  mode = "scaleset";       # -> "pool" after the Phase-C migration
  externalChecks = true;   # App-token + (with webhookChecks) webhook alerts
  webhookChecks = false;   # POST-PHASE-C only (no webhooks in scale-set mode)
  thresholds = {
    rateLimitWarn = 200;
    rateLimitCrit = 50;
    providerCreateFailCount = 3;
    providerErrorRatioCrit = "0.2";
  };
};
```

It renders the library (`./rules.nix`) into `services.prometheus.ruleFiles`.

## Scale-set vs pool

The live fleet is in **scale-set** mode, so capacity metrics are
`garm_scaleset_*`. `mode = "pool"` flips the renamable ones to `garm_pool_*` for
after the migration. The **starvation join** genuinely differs: scale sets expose
`desired_runner_count` and a `name` that equals the job's requested class, so the
join is `(owner, class)`; pools expose neither, so the pool-mode variant is a
coarser owner-scoped saturation (`running runners >= max`). See the comments in
`./rules.nix`.

## Testing

The rule text is generated by the pure `./rules.nix`, so the file that ships is
the file `promtool test rules` replays. Fault-injection unit tests
(`./tests/fleet-alerting.test.yml`) assert every alert in **both** directions —
fires for a real incident, silent through a transient — via
`.#checks.<system>.t_fleet_alerting`.

## Layering

This is the general library. The concrete routing (Alertmanager receivers /
pager), the scrape targets, and thresholds tuned for a specific fleet belong in
that operator's private `infra` repo — Metacraft's lives in
`infra/services/monitoring/rules/mcl-garm-fleet.yml` (+ its `rule-tests`).
