# Example caller for tf-bootstrap.nix (the CI-enabling GitHub Layer-0 root). A
# real consumer's bootstrap/github/<name>/default.nix imports the module and
# passes its own identifiers; each consumer supplies independent values. No
# company literals here.
import ./tf-bootstrap.nix {
  awsAccountId = "000000000000";
  awsRegion = "us-east-1";
  namePrefix = "example-prod";
  githubOwner = "example-org";
  githubRepo = "infra";
  protectedBranch = "live";
  reviewerTeam = {
    name = "infra";
    slug = "infra";
    description = "Maintainers for Example infrastructure.";
    initialMaintainer = "example-admin";
  };
  requiredStatusCheckContexts = [
    "pr (terraform/aws/example-prod) / offline-checks"
    "pr (terraform/aws/example-prod) / credentialed-plan"
  ];
}
