# Runner capability-label DERIVATION + linter — the GENERAL, company-agnostic
# MECHANISM (Runner-Fleet-Capability-Pools-And-Remote-Driving RC1).
#
# Per the campaign :repo_layering:, the label VOCABULARY and `runs-on`
# CONVENTIONS are POLICY (metacraft-dev-guidelines/policies/ci-workflow-standards.md);
# this module is the parametric mechanism with NO baked-in Metacraft host/secret/org.
# It exposes:
#
#   * `packages.runner-label-tool` — the `derive` (manifest → labels) + `lint`
#     (advertised ⊆ derived) CLI, a thin wrapper over ./derive.py. Runtime
#     consumers: the central GARM controller (RB2/RC2) derives a classic
#     runner's JIT label array from a *verified* /v1/manifest; infra CI lints
#     every host's advertised set. Build/eval-testable WITHOUT the infra repo
#     (checks/runner-label-taxonomy.nix → gate `t_runner_label_taxonomy`).
#
# The derivation reads the RA6 signed capability manifest schema documented in
# vm-harness/docs/serve-enrollment.md. The tool does the field→label mapping
# only — the caller verifies the manifest signature first (RA6 contract:
# "an unverifiable manifest yields no labels").
{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.runner-label-tool = pkgs.writeShellApplication {
        name = "runner-label-tool";
        runtimeInputs = [ pkgs.python3 ];
        text = ''
          exec python3 ${./derive.py} "$@"
        '';
      };
    };
}
