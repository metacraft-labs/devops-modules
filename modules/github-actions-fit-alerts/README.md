# github-actions-fit-alerts

A general, parametric Prometheus **alert-rule library** answering "does this
workflow fit `ubuntu-latest`?" for a fleet running a hybrid free/self-hosted CI
model. Company-agnostic: the runner-type / visibility scope and every threshold
are options.

Delivered for milestone **RD4** of
`Runner-Fleet-Capability-Pools-And-Remote-Driving`. Gate:
`.#checks.<system>.t_runner_fit_monitoring`.

## What it covers

Over metrics from the companion `github-actions-fit-exporter`:

| Alert                                         | Signal                                                                     | Severity |
| --------------------------------------------- | -------------------------------------------------------------------------- | -------- |
| `GithubActionsUbuntuLatestDurationRegression` | hosted public job duration > `regressionFactor`× its trailing baseline     | warning  |
| `GithubActionsUbuntuLatestResourceLimit`      | hosted public job hit `oom` / `no_space` / `timeout` (from a job-log scan) | critical |

Plus one recording rule (`github_actions_fit:duration_baseline_seconds`) that is
the offset trailing average the regression compares against.

Both alerts scope to `runner_type` × `visibility` (defaults `github-hosted` ×
`public`): the operator's question is specifically about the public repos moved
to free hosted runners.

## The `ubuntu-latest` baseline

`ubuntu-latest` = Ubuntu 24.04. Standard Linux runner (GitHub docs, verified
2026-09-09): **public** repos 4 vCPU / 16 GB RAM / 14 GB SSD; **private** repos
2 vCPU / 8 GB RAM / 14 GB SSD. The resource-limit signatures map to those
ceilings: `oom` → 16 GB RAM, `no_space` → the 14 GB SSD, `timeout` → the job
wall-clock. Record the concrete spec in the instantiating `infra` (rule header +
dashboard) so a future GitHub change is a visible diff.

## Usage

```nix
services.github-actions-fit-alerts = {
  enable = true;
  runnerType = "github-hosted";
  visibility = "public";
  baselineWindow = "30m";
  baselineOffset = "30m";     # so the baseline excludes the regression
  regressionFactor = "1.5";
  minDurationSeconds = 120;   # a fast job doubling is noise, not a regression
  durationRegressionFor = "10m";
  resourceLimitFor = "10m";
};
```

It renders the pure `./rules.nix` into `services.prometheus.ruleFiles`, so the
file that ships is the file `promtool test rules` replays
(`./tests/fit-monitoring.test.yml`), asserted in **both** directions.

## Layering

This is the general library + the general exporter (`github-actions-fit-exporter`
in this repo). The concrete scrape/textfile wiring, the pinned baseline, the
watched repos, the token, and the dashboard belong in that operator's private
`infra` — Metacraft's live in `infra/services/monitoring/` (`rules/mcl-runner-fit.yml`,
its `rule-tests`, `github-actions-fit.nix`, `dashboards/runner-fit.json`).
