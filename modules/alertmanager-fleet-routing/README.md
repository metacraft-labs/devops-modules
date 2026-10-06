# alertmanager-fleet-routing

A general, parametric **Alertmanager routing** module that makes a runner-fleet's
Prometheus alerts actually **page**. It wraps nixpkgs
`services.prometheus.alertmanager` with an opinionated routing-by-`(severity,
component)` tree, sane grouping + inhibition, and pluggable receivers whose
secrets are always file-referenced.

Delivered for the **`t_fleet_alert_routing`** gate of
`Runner-Fleet-Capability-Pools-And-Remote-Driving` — the missing piece after
**RE1**, which shipped the alert RULES (`garm-fleet-alerts`) with `severity` /
`component` labels that were, until now, only a routing CONTRACT with nothing to
honour them.

## The routing contract

The `garm-fleet-alerts` rules stamp `severity` (`critical` / `warning`) and
`component: garm-fleet` on every alert. This module routes on exactly those:

| Alert labels           | Routes to                   |
| ---------------------- | --------------------------- |
| `severity=critical`    | the **pager** receiver      |
| `severity=warning`     | the **CI-ops** receiver     |
| `component=garm-fleet` | grouped together into pages |

The `component=garm-fleet` subtree regroups the fleet's alerts (by `component` +
`severity`) so a burst of runner-chain failures is one page per severity, not one
per alertname — then splits critical→pager / warning→CI-ops. Below it, the same
severity split applies to any other component.

## What is general vs concrete

This module is the **general** half (per the campaign `:repo_layering:`): the
routing OPINION and the option surface, company-agnostic. The **concrete** half —
the real pager (PagerDuty / Slack / email), its endpoint, and its secret — lives
in the operator's private `infra` repo. Metacraft's is
`infra/services/monitoring/alertmanager.nix` (+ its agenix secret).

## Usage

```nix
services.fleet-alert-routing = {
  enable = true;
  # Receiver ENDPOINTS are options; secrets are FILE-referenced, never inline.
  receivers = {
    default = { };
    pager.pagerduty_configs = [
      { routing_key_file = config.age.secrets."alertmanager/pagerduty-key".path; }
    ];
    "ci-ops".slack_configs = [ {
      channel = "#ci-ops";
      api_url_file = config.age.secrets."alertmanager/slack-url".path;
      send_resolved = true;
    } ];
  };
  listenAddress = "127.0.0.1";   # keep OFF the public internet
  port = 9093;
};
```

Then point Prometheus at it (concrete side):

```nix
services.prometheus.alerting.alertmanagers = [
  { static_configs = [ { targets = [ "127.0.0.1:9093" ]; } ]; } ];
```

Receiver kinds: anything Alertmanager understands — `pagerduty_configs`,
`webhook_configs`, `slack_configs`, `email_configs`, … Always use the `*_file`
secret variants (`routing_key_file`, `api_url_file`, `smtp_auth_password_file`).

## Options (highlights)

| Option                                                     | Default                            | Purpose                                                                     |
| ---------------------------------------------------------- | ---------------------------------- | --------------------------------------------------------------------------- |
| `component`                                                | `garm-fleet`                       | the label whose alerts group together / are inhibited by controller-down    |
| `criticalReceiver` / `warningReceiver` / `defaultReceiver` | `pager` / `ci-ops` / `default`     | which receiver each severity bucket routes to                               |
| `receivers`                                                | inert loopback webhooks            | pluggable endpoints (override for a real pager)                             |
| `fleetGroupBy`                                             | `[component severity]`             | how the fleet's alerts are grouped into pages                               |
| `severityInhibit`                                          | `true`                             | critical squelches warning on same `(component, instance)`                  |
| `controllerDownInhibit`                                    | `true`                             | controller-down squelches its dependent `component` alerts (page the cause) |
| `controllerDownSourceMatchers`                             | `[alertname="GarmControllerDown"]` | which alert counts as controller-down (overridable)                         |
| `listenAddress` / `port`                                   | `127.0.0.1` / `9093`               | Alertmanager web/API bind                                                   |

## Dead-man's switch

Per the [alerting methodology](https://github.com/metacraft-labs/metacraft-dev-guidelines/blob/latest/policies/alerting-methodology.md),
a single-controller fleet MUST also run a **dead-man's switch** — otherwise a dead
Alertmanager/host/network pages nothing and silence reads as health. Set
`deadManReceiver` to a receiver that **pings an off-host heartbeat sink**
(Healthchecks) on every interval; the always-firing `Watchdog` alert (emitted by
`garm-fleet-alerts`, `watchdog = true`) is routed there FIRST, on a short cadence,
and never falls through to the pager/CI-ops buckets. When the pings stop, the
off-host sink alarms.

```nix
services.fleet-alert-routing = {
  enable = true;
  deadManReceiver = "deadmanswitch";           # the Watchdog goes only here
  receivers = {
    default = { };
    pager.webhook_configs = [ { url_file = config.age.secrets."alertmanager/ntfy-url".path; } ];
    deadmanswitch.webhook_configs = [
      { url_file = config.age.secrets."alertmanager/healthchecks-ping-url".path; }  # OFF-HOST
    ];
  };
};
```

| Option                | Default                  | Purpose                                                                                          |
| --------------------- | ------------------------ | ------------------------------------------------------------------------------------------------ |
| `deadManReceiver`     | `null`                   | receiver the always-firing `Watchdog` routes to (an off-host Healthchecks ping); `null` disables |
| `deadManMatchers`     | `[alertname="Watchdog"]` | which alert is the heartbeat                                                                     |
| `deadManPingInterval` | `1m`                     | heartbeat cadence (must be < the sink's grace period)                                            |

The heartbeat sink **must not live on the monitored host** — it is what detects
that host dying. Use a hosted Healthchecks tier or a separate box.

## Inhibition

Two sane defaults, both overridable:

1. **Severity squelch** — a critical alert inhibits a warning alert with the same
   `(component, instance)`.
2. **Controller-down** — a dead controller makes every downstream `garm_*` alert
   fire; the controller-down alert inhibits its dependent `component` alerts on
   the same instance so you page the cause, not the symptoms.

## Testing

The config is rendered by the pure `./config.nix`, so the file `amtool` replays
is the file the host deploys. The gate `.#checks.<system>.t_fleet_alert_routing`
runs `amtool check-config` on the default render and `amtool config routes test`
to assert `critical,garm-fleet → pager` and `warning,garm-fleet → ci-ops`, and on
a second dead-man render asserts `Watchdog → deadmanswitch` (while `critical`
still pages) — the amtool analogue of the promtool contract `garm-fleet-alerts`
uses (whose suite includes the always-firing `Watchdog`).

## Layering

This is the general module. The concrete routing endpoints, the pager choice, the
Prometheus→Alertmanager wiring and the receiver secret belong in the operator's
private `infra` repo.
