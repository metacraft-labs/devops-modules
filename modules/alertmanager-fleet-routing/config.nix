# Pure Alertmanager config RENDERER — the single source of truth for both the
# deployed service (../alertmanager-fleet-routing/default.nix -> the NixOS
# module) and the build-time gate (../../checks/alertmanager-routing.nix ->
# packages.fleet-alertmanager-config). Same lesson as garm-fleet-alerts/rules.nix:
# the file `amtool check-config` / `amtool config routes test` replays is the
# EXACT structure the host deploys, because both come from here.
#
# It is company-agnostic. The routing OPINION is baked in — route by
# `severity` (critical -> the pager receiver, warning -> the CI-ops receiver)
# and group the fleet's alerts together by their `component` label — while the
# receiver ENDPOINTS are parameters, so a pager can be PagerDuty / a webhook /
# Slack / email, always with its secret referenced by FILE (never inlined).
{
  lib,

  # The `component` label value that identifies this fleet's alerts (the
  # garm-fleet-alerts library stamps `component: garm-fleet` on every rule). Its
  # subtree is grouped together and can carry fleet-specific inhibition.
  component ? "garm-fleet",

  # Receiver NAMES for the two severity buckets + the catch-all. These must be
  # keys of `receivers` below.
  criticalReceiver ? "pager",
  warningReceiver ? "ci-ops",
  defaultReceiver ? "default",

  # Pluggable receiver ENDPOINTS: name -> Alertmanager receiver config (minus the
  # `name` field, which is derived from the key). Any receiver kind Alertmanager
  # understands works here — `pagerduty_configs`, `webhook_configs`,
  # `slack_configs`, `email_configs`, … Secrets belong in the `*_file` variants
  # (`routing_key_file`, `api_url_file`, …), never inline. The defaults are inert
  # loopback webhooks so the rendered config is valid + routable WITHOUT any
  # credentials (what the gate exercises); a real deployment overrides them.
  receivers ? {
    "${defaultReceiver}" = { };
    "${criticalReceiver}".webhook_configs = [ { url = "http://127.0.0.1:9099/pager"; } ];
    "${warningReceiver}".webhook_configs = [ { url = "http://127.0.0.1:9099/ci-ops"; } ];
  },

  # Grouping. `topGroupBy` is the default; the `component` subtree regroups the
  # fleet's alerts together (by `component` + `severity`) so a burst of
  # runner-chain alerts is one page per severity, not one page per alertname.
  topGroupBy ? [
    "alertname"
    "component"
  ],
  fleetGroupBy ? [
    "component"
    "severity"
  ],
  groupWait ? "30s",
  groupInterval ? "5m",
  repeatInterval ? "4h",

  global ? {
    resolve_timeout = "5m";
  },

  # Sane default inhibition:
  #   * a critical alert silences a warning alert with the same
  #     (component, instance) — the classic severity squelch;
  #   * a controller-down alert silences its dependent fleet alerts on the same
  #     instance (a dead controller makes every downstream `garm_*` alert fire —
  #     page the cause, not the symptoms). `controllerDownSourceMatchers` names
  #     the controller-down alert so this stays overridable / non-garm-specific.
  severityInhibit ? true,
  controllerDownInhibit ? true,
  controllerDownSourceMatchers ? [ ''alertname="GarmControllerDown"'' ],
  extraInhibitRules ? [ ],

  # Additional first-level routes (evaluated before the severity catch-alls), for
  # concrete per-team / per-org routing an operator layers on top.
  extraRoutes ? [ ],

  # DEAD-MAN'S SWITCH (alerting-methodology.md). When `deadManReceiver` names a
  # receiver, the always-firing Watchdog alert is routed to it on a SHORT cadence
  # — that receiver pings an OFF-HOST heartbeat sink (Healthchecks) every
  # interval, so when this Alertmanager / host / network dies the pings STOP and
  # the sink alarms. This route is placed FIRST (before the component subtree) so
  # the Watchdog never falls through to the CI-ops / pager buckets. Left null =>
  # no dead-man route rendered (the hermetic default render stays credential-free
  # and unchanged).
  deadManReceiver ? null,
  deadManMatchers ? [ ''alertname="Watchdog"'' ],
  # The heartbeat cadence. Kept short so a missed ping is noticed quickly; must be
  # < the Healthchecks check's grace period.
  deadManPingInterval ? "1m",
}:
let
  inherit (lib) optional mapAttrsToList;

  matcher = label: value: ''${label}="${value}"'';

  severityRoutes = [
    {
      matchers = [ (matcher "severity" "critical") ];
      receiver = criticalReceiver;
    }
    {
      matchers = [ (matcher "severity" "warning") ];
      receiver = warningReceiver;
    }
  ];

  # component=<fleet> subtree: keep the receiver split by severity but regroup so
  # the fleet's alerts notify together.
  fleetRoute = {
    matchers = [ (matcher "component" component) ];
    group_by = fleetGroupBy;
    receiver = warningReceiver; # component-but-no-severity fallback
    routes = severityRoutes;
  };

  # Dead-man's-switch route: the always-firing Watchdog goes STRAIGHT to the
  # heartbeat receiver, on a short cadence, and never continues to other routes.
  # group_by [] collapses every Watchdog into one aggregation so the ping fires
  # once per interval regardless of extra labels.
  deadManRoutes = optional (deadManReceiver != null) {
    matchers = deadManMatchers;
    receiver = deadManReceiver;
    group_by = [ ];
    group_wait = "0s";
    group_interval = deadManPingInterval;
    repeat_interval = deadManPingInterval;
    continue = false;
  };

  inhibitRules =
    (optional severityInhibit {
      source_matchers = [ (matcher "severity" "critical") ];
      target_matchers = [ (matcher "severity" "warning") ];
      equal = [
        "component"
        "instance"
      ];
    })
    ++ (optional controllerDownInhibit {
      source_matchers = controllerDownSourceMatchers;
      target_matchers = [ (matcher "component" component) ];
      equal = [ "instance" ];
    })
    ++ extraInhibitRules;
in
{
  inherit global;

  route = {
    receiver = defaultReceiver;
    group_by = topGroupBy;
    group_wait = groupWait;
    group_interval = groupInterval;
    repeat_interval = repeatInterval;
    routes = deadManRoutes ++ [ fleetRoute ] ++ extraRoutes ++ severityRoutes;
  };

  receivers = mapAttrsToList (name: cfg: { inherit name; } // cfg) receivers;

  inhibit_rules = inhibitRules;
}
