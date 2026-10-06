{ ... }:
# Backward-compatible (repo-only) gate fixture for the standalone Actions-secrets
# engine (milestone G3). This is the exact shape the two real production callers
# use: only githubOwner + stateKey, NO AWS/GitHub deployment-fact params.
#
# It reproduces the regression the review found: when the fact params are null,
# their deployment-fact outputs must NOT be emitted at all. terranix strips
# `value = null`, so an unconditional output would render a `description` with no
# `value` key — a config OpenTofu rejects at plan time. The gate asserts the
# rendered config carries none of the fact outputs and still plans cleanly.
#
# The encrypted value is a throwaway placeholder; nothing here is a real secret.
import ../../../actions-secrets.nix {
  githubOwner = "example-org";
  stateKey = "bootstrap/github/example-secrets.tfstate";
  managedDoc = {
    version = 1;
    providerIds = [
      "example-org/infra:REPO_SECRET"
    ];
  };
  payloadDoc = {
    version = 1;
    payloads = {
      "example-org/infra:REPO_SECRET" = {
        version = 1;
        providerId = "example-org/infra:REPO_SECRET";
        providerResource = "github_actions_secret";
        scope = "repository";
        owner = "example-org";
        name = "REPO_SECRET";
        repository = "infra";
        keyId = "1111111111111111111";
        valueEncrypted = "cmVwby1lbmNyeXB0ZWQtcGxhY2Vob2xkZXI=";
      };
    };
  };
}
