# Parametric helpers for governance secret manifests, shared across the infra
# repos (metacraft / agent-harbor / blocksense). Each repo's manifest.nix keeps
# only the repo-specific data (owner, repo); the boilerplate lives here.
#
#   let h = import "${inputs.nixos-modules}/terraform/github/manifest-lib.nix" { };
#   in { secrets = [ (h.mkAgenixCiSecret { owner = "metacraft-labs"; repo = "infra"; }) … ]; }
{ }:
rec {
  # A repository-scoped github_actions_secret manifest entry. `ageFile` defaults
  # to the conventional secrets/actions/repos/<repo>/<name>.age path.
  mkRepoActionsSecret =
    {
      owner,
      repo,
      name,
      ageFile ? "secrets/actions/repos/${repo}/${name}.age",
      rotationGroup ? null,
    }:
    {
      providerResource = "github_actions_secret";
      scope = "repository";
      repository = repo;
      inherit name;
      providerId = "${owner}/${repo}:${name}";
      inherit ageFile;
      manageWithTerraform = true;
    }
    // (if rotationGroup != null then { inherit rotationGroup; } else { });

  # The repo-specific agenix CI key (PRIVATE half) that reusable-terraform-ci
  # decrypts agenix-token secrets (e.g. Cloudflare API tokens) with. Public half
  # is a recipient in the token rules. Governance-managed, not `gh secret set`.
  mkAgenixCiSecret =
    { owner, repo }:
    mkRepoActionsSecret {
      inherit owner repo;
      name = "AGENIX_CI_PRIVATE_KEY";
    };
}
