# github-actions-fit — Prometheus alert-rule LIBRARY (general, parametric,
# company-agnostic). Runner-Fleet-Capability-Pools-And-Remote-Driving RD4.
#
# A PURE function: given thresholds it returns the YAML text of a Prometheus rule
# file. Both the NixOS module (./default.nix) and the promtool gate
# (../../checks/fit-monitoring.nix) render from THIS one source, so the exact
# text that ships is the exact text `promtool test rules` replays — the lesson
# the deployment-events rules learned the hard way (see the note atop
# infra/services/monitoring/prometheus.nix).
#
# It fires when a workflow does NOT fit the free GitHub-hosted `ubuntu-latest`
# runner it was moved onto, over metrics from the companion
# github-actions-fit-exporter:
#
#   github_actions_job_duration_seconds{repo,workflow,job,runner_type,visibility}
#   github_actions_job_resource_limit{...,signature=oom|no_space|timeout}
#
# TWO alerts:
#
#   * DURATION REGRESSION — a public-repo, github-hosted job whose duration
#     exceeds `regressionFactor` × its own trailing baseline (a recording rule:
#     avg over `baselineWindow`, offset `baselineOffset` so the baseline excludes
#     the regression itself), AND is above `minDurationSeconds` (so a 2s→5s job
#     never pages). This is "it got slower after the move to ubuntu-latest".
#
#   * RESOURCE LIMIT — a public-repo, github-hosted job hit an OOM / no-space /
#     timeout signature. That is a hard fit failure (the ~14 GB SSD, the 16 GB
#     RAM public-runner ceiling, or the job timeout), so it is the louder page.
#
# Both scope to `runner_type` × `visibility` (defaults github-hosted × public):
# the operator's question is specifically about the PUBLIC repos moved to free
# hosted runners. Widen via the options for private-repo hosted minutes.
{
  lib,
  # Scope: the runner class + repo visibility the fit question is about.
  runnerType ? "github-hosted",
  visibility ? "public",
  # Duration-regression baseline + trip.
  baselineWindow ? "30m",
  baselineOffset ? "30m",
  regressionFactor ? "1.5",
  minDurationSeconds ? 120,
  durationRegressionFor ? "10m",
  # Resource-limit trip.
  resourceLimitFor ? "10m",
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

  s = toString;
  scope = ''runner_type="${runnerType}", visibility="${visibility}"'';

  indentBlock =
    n: str:
    let
      pad = concatStrings (genList (_: " ") n);
    in
    concatStringsSep "\n" (map (l: if l == "" then "" else pad + l) (splitString "\n" str));

  # Renderers (data -> YAML) — indentation correct BY CONSTRUCTION.
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
        "          component: runner-fit"
        "        annotations:"
        "          summary: \"${a.summary}\""
        "          description: \"${a.description}\""
      ]
    );

  mkRecord =
    r:
    concatStringsSep "\n" [
      "      - record: ${r.record}"
      "        expr: |"
      (indentBlock 10 r.expr)
    ];

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

  baselineExpr = ''
    avg_over_time(
      github_actions_job_duration_seconds{${scope}}[${baselineWindow}] offset ${baselineOffset}
    )'';

  # metric > factor*baseline  AND  metric > floor. Both sides carry the same
  # {repo,workflow,job,runner_type,visibility} label set, so the vector matches
  # are one-to-one and no on()/ignoring() is needed.
  regressionExpr = ''
    github_actions_job_duration_seconds{${scope}}
      > ${regressionFactor} * github_actions_fit:duration_baseline_seconds
      and
    github_actions_job_duration_seconds{${scope}}
      > ${s minDurationSeconds}'';

  resourceExpr = "github_actions_job_resource_limit{${scope}} == 1";

  groups = [
    {
      name = "runner-fit-duration";
      comment = [
        "# ── ubuntu-latest DURATION regression ──"
        "# Baseline is a recording rule (avg over the window, OFFSET back so it"
        "# excludes the regression) so the alert stays legible and promtool can"
        "# assert the whole chain from raw duration series."
      ];
      records = [
        {
          record = "github_actions_fit:duration_baseline_seconds";
          expr = baselineExpr;
        }
      ];
      rules = [
        {
          name = "GithubActionsUbuntuLatestDurationRegression";
          expr = regressionExpr;
          for = durationRegressionFor;
          severity = "warning";
          summary = "Workflow slower on ubuntu-latest: {{ $labels.repo }} {{ $labels.workflow }}/{{ $labels.job }}";
          description = "Job {{ $labels.job }} of workflow {{ $labels.workflow }} ({{ $labels.repo }}) is taking {{ $value | humanizeDuration }} on the ${runnerType} runner — over ${regressionFactor}x its recent baseline — for ${durationRegressionFor}. The workflow may not fit ${visibility} ubuntu-latest (4 vCPU / 16 GB / 14 GB SSD); compare hosted vs self-hosted on the runner-fit dashboard and consider keeping it on self-hosted.";
        }
      ];
    }
    {
      name = "runner-fit-resource";
      comment = [
        "# ── ubuntu-latest RESOURCE-LIMIT failure ──"
        "# Emitted only when the exporter's log scan matched a signature on the"
        "# most recent non-success run; it is 1-or-absent, so `== 1` is exact and"
        "# an absent series is (correctly) silent."
      ];
      rules = [
        {
          name = "GithubActionsUbuntuLatestResourceLimit";
          expr = resourceExpr;
          for = resourceLimitFor;
          severity = "critical";
          summary = "Workflow hit a {{ $labels.signature }} limit on ubuntu-latest: {{ $labels.repo }} {{ $labels.workflow }}/{{ $labels.job }}";
          description = "Job {{ $labels.job }} of workflow {{ $labels.workflow }} ({{ $labels.repo }}) hit a resource limit ({{ $labels.signature }}: oom = out of RAM, no_space = the ~14 GB SSD full, timeout = job wall-clock) on the ${runnerType} runner. It does NOT fit ${visibility} ubuntu-latest — move it back to a self-hosted capability label set or shrink its footprint.";
        }
      ];
    }
  ];
in
''
  # GENERATED by nixos-modules/modules/github-actions-fit-alerts/rules.nix — do not
  # edit the deployed copy; change the library and re-render. scope=${runnerType}/${visibility}.
  groups:
  ${concatMapStringsSep "\n" mkGroup groups}
''
