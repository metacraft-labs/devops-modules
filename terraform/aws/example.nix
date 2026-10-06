# Example caller for tf-bootstrap.nix. A real consumer's
# bootstrap/aws/<name>/default.nix imports the module and passes its own values;
# each consumer supplies independent identifiers. Two consumers may point at the
# same AWS account today, but the variables are per-repo so either can move to a
# separate account later.
import ./tf-bootstrap.nix {
  awsAccountId = "000000000000";
  awsRegion = "us-east-1";
  budgetAlertEmails = [ "ops@example.com" ];
  githubBranch = "live";
  githubEnvironment = "production";
  githubOwner = "example-org";
  githubRepo = "infra";
  lockTableName = "example-prod-tofu-locks";
  namePrefix = "example-prod";
  orgLabel = "Example";
}
