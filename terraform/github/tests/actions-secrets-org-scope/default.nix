{ ... }:
# Offline gate fixture for the standalone Actions-secrets engine (milestone G3).
#
# Feeds actions-secrets.nix a managed+payload doc containing one organization
# secret with visibility "all", one organization secret with visibility
# "selected" (carrying a repository id list), and one repository secret — plus
# the AWS/GitHub deployment-fact params — so `actions-secrets.tftest.hcl` can
# prove org-scoped secrets are emitted and the deployment facts are present.
#
# The encrypted values are throwaway placeholders; nothing here is a real secret.
import ../../actions-secrets.nix {
  githubOwner = "example-org";
  stateKey = "bootstrap/github/example-secrets.tfstate";
  awsAccountId = "000000000000";
  awsRegion = "us-east-1";
  githubAccessCheckRepository = "infra";
  managedDoc = {
    version = 1;
    providerIds = [
      "example-org/infra:REPO_SECRET"
      "example-org/ORG_SECRET_ALL"
      "example-org/ORG_SECRET_SELECTED"
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
      "example-org/ORG_SECRET_ALL" = {
        version = 1;
        providerId = "example-org/ORG_SECRET_ALL";
        providerResource = "github_actions_organization_secret";
        scope = "organization";
        owner = "example-org";
        name = "ORG_SECRET_ALL";
        visibility = "all";
        keyId = "2222222222222222222";
        valueEncrypted = "b3JnLWFsbC1lbmNyeXB0ZWQtcGxhY2Vob2xkZXI=";
      };
      "example-org/ORG_SECRET_SELECTED" = {
        version = 1;
        providerId = "example-org/ORG_SECRET_SELECTED";
        providerResource = "github_actions_organization_secret";
        scope = "organization";
        owner = "example-org";
        name = "ORG_SECRET_SELECTED";
        visibility = "selected";
        selectedRepositoryIds = [
          123456
          654321
        ];
        keyId = "3333333333333333333";
        valueEncrypted = "b3JnLXNlbGVjdGVkLWVuY3J5cHRlZC1wbGFjZWhvbGRlcg==";
      };
    };
  };
}
