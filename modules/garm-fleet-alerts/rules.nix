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
#   garm_job_status{owner,requested_labels,status}         -> queued-job demand,
#                                                             in-progress jobs
#                                                             AND jobs-served (RC5)
#   garm_runner_status{instance,provider,pool_id,           -> capability-pool slots,
#                      pool_owner,name,status}                 teardown stuck, live runners
#   garm_{pool,scaleset}_{min_idle_runners,status}          -> the min-idle floor
#   garm_pool_{max_runners,info}                            -> declared pool slots
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
  # Emit the `garm-fleet-instance-lifecycle` group (delete storms, instances
  # absent from the provider, gosti orphan/inventory alerts). Off for a fleet
  # that does not run the gosti-serve inventory exporter, or whose providers'
  # DeleteInstance retries are known noise (the H7 `dataset is busy` retry).
  instanceLifecycle ? true,
  # Emit the RC5 `garm-fleet-overprovision` group (thundering-herd watch).
  overProvision ? true,
  # for: windows.
  controllerDownFor ? "1m",
  controllerUnhealthyFor ? "5m",
  poolManagerDownFor ? "5m",
  providerCreateFailFor ? "15m",
  providerErrorRatioFor ? "1h",
  rateLimitFor ? "5m",
  listenerShortfallFor ? "15m",
  listenerPollStalledFor ? "15m",
  starvationFor ? "5m",
  capabilityPoolStarvationFor ? "15m",
  stuckDeletingFor ? "5m",
  liveRunnerCollapseFor ? "15m",
  overProvisionFor ? "30m",
  # keep_firing_for: holds. Each one merges a fault that flaps or retries on a
  # cadence (a provider retrying every ~20m, a controller restart that drops
  # the session counters, corpses clearing while new ones age in) into ONE
  # episode instead of a sawtooth of pages. See the comment on each rule.
  controllerDownKeepFiringFor ? "15m",
  providerKeepFiringFor ? "2h",
  listenerShortfallKeepFiringFor ? "30m",
  starvationKeepFiringFor ? "2h",
  stuckDeletingKeepFiringFor ? "2h",
  # GarmControllerDown: down NOW and up for less than this fraction of the last
  # `controllerDownWindow` — 0.84 of 1h is "down for at least 10 of the last 60
  # minutes"; keep `controllerDownBudget` (the description text) in step.
  controllerDownWindow ? "1h",
  controllerDownUpRatio ? "0.84",
  controllerDownBudget ? "10 of the last 60 minutes",
  # GarmFleetStarvation: starved for at least this many 1-minute samples of the
  # last hour (assumes the 1m evaluation interval).
  starvationMinutesPerHour ? 30,
  # GarmInstanceStuckDeleting: page once at least this many instances on one
  # controller have been in teardown for 30m+.
  stuckDeletingCount ? 5,
  # The operator's tool for finding what holds a wedged teardown, quoted in the
  # GarmInstanceStuckDeleting description.
  teardownHolderHint ? "identify the mount-namespace holders with `scripts/incus-busy-dataset-holders.sh` on the provider host",
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
  providerCreateFailCount ? 10, # >= this many CreateInstance failures in 1h.
  providerDeleteFailCount ? 10, # >= this many DeleteInstance failures in 15m.
  absentFromProviderCount ? 3, # >= this many "absent from provider" in 30m.
  orphanStoppedCount ? 3, # STOPPED kept instances sustained over 30m.
  providerErrorRatioCrit ? "0.5", # CreateInstance|Start errors/ops ratio over 1h.
  providerErrorRatioMinErrors ? 2, # ...and at least this many such errors in 1h.
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
  # Optional `comment` on a rule: a list of YAML comment lines rendered above
  # it at the rule's indentation ("" renders as a blank line). The rationale
  # for a threshold lives next to the rule in the SHIPPED file, so a re-render
  # never strips it from a deployed copy.
  mkComment = x: optionals (x ? comment) (map (c: if c == "" then "" else "      ${c}") x.comment);

  # Alert: { name, expr, for?, keepFiringFor?, severity, summary, description,
  # comment? }.
  # `expr` may be multi-line; it is rendered as a `|` block scalar at col 10.
  # `summary`/`description` are YAML double-quoted — any literal `"` inside must
  # already be written as `\"`.
  mkAlert =
    a:
    concatStringsSep "\n" (
      mkComment a
      ++ [
        "      - alert: ${a.name}"
        "        expr: |"
        (indentBlock 10 a.expr)
      ]
      ++ optional (a ? for) "        for: ${a.for}"
      ++ optional (a ? keepFiringFor) "        keep_firing_for: ${a.keepFiringFor}"
      ++ [
        "        labels:"
        "          severity: ${a.severity}"
        "          component: garm-fleet"
        "        annotations:"
        "          summary: \"${a.summary}\""
        "          description: \"${a.description}\""
      ]
    );

  # Recording rule: { record, expr, comment? }.
  mkRecord =
    r:
    concatStringsSep "\n" (
      mkComment r
      ++ [
        "      - record: ${r.record}"
        "        expr: |"
        (indentBlock 10 r.expr)
      ]
    );

  # Group: { name, comment?, records? [ ], rules? [ ], items? [ ] }.
  # `records` render first, then `rules` (alerts), then `items` — a list that
  # mixes the two in the given order, for a group in which an alert must sit
  # right after the recording rules it reads (rules in a group are evaluated in
  # order).
  mkItem = x: if x ? record then mkRecord x else mkAlert x;
  mkGroup =
    g:
    concatStringsSep "\n" (
      (optionals (g ? comment) (map (c: if c == "" then "" else "  ${c}") g.comment))
      ++ [
        "  - name: ${g.name}"
        "    rules:"
      ]
      ++ map mkRecord (g.records or [ ])
      ++ map mkAlert (g.rules or [ ])
      ++ map mkItem (g.items or [ ])
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

  runningJobsExpr = ''
    count by (garm_owner, garm_class) (
      label_replace(
        label_replace(
          garm_job_status{status="in_progress"},
          "garm_owner", "$1", "owner", "(.*)"),
        "garm_class", "$1", "requested_labels", "(.*)")
    )'';

  # STARVED = saturated with jobs queued AND running none of the class's jobs.
  # The saturation join is per (owner, class) for scale sets and owner-scoped
  # for pools (see poolSaturatedExpr); the running-jobs exclusion is per class
  # in both, since garm_job_status carries the class in either mode.
  starvedExpr =
    if isPool then
      ''
        (
          garm:class_queued_jobs
            and on (garm_owner) (garm:class_saturated == 1)
        )
          unless on (garm_owner, garm_class) garm:class_running_jobs''
    else
      ''
        (
          garm:class_queued_jobs
            and on (garm_owner, garm_class) (garm:class_saturated == 1)
        )
          unless on (garm_owner, garm_class) garm:class_running_jobs'';

  # "N or more instances whose matching series is a 1 for N of the last 30
  # one-minute samples". 28 of 30 so that one missed evaluation does not reset
  # an instance's age.
  stuckDeletingExpr = "count by (instance) (count_over_time(garm:instance_deleting[30m]) >= 28) >= ${s stuckDeletingCount}";

  providerErrorRatioText = if providerErrorRatioCrit == "0.5" then "half" else providerErrorRatioCrit;

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
      ""
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

  groups = [
    {
      name = "garm-fleet-controller";
      comment = [ "# ── Controller / host reachability & health ──" ];
      rules = [
        {
          name = "GarmControllerDown";
          comment = [
            "# DOWN NOW, AND DOWN FOR 10 OF THE LAST 60 MINUTES (OBS-AREQ7,"
            "# 2026-11-16). Measured 2026-11-02..16 (`up{job=\"garm\"}`): 37 down runs,"
            "# 25 of them 1-7 minutes — a controller restart during a deploy"
            "# activation, or one missed scrape of m3 over NetBird — and each paged"
            "# under the old `for: 2m` (15 episodes in two weeks, 6 in W47). The"
            "# outages that mattered lasted 13-94 minutes (m3 on 11-02 x3, 11-03 x2,"
            "# 11-07, 11-15 18:47Z, and the 11-16 06:46Z cordon at 93m)."
            "#"
            "# The condition is a FRACTION, not a long `for:`: a continuous outage"
            "# crosses it 10 minutes in, as `for: 10m` would, but a controller that"
            "# keeps dropping for four or five minutes at a time (m3's median down"
            "# run is 4m) accumulates to it too, where a `for: 10m` would never"
            "# complete and would hide it. `up == 0` in front makes it resolve as"
            "# soon as the controller answers; `keep_firing_for: 15m` keeps a"
            "# flapping one a single alert. Replayed: 15 -> 9 episodes in 14 days,"
            "# 2 in W47 (11-15 18:56Z, 11-16 06:55Z)."
          ];
          expr = ''
            (up{job="${garmJob}"} == 0)
              and on (instance, job)
            (avg_over_time(up{job="${garmJob}"}[${controllerDownWindow}]) < ${controllerDownUpRatio})'';
          for = controllerDownFor;
          keepFiringFor = controllerDownKeepFiringFor;
          severity = "critical";
          summary = "GARM controller unreachable ({{ $labels.instance }})";
          description = "Prometheus cannot scrape GARM at {{ $labels.instance }} (job ${garmJob}), and it has been down for at least ${controllerDownBudget}. No runners can be created or reaped while the controller is down — check the garm.service unit and the host.";
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
          comment = [
            "# BOTH PROVIDER ALERTS ARE PER (controller, provider) OVER ONE HOUR, WITH A"
            "# HOLD. Measured 2026-11-02..16 from garm_runner_{errors,operations}_total:"
            "#"
            "#   * The old 15m windows turned one incident into a sawtooth. A provider"
            "#     that cannot create retries about every 20 minutes, so `increase[15m]`"
            "#     crossed 3 and fell back on every retry: hms-incus-terraform during"
            "#     the 2026-11-12/13 ZFS write-latency incident (11-26 failed creates an"
            "#     hour, 18:00-00:00Z) produced 14 separate warning episodes in six"
            "#     hours. 166 CreateFailures episodes in 14 days, 62 in W47."
            "#   * The ratio alert also covered DeleteInstance and ListInstances. 1,761"
            "#     of its 2,559 episodes were DeleteInstance on incus providers — the H7"
            "#     `dataset is busy` teardown retry, which fails and retries to success"
            "#     by design. Teardown that stops converging is GarmInstanceStuckDeleting's"
            "#     case, not this one. ListInstances errors are reconcile-loop reads that"
            "#     the next loop repeats."
            "#   * A low-volume provider read as 100% failing on one error (one failed"
            "#     create out of one in 15m), and the ratio flapped across 0.2 on busy"
            "#     ones (gpu001-incus at 5-30% for most of the window)."
            "#"
            "# So the two alerts now split the provisioning failures between them"
            "# instead of both firing on the same incident:"
            "#"
            "#   GarmProviderHighErrorRatio — a provider failing MOST of its create /"
            "#     start attempts (> 50% over 1h, at least 2 failures) for 1h. The real"
            "#     faults in the window all have this shape: gpu002-incus 11-04 19:00Z-"
            "#     11-05 05:00Z (100%), hms-incus-terraform on 11-06, 11-07, 11-09 and"
            "#     during the ZFS incident 11-12 19:00Z-11-13 00:00Z (~100%), hms-incus"
            "#     and hms-libvirt on 11-09 and 11-11, m3-tart-linux from 11-12 on (3 of 3"
            "#     every hour), m4-ah-sandbox `Start` from 11-11 on. Every one still"
            "#     fires. It is a WARNING now: the page for lost capacity is the symptom"
            "#     — GarmFleetStarvation, GarmCapabilityPoolStarvation and"
            "#     GarmLiveRunnerCollapse — and a provider failing is its cause."
            "#   GarmProviderCreateFailures — a BUSY provider losing a share of its"
            "#     creates (>= 10 failed in an hour) while most still succeed, which the"
            "#     ratio cannot see: gpu001-incus failed 17-51 creates an hour at 25-65%"
            "#     on 11-05, 11-06 and 11-08."
            "#"
            "# keep_firing_for: 2h merges the 20-minute retry cadence into one episode"
            "# per incident. Replayed over the 14 days: HighErrorRatio 2,559 -> 21"
            "# episodes, CreateFailures 166 -> 7."
          ];
          # The `unless` hands a provider failing MOST of its creates to
          # GarmProviderHighErrorRatio, so one incident is one alert.
          expr = ''
            (
              sum by (instance, provider) (increase(garm_runner_errors_total{operation="CreateInstance"}[1h])) >= ${s providerCreateFailCount}
            )
              unless on (instance, provider)
            (
              sum by (instance, provider) (increase(garm_runner_errors_total{operation="CreateInstance"}[1h]))
                / sum by (instance, provider) (increase(garm_runner_operations_total{operation="CreateInstance"}[1h]))
                > ${providerErrorRatioCrit}
            )'';
          for = providerCreateFailFor;
          keepFiringFor = providerKeepFiringFor;
          severity = "warning";
          summary = "GARM provider losing creates ({{ $labels.provider }})";
          description = "Provider {{ $labels.provider }} on {{ $labels.instance }} has failed {{ $value | printf \\\"%.0f\\\" }} CreateInstance calls in the last hour while most of its creates still succeed. The backend (incus/libvirt/tart/EC2) is degraded rather than down — check the provider host. When most creates fail, GarmProviderHighErrorRatio fires instead.";
        }
        {
          name = "GarmProviderHighErrorRatio";
          # Plain division is safe here: every error is also a counted
          # operation (operations_total >= errors_total per operation/provider),
          # so the denominator is never 0 while the numerator is > 0, and a
          # no-traffic provider yields 0/0 = NaN which never trips `> x`.
          # Only CreateInstance|Start: DeleteInstance failures are the H7
          # teardown retry (GarmInstanceStuckDeleting judges teardown) and
          # ListInstances errors are reconcile reads the next loop repeats.
          expr = ''
            (
              sum by (instance, provider) (increase(garm_runner_errors_total{operation=~"CreateInstance|Start"}[1h]))
                / sum by (instance, provider) (increase(garm_runner_operations_total{operation=~"CreateInstance|Start"}[1h]))
                > ${providerErrorRatioCrit}
            )
              and on (instance, provider)
            (
              sum by (instance, provider) (increase(garm_runner_errors_total{operation=~"CreateInstance|Start"}[1h])) >= ${s providerErrorRatioMinErrors}
            )'';
          for = providerErrorRatioFor;
          keepFiringFor = providerKeepFiringFor;
          severity = "warning";
          summary = "GARM provider failing most of its creates ({{ $labels.provider }})";
          description = "Provider {{ $labels.provider }} on {{ $labels.instance }} has failed more than ${providerErrorRatioText} of its CreateInstance/Start calls over the last hour ({{ $value | humanizePercentage }}), for an hour. Its pools are not producing runners — the backend is broken (incus/libvirt/tart down, or AWS quota/subnet/AMI errors). If jobs are waiting on it, GarmFleetStarvation or GarmCapabilityPoolStarvation pages as well.";
        }
      ];
    }
  ]
  ++ optionals instanceLifecycle [
    {
      name = "garm-fleet-instance-lifecycle";
      comment = [
        "# ── Instance lifecycle: deletes that fail, instances GARM stops seeing, and"
        "# ── the orphans both leave behind on the provider hosts."
        "# 2026-09-22/23: ~88k failed provider deletes/24h (a delete storm, see"
        "# GarmProviderDeleteFailures), ~210 Windows VMs leaked on high-mem-server"
        "# because the provider's ListInstances omitted them, and ~100 STOPPED"
        "# containers filled gpu-server-001/002's storage pool."
        "# gosti_* series come from the gosti-serve inventory exporter"
        "# (services.gosti-serve.inventoryExporter) on each provider host."
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
          name = "GostiEphemeralStoppedOrphans";
          expr = "sum by (instance, backend) (min_over_time(gosti_ephemeral_instances{state=\"stopped\"}[30m])) >= ${s orphanStoppedCount}";
          for = orphanStoppedFor;
          severity = "warning";
          summary = "Stopped runner instances are piling up on {{ $labels.instance }} ({{ $labels.backend }})";
          description = "{{ $labels.instance }} has held at least ${s orphanStoppedCount} STOPPED per-job {{ $labels.backend }} instances continuously for 30m. A finished ephemeral runner is deleted within minutes, so these are orphans whose teardown failed or was never issued; they consume storage until the pool is full (gpu-server-001/002, 2026-09-23).";
        }
        {
          name = "GostiEphemeralUnattributedInstances";
          expr = "sum by (instance, backend) (min_over_time(gosti_ephemeral_instances{attributed=\"false\"}[1h])) > 0";
          for = orphanUnattributedFor;
          severity = "warning";
          summary = "Runner instances with no owning GARM pool on {{ $labels.instance }} ({{ $labels.backend }})";
          description = "{{ $labels.instance }} has carried {{ $value }} runner-named {{ $labels.backend }} instances with no GARM ownership record for over an hour. No pool lists them, so GARM will never delete them: they are orphans (typically created before attribution existed, or by a create whose labelling failed).";
        }
        {
          name = "GostiEphemeralInventoryFailing";
          expr = "gosti_ephemeral_list_success == 0";
          for = inventoryFailingFor;
          severity = "warning";
          summary = "{{ $labels.instance }} cannot enumerate its {{ $labels.backend }} instances";
          description = "`gosti ephemeral-list --backend {{ $labels.backend }}` has failed on {{ $labels.instance }} for ${inventoryFailingFor}. GARM's ListInstances for this host fails closed while this persists, so runners there are neither confirmed nor reconciled — fix the hypervisor/daemon access.";
        }
      ];
    }
  ]
  ++ [
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
          comment = [
            "# keep_firing_for: 30m bridges a controller restart. The session count is"
            "# CreateMessageSession minus DeleteMessageSession, both counters, so a"
            "# restart drops the series and starts them again from zero: a shortfall"
            "# that survives the restart re-entered `pending` and paged again 15m"
            "# later. Measured 2026-11-09..16 on m3:9997: 5 episodes, all ONE fault"
            "# (6 scale sets declared, 4 sessions live — still so at 2026-11-16 10:00Z),"
            "# split at the m3 controller restarts of 11-12 19:59Z and 11-15 00:33Z."
            "# With the hold it is 3 episodes, each a real shortfall; the 6-hour"
            "# recovery on 11-12 (12:18Z-18:19Z) still resolves and re-fires."
          ];
          expr = "garm:listener_entities_declared - garm:message_sessions_live >= 1";
          for = listenerShortfallFor;
          keepFiringFor = listenerShortfallKeepFiringFor;
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
      items = [
        {
          record = "garm:class_saturated";
          expr = if isPool then poolSaturatedExpr else scalesetSaturatedExpr;
        }
        {
          record = "garm:class_queued_jobs";
          expr = queuedJobsExpr;
        }
        {
          record = "garm:class_running_jobs";
          comment = [
            "# Jobs of the class that are actually running. A saturated class with"
            "# jobs queued is a capacity queue while its runners are working; it is a"
            "# FAULT when nothing of that class is running at all, because then every"
            "# slot is held by a runner that takes no job."
          ];
          expr = runningJobsExpr;
        }
        {
          record = "garm:class_starved";
          comment = [
            "# NO PROGRESS, NOT MERELY FULL. Measured 2026-11-02..16: 303 episodes in"
            "# 14 days (159 in W47), nearly all on the two classes with the smallest"
            "# ceilings — eph-linux-x64-terraform (6 + 2 + 1 slots, one warm runner per"
            "# org) and m3's eph-linux-arm64 (2 per owner). The terraform lane queued"
            "# behind its own running jobs every busy hour and drained minutes later:"
            "# 10-minute episodes, back to back. That is the queueing"
            "# docs/CI-Runner-Fleet-Status.md says is expected; nothing is broken."
            "#"
            "# `unless garm:class_running_jobs` keeps the fault and drops the queue:"
            "# it fires only while the class is at its ceiling, has jobs queued and"
            "# runs NONE of them; the alert below fires once that has held for 30 of"
            "# the last 60 minutes, and `keep_firing_for: 2h` makes a slot-holding"
            "# incident one episode instead of a sawtooth. Replayed over the same 14"
            "# days: 303 -> 29 per-class episodes (16 in W47; 4 in W47 counted per"
            "# alert and instance, as the report now does). Still caught: both terraform"
            "# classes during the 2026-11-12/13 ZFS incident (from 18:25Z, about"
            "# 6.5 hours, when incus creates stalled and the"
            "# scale sets held no working runner), and m3's eph-linux-arm64 from"
            "# 11-12 on, which is the downstream face of GarmListenerSessionShortfall"
            "# (2 of m3's 6 scale sets have no message session, so their jobs never"
            "# start)."
          ];
          expr = starvedExpr;
        }
        {
          name = "GarmFleetStarvation";
          comment = [
            "# Starved for 30 of the last 60 minutes, not for 45 unbroken ones: the"
            "# condition breaks whenever a job briefly starts, and m3's"
            "# eph-linux-arm64 — the class starved longest in W47 (95 hours) — has a"
            "# median unbroken stretch of 31 minutes, so a long `for:` would have"
            "# missed most of it."
          ];
          expr = "count_over_time(garm:class_starved[1h]) >= ${s starvationMinutesPerHour}";
          for = starvationFor;
          keepFiringFor = starvationKeepFiringFor;
          severity = "critical";
          summary = "Runner STARVATION: {{ $labels.garm_owner }}/{{ $labels.garm_class }} saturated, jobs queued, none running";
          description = "Class {{ $labels.garm_class }} (owner {{ $labels.garm_owner }}) has had jobs queued while at its runner ceiling and running NONE of them for {{ $value }} of the last 60 minutes — every slot is held by a runner that takes no work. Check GarmListenerSessionShortfall and GarmProviderHighErrorRatio for the controller that serves the class, then the runners themselves (booting, offline on GitHub, or wedged in teardown).";
        }
        # Capability POOLS (mode-independent: garm_pool_* exists whenever a
        # controller declares pools, whichever family carries the scale-set
        # classes).
        {
          record = "garm:pool_slots_allocated";
          comment = [
            ""
            "# ── THE HALF `GarmFleetStarvation` CANNOT SEE ──"
            "#"
            "# `garm:class_saturated` above is built ENTIRELY from `garm_scaleset_*`"
            "# series, and derives `garm_class` from a scale set's `name`."
            "# `garm:class_queued_jobs` derives `garm_class` from a job's"
            "# `requested_labels`. Those two agree only for SCALE-SET jobs, whose"
            "# `runs-on` *is* the set's name. A capability-POOL job asks for a label"
            "# array — `self-hosted linux x64` — and no `garm_scaleset_info` carries"
            "# that name, so `and on (garm_owner, garm_class)` matches nothing and the"
            "# alert is structurally blind to every pool-served class."
            "#"
            "# MEASURED 2026-10-17, which is why this exists: 275 jobs queued"
            "# fleet-wide (155 of them agent-harbor's, on `self-hosted linux x64` and"
            "# `self-hosted Linux x86-64-v3`), jobs waiting ~1h for a runner, and"
            "# `GarmFleetStarvation` NOT FIRING — `garm:class_saturated` had entries"
            "# for ten `eph-*` classes and none for any pool class."
            "#"
            "# WHY THIS IS PER-OWNER AND NOT PER-CLASS, stated plainly because the"
            "# obvious fix does not work: matching a pool to a job class needs SET"
            "# containment (GitHub schedules when the job's labels are a SUBSET of the"
            "# runner's tags), and the pool's `tags` is a comma-joined list in a"
            "# different order from the job's space-joined `requested_labels`. PromQL"
            "# has no subset operator, so a per-class pool join is not expressible"
            "# here. `pool_owner`/`owner` DO agree, so the join is done at owner"
            "# granularity and named for what it actually proves."
            "#"
            "# ALLOCATION COUNTS EVERY RECORD, NOT JUST LIVE ONES, and that is the"
            "# whole point. GARM charges an instance against its pool's `maxRunners`"
            "# until the record is GONE, so a pool full of `pending_delete` corpses is"
            "# full. On 2026-10-17 agent-harbor held exactly 22 records against 22"
            "# declared pool slots — 12 running, 6 `pending_delete`, 4 `deleting` —"
            "# i.e. 100% allocated with 45% of it dead. Counting only live runners"
            "# would have reported 10 free slots and explained nothing."
          ];
          expr = ''count by (pool_owner) (garm_runner_status{pool_id!=""})'';
        }
        {
          record = "garm:pool_slots_declared";
          expr = ''
            sum by (pool_owner) (
              garm_pool_max_runners * on (id) group_left(pool_owner) garm_pool_info
            )'';
        }
        {
          record = "garm:pool_slots_free";
          comment = [
            "#"
            "# The max over 3m is there because GARM sometimes exports NO"
            "# `garm_runner_status` series at all for one scrape (see"
            "# garm:live_runners below). Read raw, allocation dropped to nothing on"
            "# those scrapes, free jumped to `declared`, and the 15m `for` of"
            "# GarmCapabilityPoolStarvation started over. On 2026-10-31 that happened"
            "# in 101 scrapes, up to every other minute during busy hours."
          ];
          expr = ''
            garm:pool_slots_declared
              - (max_over_time(garm:pool_slots_allocated[3m]) or (garm:pool_slots_declared * 0))'';
        }
        {
          record = "garm:owner_queued_jobs";
          expr = "sum by (garm_owner) (garm:class_queued_jobs)";
        }
        {
          name = "GarmCapabilityPoolStarvation";
          expr = ''
            (garm:owner_queued_jobs > 0)
              and on (garm_owner)
            label_replace(garm:pool_slots_free <= 0, "garm_owner", "$1", "pool_owner", "(.*)")'';
          for = capabilityPoolStarvationFor;
          severity = "critical";
          summary = "Runner STARVATION (capability pools): {{ $labels.garm_owner }} has {{ $value }} job(s) queued and ZERO free pool slots";
          description = "{{ $value }} job(s) have been queued for ${capabilityPoolStarvationFor} for owner {{ $labels.garm_owner }} while every declared capability-pool slot it owns is allocated. This is the pool-side counterpart of GarmFleetStarvation, which only covers scale-set classes and cannot see this. Allocation counts instances in `pending_delete`/`deleting` too, because GARM charges those against maxRunners until the record disappears — so check GarmInstanceStuckDeleting FIRST: if corpses are holding the slots, the fix is teardown, not more capacity. Raising maxRunners on a host that cannot tear down makes it worse.";
        }
        {
          record = "garm:instance_deleting";
          comment = [
            ""
            "# ── Instances wedged in teardown ──"
            "#"
            "# The signal that was missing on 2026-10-17. Eleven instances sat in"
            "# `pending_delete` on high-mem-server for a MEDIAN OF 169 MINUTES (max"
            "# 174), each retried 46-48 times, all failing"
            "# `zfs destroy -r …: dataset is busy`. Nothing alerted: the orphan sweeper"
            "# cannot see them (it looks for containers with NO GARM record, and these"
            "# still have one), and the capacity alert above did not exist yet."
            "#"
            "# The threshold is deliberately well above a HEALTHY teardown."
            "# docs/CI-Runner-Fleet-Status.md records the H7 defect as retrying to"
            "# success at p50 7 / max 30 attempts, and drains of 10-25 minutes were"
            "# measured on 2026-10-10. 30m therefore does not fire on the normal"
            "# defect; it fires when teardown has stopped converging, which is the"
            "# state that silently eats pool capacity."
            "#"
            "# Until 2026-11-16 this was one alert per instance (`name`), on the"
            "# argument that clearing one needs its holder identified by name. The"
            "# name is still one query away (see the description); the paging unit"
            "# changed, for the reason below."
            "#"
            "# Read through max_over_time for the same reason as garm:pool_slots_free:"
            "# one scrape without `garm_runner_status` would otherwise restart the"
            "# count below."
            "#"
            "# ONE ALERT PER CONTROLLER, NOT PER INSTANCE (OBS-AREQ7, 2026-11-16)."
            "# Per instance this was 544 critical episodes in 14 days (359 in W47):"
            "# every wedged corpse was its own page. Measured from garm_runner_status"
            "# over 2026-11-02..16 on high-mem-server:9997, 546 instances sat in"
            "# teardown for 30m+, 287 for 1h+ and 89 for 3h+ — the H7 defect is"
            "# chronic, and since 2026-11-07 12:31Z at least five corpses older than"
            "# 30m have been present almost continuously. Paging per corpse cannot be"
            "# acted on; the fault the alert exists for is teardown eating the pool"
            "# ceiling (2026-10-17: eleven at once, median 169 minutes)."
            "#"
            "# So: count, per controller, the instances that have been in"
            "# pending_delete/deleting for 30m (at least 28 of the last 30 one-minute"
            "# samples of the record below, so a missed evaluation does not reset an"
            "# instance's age), and fire at five. keep_firing_for: 2h holds it across the"
            "# churn as old corpses clear and new ones age in. Replayed: 544 -> 17"
            "# episodes in 14 days, 3 starting in the week to 11-16; the 11-07 12:31Z"
            "# episode covers the whole 2026-11-12/13 ZFS incident. The names are in"
            "# the description query, so finding the holder is unchanged."
          ];
          expr = ''
            max by (instance, provider, pool_owner, name) (
              max_over_time(garm_runner_status{status=~"pending_delete|deleting"}[3m])
            )'';
        }
        {
          name = "GarmInstanceStuckDeleting";
          expr = stuckDeletingExpr;
          for = stuckDeletingFor;
          keepFiringFor = stuckDeletingKeepFiringFor;
          severity = "critical";
          summary = "GARM {{ $labels.instance }} has {{ $value }} instances in teardown for 30m+";
          description = "{{ $value }} instances on controller {{ $labels.instance }} have been in pending_delete/deleting for over 30m. A healthy teardown clears in 10-25m even with the H7 `dataset is busy` retry defect, so this is teardown that has stopped converging — and every one of them still occupies a slot against its pool maxRunners until the record is gone. List them with `count_over_time(garm:instance_deleting{instance=\\\"{{ $labels.instance }}\\\"}[30m]) >= 28` (labels name, provider, pool_owner), ${teardownHolderHint}, and check that host load: the H7 unmount race drains far slower under CPU starvation.";
        }
        {
          record = "garm:live_runners";
          comment = [
            ""
            "# ── Live runners below the idle floor ──"
            "#"
            "# A controller that cannot keep even its declared min-idle runners alive"
            "# has lost its capacity, whether or not jobs are queued yet. Neither"
            "# starvation alert covers that: both need queued demand, and a collapse"
            "# in a quiet hour leaves the next burst of jobs with nothing to run on."
            "#"
            "# GARM's metric collector clears `garm_runner_status` and then queries the"
            "# database to fill it again. A scrape in between gets a successful"
            "# response with NO runner series. On 2026-10-31 at 14:14:14Z such a"
            "# scrape made the fleet read as 2 running runners (m3's), against a"
            "# normal 39-50. The runners were there: 29 of the 42 running at 14:11"
            "# were still running at 14:16, and the hms controller reported 42 again"
            "# one scrape later. So the count is taken as the MAX over 5m, which"
            "# ignores an empty scrape and still drops to 0 when runners really go."
            "# The devops-modules GARM package patch \"publish metric snapshots\""
            "# removes the empty scrapes; the max_over_time stays as a guard."
            "#"
            "# `or ... 0 * up` turns a controller that is up but has no runners into"
            "# an explicit 0 rather than a missing series. A controller that is down"
            "# is GarmControllerDown's case."
          ];
          expr = ''
            count by (instance) (garm_runner_status{job="${garmJob}", status="running"})
              or sum by (instance) (0 * (up{job="${garmJob}"} == 1))'';
        }
        {
          record = "garm:min_idle_floor";
          expr = ''
            (
              sum by (instance) (
                garm_pool_min_idle_runners{job="${garmJob}"}
                  * on (instance, id) group_left () (garm_pool_status{job="${garmJob}"} == 1)
              )
                or sum by (instance) (0 * (up{job="${garmJob}"} == 1))
            )
            + (
              sum by (instance) (
                garm_scaleset_min_idle_runners{job="${garmJob}"}
                  * on (instance, id) group_left () (garm_scaleset_status{job="${garmJob}"} == 1)
              )
                or sum by (instance) (0 * (up{job="${garmJob}"} == 1))
            )'';
        }
        {
          name = "GarmLiveRunnerCollapse";
          expr = ''
            max_over_time(garm:live_runners[5m])
              < max_over_time(garm:min_idle_floor[5m])'';
          for = liveRunnerCollapseFor;
          severity = "critical";
          summary = "GARM {{ $labels.instance }} has fewer live runners than its min-idle floor";
          description = "GARM at {{ $labels.instance }} has had at most {{ $value }} runner(s) in state `running` for ${liveRunnerCollapseFor}+, fewer than the min-idle runners its enabled pools and scale sets declare. The controller is up, so runners are failing to be created or are dying. Check GarmProviderCreateFailures, the provider serve units (gosti-serve) and incus on the runner hosts, and the garm.service journal for `failed to create instance in provider`.";
        }
      ];
    }
  ]
  ++ optionals overProvision [
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
  ++ optionals watchdog [ watchdogGroup ]
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
