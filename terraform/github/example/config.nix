# Example Terranix root exercising the branch-protection ruleset library.
#
# Render and validate offline:
#   terranix --quiet example/config.nix > config.tf.json
#   tofu init -backend=false && tofu validate
#
# A real consumer passes the policy from the shared data file instead of the
# fixture, e.g.
#   policy = builtins.fromJSON (builtins.readFile
#     "${inputs.dev-guidelines}/policies/branch-protection-policy.json");
let
  pkgs = import <nixpkgs> { };
  inherit (pkgs) lib;
  branchProtection = import ../branch-protection.nix { inherit lib; };

  policy = builtins.fromJSON (builtins.readFile ./policy.fixture.json);

  rulesets = branchProtection.mkRulesets {
    inherit policy;
    repositories = {
      # A product repo: dev/stable gate on CI, agents does not.
      "my-product" = {
        repoClass = "product";
        checks = {
          dev = [
            "ci / build"
            "ci / test"
          ];
          stable = [
            "release"
            "package"
          ];
        };
      };
      # A spec repo: latest gates on the docs checks.
      "my-specs" = {
        repoClass = "spec";
        checks.latest = [
          "markdown lint"
          "link check"
        ];
      };
      # An infra repo: live gates on plan + lint.
      "my-infra" = {
        repoClass = "infra";
        checks.live = [
          "terraform / plan"
          "lint"
        ];
      };
    };
  };
in
{
  terraform.required_providers.github = {
    source = "integrations/github";
    version = ">= 6.0";
  };
  provider.github.owner = "example-org";
}
// rulesets
