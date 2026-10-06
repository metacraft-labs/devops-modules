# GARM runner-fleet Prometheus alert-rule LIBRARY (general, parametric,
# company-agnostic).
#
# This is a PURE function: given a set of thresholds it returns the YAML text of
# a Prometheus rule file. Both the NixOS module (./default.nix) and the promtool
# gate (../../checks/fleet-alerting.nix) render from THIS one source, so the
# exact text that ships is the exact text `promtool test rules` replays.
#
# It covers every failure mode in a GARM runner chain, mapped to metric names
# VERIFIED live on a real controller (high-mem-server :9997, 2026-09-08):
#
#   garm_health{controller_id,...}                         -> controller unhealthy
#   up{job="garm"}                                         -> controller/host down
#   garm_organization_pool_manager_status{name,running}    -> pool manager stopped
#   garm_runner_errors_total{operation,provider}           -> provider CreateInstance fails
#   garm_runner_operations_total{operation,provider}       -> (denominator for the ratio)
#   garm_github_rate_limit_remaining{credential_name,...}  -> GitHub throttle imminent
#   garm_scaleset_{status,max_runners,min_idle_runners,    -> capacity / STARVATION
#                  desired_runner_count,info}                  (pool mode: garm_pool_*)
#   garm_job_status{owner,requested_labels,status}         -> queued-job demand
#                                                             AND jobs-served (RC5)
#   garm_runner_operations_total{operation="CreateInstance"} -> runners-created (RC5)
#   garm_webhook_received{valid,reason}                    -> HMAC failures (pool mode only)
#   garm_github_operations_total{operation=...}            -> LISTENER LIVENESS (MA6):
#     "CreateMessageSession" / "DeleteMessageSession"         live long-poll sessions
#     "GetMessage"                                            the poll interval that
#                                                             corroborates the count
#
# LISTENER LIVENESS: a scale-set controller opens ONE message session per scale
# set and long-polls it. A worker whose session dies and is never re-opened logs
# NOTHING — no error, no warning, no backoff — so the arithmetic above is the
# only signal there is (2026-09-02: four days of dead listeners, silent). See
# the `garm-fleet-listeners` group and the README section of the same name; note
# in particular that POOL mode is webhook-driven and opens no message sessions
# at all, which is why the declared count takes pools only where there are no
# scale sets.
#
# RC5 OVER-PROVISION: a thundering-herd watch for the pools cutover — runners
# CREATED / jobs SERVED over a window (`garm:overprovision_ratio`), which sits
# near 1 in the coordinated central-GARM pool topology and spikes when a
# provider spins up runners that never serve a job. See the
# `garm-fleet-overprovision` group.
#
# Plus the two checks `garm_*` CANNOT see, over metrics published by the
# companion external-checks exporter (../garm-fleet-external-checks):
#
#   github_app_installation_token_mint_ok{app}             -> App key/JWT rejected
#   github_webhook_last_delivery_ok{org,hook_id}           -> webhook delivery broken
#   probe_success{job=~webhookProbeJobRegex}               -> public endpoint down (blackbox)
#
# SCALE-SET vs POOL. The live fleet is in scale-set mode today, so the capacity
# metrics are `garm_scaleset_*`. `mode = "pool"` flips them to `garm_pool_*` for
# after the Phase-C migration. The simple renames (status/max/min) are exact; the
# STARVATION join is genuinely different between the two modes (scale sets expose
# `desired_runner_count` and a `name` that equals the job's requested class;
# pools do not), so the pool-mode starvation expression is a documented, coarser
# owner-scoped variant — see `poolSaturatedExpr`.
{
  lib,
  # The Prometheus scrape job that collects `garm_*` from the controllers.
  garmJob ? "garm",
  # "scaleset" (live today) | "pool" (post Phase-C migration).
  mode ? "scaleset",
  # Emit the always-firing `Watchdog` alert — the DEAD-MAN'S SWITCH heartbeat
  # (alerting-methodology.md). It fires continuously and is routed (by the
  # alertmanager-fleet-routing `deadManReceiver`) to an off-host Healthchecks
  # ping, so a dead Prometheus/Alertmanager/host stops the pings and the off-host
  # sink alarms. severity=none keeps it out of the pager/CI-ops buckets.
  watchdog ? true,
  # for: windows.
  controllerDownFor ? "2m",
  controllerUnhealthyFor ? "5m",
  poolManagerDownFor ? "5m",
  providerCreateFailFor ? "5m",
  providerErrorRatioFor ? "10m",
  rateLimitFor ? "5m",
  listenerShortfallFor ? "15m",
  listenerPollStalledFor ? "15m",
  starvationFor ? "10m",
  overProvisionFor ? "30m",
  appTokenMintFor ? "15m",
  webhookDeliveryFor ? "30m",
  webhookHmacFor ? "10m",
  webhookProbeFor ? "5m",
  # Instance lifecycle (leak detection). See the `garm-fleet-instance-lifecycle`
  # group for the incidents these encode.
  providerDeleteFailFor ? "15m",
  absentFromProviderFor ? "0m",
  orphanStoppedFor ? "10m",
  orphanUnattributedFor ? "30m",
  inventoryFailingFor ? "15m",
  # Thresholds.
  providerCreateFailCount ? 3, # >= this many CreateInstance failures in 15m.
  providerDeleteFailCount ? 10, # >= this many DeleteInstance failures in 15m.
  absentFromProviderCount ? 3, # >= this many "absent from provider" in 30m.
  orphanStoppedCount ? 3, # STOPPED kept instances sustained over 30m.
  providerErrorRatioCrit ? "0.2", # errors/ops ratio over 15m.
  rateLimitWarn ? 200,
  rateLimitCrit ? 50,
  # LISTENER LIVENESS (scale-set long-poll workers). A GARM in scale-set mode
  # opens ONE GitHub message session per scale set and long-polls it with
  # GetMessage; the poll returns when a message arrives or when GitHub times the
  # request out. MEASURED on a live controller (m3:9997, 2026-09-15, 31.8h of
  # counters, 6 scale sets / 6 live sessions): GetMessage rate 0.0673/s for the
  # Organization scope and 0.0594/s for the Enterprise scope, i.e. a mean
  # 44.6s / 50.5s per session and 47.4s fleet-wide — the same ~47s the
  # 2026-09-02 incident was reconstructed from. `listenerPollIntervalCrit` is
  # therefore set ~3.8x above the observed long-poll ceiling: only a session
  # that has stopped polling ALTOGETHER (rate -> 0, interval -> +Inf) reaches it.
  listenerPollWindow ? "15m",
  listenerPollIntervalCrit ? 180,
  # RC5 over-provision (thundering-herd) ratio: runners CREATED / jobs SERVED
  # over `overProvisionWindow`. Healthy pool mode is ~1 (one ephemeral runner per
  # job); a herd creates many runners per job. Only judged once at least
  # `overProvisionServedFloor` jobs have been served in the window, so a warm
  # min-idle floor during a quiet period never pages.
  overProvisionWindow ? "1h",
  overProvisionRatioCrit ? "2",
  overProvisionServedFloor ? 5,
  # Toggle the two external-check alert families (over the exporter metrics).
  externalChecks ? true,
  # Toggle the webhook alert family. Post-Phase-C only: in scale-set mode GARM
  # long-polls GitHub and there are NO webhooks, so `garm_webhook_received` never
  # exists and the exporter has no hook to probe. Authored + tested here; the
  # concrete infra instance keeps this OFF until RC3 lands the public endpoint.
  webhookChecks ? true,
  # The blackbox-exporter job that probes the public webhook hostname(s).
  webhookProbeJobRegex ? ".*webhook.*",
}:
let
  inherit (lib)
    optional
    optionals
    concatStringsSep
    concatMapStringsSep
    splitString
    genList
    concatStrings
    ;

  isPool = mode == "pool";
  s = toString;

  # Indent every non-empty line of a block by `n` spaces (for interpolating a
  # multi-line PromQL expression under a YAML `|` block scalar).
  indentBlock =
    n: str:
    let
      pad = concatStrings (genList (_: " ") n);
    in
    concatStringsSep "\n" (map (l: if l == "" then "" else pad + l) (splitString "\n" str));

  # ── Renderers (data -> YAML). Every rule is emitted through these so the
  # indentation is correct BY CONSTRUCTION, not by hand-aligning strings. ──────
  #
  # Alert: { name, expr, for?, severity, summary, description }.
  # `expr` may be multi-line; it is rendered as a `|` block scalar at col 10.
  # `summary`/`description` are YAML double-quoted — any literal `"` inside must
  # already be written as `\"`.
  mkAlert =
    a:
    concatStringsSep "\n" (
      [
        "      - alert: ${a.name}"
        "        expr: |"
        (indentBlock 10 a.expr)
      ]
      ++ optional (a ? for) "        for: ${a.for}"
      ++ [
        "        labels:"
        "          severity: ${a.severity}"
        "          component: garm-fleet"
        "        annotations:"
        "          summary: \"${a.summary}\""
        "          description: \"${a.description}\""
      ]
    );

  # Recording rule: { record, expr }.
  mkRecord =
    r:
    concatStringsSep "\n" [
      "      - record: ${r.record}"
      "        expr: |"
      (indentBlock 10 r.expr)
    ];

  # Group: { name, comment?, records? [ ], rules [ ] }.
  mkGroup =
    g:
    concatStringsSep "\n" (
      (optionals (g ? comment) (map (c: "  ${c}") g.comment))
      ++ [
        "  - name: ${g.name}"
        "    rules:"
      ]
      ++ map mkRecord (g.records or [ ])
      ++ map mkAlert (g.rules or [ ])
    );

  # Capacity metric family, selected by mode.
  m = {
    maxRunners = if isPool then "garm_pool_max_runners" else "garm_scaleset_max_runners";
    desired = "garm_scaleset_desired_runner_count"; # scale-set only
    info = if isPool then "garm_pool_info" else "garm_scaleset_info";
    ownerLabel = if isPool then "pool_owner" else "scaleset_owner";
  };

  # ── STARVATION join (see header). Scale-set: saturated == desired >= max,
  # joined to queued jobs by (owner, class) where scale-set `name` == the job's
  # `requested_labels`. This is the exact live shape: on 2026-09-08 scaleset
  # id=5 (eph-linux-x64, metacraft-labs) had desired=6, max=6 with an
  # eph-linux-x64 job queued — a real starvation this catches.
  scalesetSaturatedExpr = ''
    max by (garm_owner, garm_class) (
      label_replace(
        label_replace(
          (${m.desired} >= bool ${m.maxRunners})
            * on (id) group_left(${m.ownerLabel}, name) ${m.info},
          "garm_owner", "$1", "${m.ownerLabel}", "(.*)"),
        "garm_class", "$1", "name", "(.*)")
    )'';

  # Pool mode: pools expose no `desired_runner_count` and no class `name` that
  # matches a job's label set, so saturation is "running runners in the pool >=
  # max" and the queued-job join degrades to OWNER scope. Tighten to label-set
  # membership once the pool-mode requested_labels/pool-tags mapping is settled.
  poolSaturatedExpr = ''
    max by (garm_owner) (
      label_replace(
        (
          count by (pool_id) (garm_runner_status{status="running"})
            >= bool label_replace(${m.maxRunners}, "pool_id", "$1", "id", "(.*)")
        )
          * on (pool_id) group_left(${m.ownerLabel})
            label_replace(${m.info}, "pool_id", "$1", "id", "(.*)"),
        "garm_owner", "$1", "${m.ownerLabel}", "(.*)")
    )'';

  queuedJobsExpr = ''
    count by (garm_owner, garm_class) (
      label_replace(
        label_replace(
          garm_job_status{status="queued"},
          "garm_owner", "$1", "owner", "(.*)"),
        "garm_class", "$1", "requested_labels", "(.*)")
    )'';

  starvationExpr =
    if isPool then
      ''
        garm:class_queued_jobs
          and on (garm_owner) (garm:class_saturated == 1)''
    else
      ''
        garm:class_queued_jobs
          and on (garm_owner, garm_class) (garm:class_saturated == 1)'';

  # ── LISTENER LIVENESS (see the `garm-fleet-listeners` group below). ─────────
  #
  # DECLARED LISTENERS. One message session per SCALE SET. Pools are counted
  # only on controllers that declare no scale sets, and that is deliberate, not
  # laziness: MEASURED on the two live controllers 2026-09-15, a POOL-mode GARM
  # opens no message sessions at all — high-mem-server:9997 exports 18
  # `garm_pool_info`, `garm_webhook_received` (8368 valid), and ZERO
  # `garm_github_operations_total{operation=~".*MessageSession|GetMessage"}`
  # series, because pool mode is webhook-driven.
  #
  # BE PRECISE ABOUT WHAT THE `unless` BUYS. A pool-ONLY controller is already
  # excluded from the shortfall alert by vector matching alone: with no
  # message-session counters there is no garm:message_sessions_live series on
  # that instance, and `declared - live` over a missing right-hand side is
  # EMPTY, not `declared - 0`. So counting its pools would NOT by itself page
  # forever (verified 2026-09-15 against the live fleet: both the shipped
  # expression and a naive `count(garm_scaleset_info or garm_pool_info)` variant
  # return zero series). It would page forever only if the live term ALSO
  # defaulted an absent creates counter to zero — which is exactly the mistake
  # the `or 0 * <creates>` arm below invites on the delete term, so the risk is
  # real but conditional.
  #
  # What the `unless on (instance)` actually prevents is a MIXED controller —
  # one exporting both families — having its pools added on top of its scale
  # sets, which would invent a permanent phantom shortfall there, because pools
  # open no sessions to cover the inflated expectation. It also keeps the count
  # on the DECLARED TOTAL, so a fleet that retires its scale sets in favour of
  # pools is still counted rather than silently dropping to nothing.
  declaredListenersExpr = ''
    count by (instance) (
      ${m.info}
        or
      (${if isPool then "garm_scaleset_info" else "garm_pool_info"} unless on (instance) ${m.info})
    )'';

  # LIVE SESSIONS. Both counters reset together when GARM restarts, so the raw
  # difference is restart-safe; the `for:` on the alert covers the seconds in
  # which the sessions are being re-opened. The `or 0 * <creates>` arm matters:
  # a controller that has not deleted a session yet exports NO
  # DeleteMessageSession series at all, and `sum(a) - sum(b)` with an empty `b`
  # is EMPTY — the rule would go silent on exactly the healthy-so-far controller
  # it is meant to watch.
  liveSessionsExpr = ''
    sum by (instance) (garm_github_operations_total{operation="CreateMessageSession"})
      -
    (
      sum by (instance) (garm_github_operations_total{operation="DeleteMessageSession"})
        or
      0 * sum by (instance) (garm_github_operations_total{operation="CreateMessageSession"})
    )'';

  # CORROBORATING SIGNAL: mean seconds between GetMessage long-polls per live
  # session. rate(GetMessage) is polls/second across all of the controller's
  # sessions, so live / rate is the per-session interval — the arithmetic the
  # 2026-09-02 session count was actually recovered from (one live org session
  # polling at ~47s; two enterprise sessions at ~24s, exactly half). A session
  # that is counted live but has stopped listening drives rate -> 0 and the
  # interval -> +Inf.
  pollIntervalExpr = ''
    garm:message_sessions_live
      / sum by (instance) (rate(garm_github_operations_total{operation="GetMessage"}[${listenerPollWindow}]))'';

  # DEAD-MAN'S SWITCH heartbeat. `vector(1)` is always 1, so this alert is always
  # firing; the routing layer sends it to an off-host Healthchecks ping. Its
  # absence (dead Prometheus/Alertmanager/host) is what actually raises the alarm.
  watchdogGroup = {
    name = "garm-fleet-watchdog";
    comment = [
      "# ── DEAD-MAN'S SWITCH (always-firing heartbeat) ──"
      "# Routed off-host (Healthchecks) by alertmanager-fleet-routing's"
      "# deadManReceiver. Silence = the alerter itself is dead. See"
      "# metacraft-dev-guidelines/policies/alerting-methodology.md."
    ];
    rules = [
      {
        name = "Watchdog";
        expr = "vector(1)";
        severity = "none";
        summary = "Alerting pipeline heartbeat (always firing)";
        description = "This alert is always firing. It is routed to an off-host dead-man's switch that alarms if these notifications STOP arriving — i.e. if Prometheus, Alertmanager, this host, or the network has died. If YOU are reading this as a page, the routing is misconfigured (the Watchdog must go only to the dead-man receiver).";
      }
    ];
  };

  groups =
    optionals watchdog [ watchdogGroup ]
    ++ [
      {
        name = "garm-fleet-controller";
        comment = [ "# ── Controller / host reachability & health ──" ];
        rules = [
          {
            name = "GarmControllerDown";
            expr = "up{job=\"${garmJob}\"} == 0";
            for = controllerDownFor;
            severity = "critical";
            summary = "GARM controller unreachable ({{ $labels.instance }})";
            description = "Prometheus cannot scrape GARM at {{ $labels.instance }} (job ${garmJob}) for ${controllerDownFor}. No runners can be created or reaped while the controller is down — check the garm.service unit and the host.";
          }
          {
            name = "GarmControllerUnhealthy";
            expr = "garm_health == 0";
            for = controllerUnhealthyFor;
            severity = "critical";
            summary = "GARM controller reports unhealthy ({{ $labels.controller_id }})";
            description = "garm_health for controller {{ $labels.controller_id }} has been 0 for ${controllerUnhealthyFor} — the process is up but degraded. Check the garm.service journal.";
          }
          {
            name = "GarmPoolManagerNotRunning";
            expr = "garm_organization_pool_manager_status == 0";
            for = poolManagerDownFor;
            severity = "critical";
            summary = "GARM pool manager not running ({{ $labels.name }})";
            description = "The pool manager for org {{ $labels.name }} has been stopped for ${poolManagerDownFor}. That org gets no new runners even though the controller is up — restart / check the org credentials.";
          }
        ];
      }
      {
        name = "garm-fleet-provider";
        comment = [ "# ── Provider (CreateInstance) health ──" ];
        rules = [
          {
            name = "GarmProviderCreateFailures";
            expr = "increase(garm_runner_errors_total{operation=\"CreateInstance\"}[15m]) >= ${s providerCreateFailCount}";
            for = providerCreateFailFor;
            severity = "warning";
            summary = "GARM provider failing to create runners ({{ $labels.provider }})";
            description = "Provider {{ $labels.provider }} has had at least ${s providerCreateFailCount} CreateInstance failures in the last 15m. The backend (incus/libvirt/tart/EC2) is likely broken — check the provider host.";
          }
          {
            name = "GarmProviderHighErrorRatio";
            # Plain division is safe here: every error is also a counted
            # operation (operations_total >= errors_total per operation/provider),
            # so the denominator is never 0 while the numerator is > 0, and a
            # no-traffic provider yields 0/0 = NaN which never trips `> x`. (Do NOT
            # reintroduce clamp_min(rate, 1): rates are per-SECOND, so a floor of 1
            # makes the ratio meaningless below 1 failed op/s.)
            expr = ''
              rate(garm_runner_errors_total[15m])
                / rate(garm_runner_operations_total[15m])
                > ${providerErrorRatioCrit}'';
            for = providerErrorRatioFor;
            severity = "critical";
            summary = "GARM provider failing >${providerErrorRatioCrit} of operations ({{ $labels.provider }})";
            description = "Provider {{ $labels.provider }} is failing more than ${providerErrorRatioCrit} of its runner operations over 15m ({{ $value | humanizePercentage }}). The backend is broken (incus/libvirt/tart down, or AWS quota/subnet/AMI errors) — runners are not being provisioned.";
          }
        ];
      }
      {
        name = "garm-fleet-instance-lifecycle";
        comment = [
          "# ── Instance lifecycle: deletes that fail, instances GARM stops seeing, and"
          "# ── the orphans both leave behind on the provider hosts."
          "# 2026-09-22/23: ~88k failed provider deletes/24h (a delete storm, see"
          "# GarmProviderDeleteFailures), ~210 Windows VMs leaked on high-mem-server"
          "# because the provider's ListInstances omitted them, and ~100 STOPPED"
          "# containers filled gpu-server-001/002's storage pool."
          "# vmh_* series come from the vm-harness-serve inventory exporter"
          "# (services.vm-harness-serve.inventoryExporter) on each provider host."
        ];
        rules = [
          {
            name = "GarmProviderDeleteFailures";
            expr = "sum by (provider) (increase(garm_runner_errors_total{operation=\"DeleteInstance\"}[15m])) >= ${s providerDeleteFailCount}";
            for = providerDeleteFailFor;
            severity = "warning";
            summary = "GARM cannot delete runners on {{ $labels.provider }}";
            description = "Provider {{ $labels.provider }} has failed at least ${s providerDeleteFailCount} DeleteInstance calls in each 15m window for ${providerDeleteFailFor}. Finished runners are not being reclaimed on that host (unreachable serve daemon, or a teardown that keeps failing, e.g. ZFS `dataset is busy`) — they will accumulate until the host's storage fills.";
          }
          {
            name = "GarmInstancesAbsentFromProvider";
            expr = "sum by (provider) (increase(garm_runner_absent_from_provider_total[30m])) >= ${s absentFromProviderCount}";
            for = absentFromProviderFor;
            severity = "warning";
            summary = "GARM runners missing from {{ $labels.provider }}'s instance list";
            description = "At least ${s absentFromProviderCount} instances GARM believes are running were absent from provider {{ $labels.provider }}'s ListInstances in 30m. They are routed to deletion, but repeated absences mean the provider cannot see its own instances (enumeration/attribution broken) — before the fix this is exactly how ~210 VMs leaked.";
          }
          {
            name = "VmhEphemeralStoppedOrphans";
            expr = "sum by (instance, backend) (min_over_time(vmh_ephemeral_instances{state=\"stopped\"}[30m])) >= ${s orphanStoppedCount}";
            for = orphanStoppedFor;
            severity = "warning";
            summary = "Stopped runner instances are piling up on {{ $labels.instance }} ({{ $labels.backend }})";
            description = "{{ $labels.instance }} has held at least ${s orphanStoppedCount} STOPPED per-job {{ $labels.backend }} instances continuously for 30m. A finished ephemeral runner is deleted within minutes, so these are orphans whose teardown failed or was never issued; they consume storage until the pool is full (gpu-server-001/002, 2026-09-23).";
          }
          {
            name = "VmhEphemeralUnattributedInstances";
            expr = "sum by (instance, backend) (min_over_time(vmh_ephemeral_instances{attributed=\"false\"}[1h])) > 0";
            for = orphanUnattributedFor;
            severity = "warning";
            summary = "Runner instances with no owning GARM pool on {{ $labels.instance }} ({{ $labels.backend }})";
            description = "{{ $labels.instance }} has carried {{ $value }} runner-named {{ $labels.backend }} instances with no GARM ownership record for over an hour. No pool lists them, so GARM will never delete them: they are orphans (typically created before attribution existed, or by a create whose labelling failed).";
          }
          {
            name = "VmhEphemeralInventoryFailing";
            expr = "vmh_ephemeral_list_success == 0";
            for = inventoryFailingFor;
            severity = "warning";
            summary = "{{ $labels.instance }} cannot enumerate its {{ $labels.backend }} instances";
            description = "`vm-harness ephemeral-list --backend {{ $labels.backend }}` has failed on {{ $labels.instance }} for ${inventoryFailingFor}. GARM's ListInstances for this host fails closed while this persists, so runners there are neither confirmed nor reconciled — fix the hypervisor/daemon access.";
          }
        ];
      }
      {
        name = "garm-fleet-github";
        comment = [ "# ── GitHub API rate limits ──" ];
        rules = [
          {
            name = "GarmGithubRateLimitLow";
            expr = "garm_github_rate_limit_remaining < ${s rateLimitWarn}";
            for = rateLimitFor;
            severity = "warning";
            summary = "GitHub API rate limit low ({{ $labels.credential_name }})";
            description = "Credential {{ $labels.credential_name }} has {{ $value }} GitHub API requests remaining (< ${s rateLimitWarn}) for ${rateLimitFor}. Approaching a throttle that will stall runner provisioning.";
          }
          {
            name = "GarmGithubRateLimitCritical";
            expr = "garm_github_rate_limit_remaining < ${s rateLimitCrit}";
            for = rateLimitFor;
            severity = "critical";
            summary = "GitHub API rate limit critically low ({{ $labels.credential_name }})";
            description = "Credential {{ $labels.credential_name }} has only {{ $value }} GitHub API requests remaining (< ${s rateLimitCrit}). GARM is about to be throttled — runner provisioning will stall.";
          }
        ];
      }
      {
        name = "garm-fleet-listeners";
        comment = [
          "# ── LISTENER LIVENESS (the 2026-09-02 silent failure) ──"
          "# GARM opens ONE GitHub message session per scale set and long-polls it."
          "# When a worker's session dies and is never re-opened, GARM logs NOTHING"
          "# — no error, no warning, no backoff — and that scale set simply stops"
          "# claiming jobs. On 2026-09-02 that state lasted FOUR DAYS. The only"
          "# signal that existed was this arithmetic: CreateMessageSession minus"
          "# DeleteMessageSession against the declared entity count, corroborated"
          "# by the GetMessage long-poll interval. Both are duration-gated: a"
          "# controlled restart drops every session at once and must not page."
        ];
        records = [
          {
            record = "garm:listener_entities_declared";
            expr = declaredListenersExpr;
          }
          {
            record = "garm:message_sessions_live";
            expr = liveSessionsExpr;
          }
          {
            # Depends on garm:message_sessions_live, so it MUST stay after it:
            # rules inside a group are evaluated in order.
            record = "garm:message_session_poll_interval_seconds";
            expr = pollIntervalExpr;
          }
        ];
        rules = [
          {
            name = "GarmListenerSessionShortfall";
            # `-` binds tighter than `>=`, so this is (declared - live) >= 1.
            # Vector matching on `instance` is what keeps a pool-mode controller
            # out of it: with no message-session counters there is no
            # garm:message_sessions_live series for that instance and the
            # subtraction yields nothing.
            expr = "garm:listener_entities_declared - garm:message_sessions_live >= 1";
            for = listenerShortfallFor;
            severity = "critical";
            summary = "GARM listeners MISSING on {{ $labels.instance }} ({{ $value }} message session(s) short)";
            description = "Controller {{ $labels.instance }} has had {{ $value }} fewer live GitHub message session(s) (CreateMessageSession minus DeleteMessageSession) than it has declared scale sets/pools, for ${listenerShortfallFor}. Those scale sets are no longer claiming jobs and GARM will not say so — it logs no error, no warning and no backoff for a dead listener, which is how this went unnoticed for four days on 2026-09-02. Corroborate with garm:message_session_poll_interval_seconds (healthy is roughly 45-50s per session), then restart GARM on that host and confirm every scale set logs starting consumer.";
          }
          {
            name = "GarmListenerPollStalled";
            # Interval first so `$value` is the interval, not the session count.
            expr = ''
              garm:message_session_poll_interval_seconds > ${s listenerPollIntervalCrit}
                and on (instance) (garm:message_sessions_live > 0)'';
            for = listenerPollStalledFor;
            severity = "critical";
            summary = "GARM long-poll STALLED on {{ $labels.instance }} ({{ $value | printf \\\"%.0f\\\" }}s between GetMessage calls)";
            description = "Controller {{ $labels.instance }} still counts live GitHub message sessions, but the mean interval between GetMessage long-polls has been above ${s listenerPollIntervalCrit}s for ${listenerPollStalledFor} ({{ $value | printf \\\"%.0f\\\" }}s). A healthy long poll returns every 45-50s per session, so the sessions exist on paper while nothing is actually listening — the other half of the 2026-09-02 failure mode, and the signal its session count was reconstructed from. Restart GARM on that host.";
          }
        ];
      }
      {
        name = "garm-fleet-capacity";
        comment = [
          "# ── Capacity / STARVATION (the priority page) ──"
          "# Recording rules derive per-(owner,class) saturation + queued demand"
          "# from the base metrics so the alert stays legible and promtool can"
          "# assert the whole chain from raw series. See rules.nix for the join."
        ];
        records = [
          {
            record = "garm:class_saturated";
            expr = if isPool then poolSaturatedExpr else scalesetSaturatedExpr;
          }
          {
            record = "garm:class_queued_jobs";
            expr = queuedJobsExpr;
          }
        ];
        rules = [
          {
            name = "GarmFleetStarvation";
            expr = starvationExpr;
            for = starvationFor;
            severity = "critical";
            summary = "Runner STARVATION: {{ $labels.garm_owner }}/{{ $labels.garm_class }} saturated with jobs queued";
            description = "{{ $value }} job(s) have been queued for ${starvationFor} for class {{ $labels.garm_class }} (owner {{ $labels.garm_owner }}) while that class is at its runner ceiling. Jobs are starving — raise max-runners, add a qualifying host, or check that the AWS burst spill is firing.";
          }
        ];
      }
      {
        name = "garm-fleet-overprovision";
        comment = [
          "# ── OVER-PROVISION / thundering-herd ratio (RC5 cutover watch) ──"
          "# runners CREATED / jobs SERVED over ${overProvisionWindow}. The"
          "# numerator is garm_runner_operations_total{operation=CreateInstance} —"
          "# labelled only by (operation, provider), so it is summed per provider"
          "# and the ratio is a FLEET figure (a herd is a fleet phenomenon; there"
          "# is no per-(owner,class) creation counter in GARM to attribute it"
          "# finer). The denominator is a served-jobs counter DERIVED from the"
          "# garm_job_status{status=completed} gauge via a subquery increase, kept"
          "# per (owner,class) for the dashboard. Mode-independent: both base"
          "# metrics exist in scale-set and pool mode."
        ];
        records = [
          {
            record = "garm:runners_created:increase";
            expr = ''sum by (provider) (increase(garm_runner_operations_total{operation="CreateInstance"}[${overProvisionWindow}]))'';
          }
          {
            # Served jobs per (owner,class). garm_job_status is a GAUGE (1 per job
            # while its record is retained); count-of-completed rises as jobs
            # finish, and the subquery increase turns that into new completions in
            # the window (counter-reset-safe, so job-record pruning only undercounts
            # slightly at the boundary rather than going negative).
            record = "garm:jobs_served:increase";
            expr = ''
              increase(
                sum by (garm_owner, garm_class) (
                  label_replace(
                    label_replace(
                      garm_job_status{status="completed"},
                      "garm_owner", "$1", "owner", "(.*)"),
                    "garm_class", "$1", "requested_labels", "(.*)")
                )[${overProvisionWindow}:1m]
              )'';
          }
          {
            # Fleet headline ratio. clamp_min keeps the denominator >= 1 so a burst
            # of creations with zero served jobs is a large finite number, not a
            # divide-by-zero — the served-floor guard on the alert decides whether
            # that is worth paging.
            record = "garm:overprovision_ratio";
            expr = ''
              sum(garm:runners_created:increase)
                / clamp_min(sum(garm:jobs_served:increase), 1)'';
          }
        ];
        rules = [
          {
            name = "GarmFleetOverProvision";
            expr = ''
              garm:overprovision_ratio > ${overProvisionRatioCrit}
                and sum(garm:jobs_served:increase) >= ${s overProvisionServedFloor}'';
            for = overProvisionFor;
            severity = "warning";
            summary = "Runner OVER-PROVISION: {{ $value | humanize }}x more runners created than jobs served";
            description = "Over the last ${overProvisionWindow} the fleet created more than ${overProvisionRatioCrit}x as many runners as jobs it served ({{ $value | humanize }}x), sustained for ${overProvisionFor}, with at least ${s overProvisionServedFloor} jobs served — a thundering-herd over-provision. In the coordinated central-GARM pool topology this ratio should sit near 1 (one ephemeral runner per job); a spike means a provider is spinning up runners that never serve a job. Check garm:runners_created:increase per provider for the offending host and the provider CreateInstance/DeleteInstance churn.";
          }
        ];
      }
    ]
    ++ optionals externalChecks [
      {
        name = "garm-fleet-external";
        comment = [
          "# ── EXTERNAL checks: things garm_* cannot see ──"
          "# Fed by the garm-fleet-external-checks exporter, NOT by GARM. If the"
          "# exporter is down these go inactive (a blind spot, not a false page) —"
          "# the generic up==0 scrape-target alert notices a dead exporter."
        ];
        rules = [
          {
            name = "GithubAppTokenMintFailing";
            expr = "github_app_installation_token_mint_ok == 0";
            for = appTokenMintFor;
            severity = "critical";
            summary = "GitHub App token minting is failing ({{ $labels.app }})";
            description = "The garm-fleet-external-checks exporter could not mint an installation token for App {{ $labels.app }} for ${appTokenMintFor}. The App private key/JWT is rejected (rotated, revoked, clock skew, or the installation was removed) — GARM cannot register or reap runners for that org. Rotate/repair the App credential.";
          }
        ]
        ++ optionals webhookChecks [
          {
            name = "GithubWebhookDeliveryFailing";
            expr = "github_webhook_last_delivery_ok == 0";
            for = webhookDeliveryFor;
            severity = "critical";
            summary = "GitHub webhook deliveries are failing ({{ $labels.org }})";
            description = "GitHub reports the most recent webhook delivery to the controller endpoint for {{ $labels.org }} (hook {{ $labels.hook_id }}) as non-2xx for ${webhookDeliveryFor}. Job events are not reaching GARM — check the Cloudflare Tunnel / public endpoint and the org webhook config.";
          }
          {
            name = "GithubWebhookEndpointProbeDown";
            expr = "probe_success{job=~\"${webhookProbeJobRegex}\"} == 0";
            for = webhookProbeFor;
            severity = "critical";
            summary = "GARM public webhook endpoint probe is failing ({{ $labels.instance }})";
            description = "The blackbox probe of the public webhook endpoint {{ $labels.instance }} has failed for ${webhookProbeFor} (tunnel down, cert expired, or endpoint unreachable). GitHub cannot deliver workflow_job events.";
          }
        ];
      }
    ]
    ++ optionals webhookChecks [
      {
        name = "garm-fleet-webhook";
        comment = [
          "# ── GARM-side webhook HMAC (POST-PHASE-C) ──"
          "# garm_webhook_received only exists in pool mode. valid=false is an HMAC"
          "# or parse failure: a secret mismatch, a bad relay, or a spoof attempt."
        ];
        rules = [
          {
            name = "GarmWebhookHmacFailures";
            expr = "increase(garm_webhook_received{valid=\"false\"}[10m]) >= 1";
            for = webhookHmacFor;
            severity = "warning";
            summary = "GARM is rejecting webhook deliveries (HMAC/parse)";
            description = "GARM has recorded webhook deliveries with valid=\\\"false\\\" (reason {{ $labels.reason }}) for ${webhookHmacFor}. The per-entity webhook secret likely does not match GitHub, or a relay is corrupting the payload — new jobs from the affected org will not scale runners.";
          }
        ];
      }
    ];
in
''
  # GENERATED by nixos-modules/modules/garm-fleet-alerts/rules.nix — do not edit
  # the deployed copy; change the library and re-render. mode=${mode}, job=${garmJob}.
  groups:
  ${concatMapStringsSep "\n" mkGroup groups}
''
