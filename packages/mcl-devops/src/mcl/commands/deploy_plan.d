module mcl.commands.deploy_plan;

import std.algorithm : map;
import std.array : array;
import std.conv : to;
import std.exception : enforce;
import std.file : exists, readText, write;
import std.json : JSONOptions, JSONValue;
import std.process : environment;
import std.stdio : writeln;
import std.string : strip;
import std.typecons : Nullable;

import argparse : Command, Description, EnvFallback, NamedArgument, Placeholder;

import mcl.utils.deploy_manifest : ManifestBuildRequest, ManifestHealthCheck,
    ManifestSigningRequest, ManifestSubstituter, buildManifest, parseHealthCommand,
    signManifest;
import mcl.utils.deploy_state : recordDesiredManifest, supersededStateForLatest;
import mcl.utils.deployment_events : ClosureSummary, deploymentIdFor,
    queryClosureSummary;
import mcl.utils.process : ProcessRunner, runProcessCapture;

version (unittest)
{
    import mcl.utils.deploy_state : uniqueDeployStateTestPath;
}

@(Command("deploy-plan")
    .Description("Create a signed desired-state deployment manifest"))
struct DeployPlanArgs
{
    @(NamedArgument(["target"])
        .Placeholder("name")
        .Description("Deployment target name"))
    string target;

    @(NamedArgument(["system"])
        .Placeholder("system")
        .Description("Nix system for the target"))
    string system = "x86_64-linux";

    @(NamedArgument(["desired-system-path"])
        .Placeholder("/nix/store/...")
        .Description("NixOS system toplevel path to deploy"))
    string desiredSystemPath;

    @(NamedArgument(["git-revision"])
        .Placeholder("REV")
        .Description("40-character git revision that produced the system path")
        .EnvFallback("GITHUB_SHA"))
    string gitRevision;

    @(NamedArgument(["sequence"])
        .Placeholder("N")
        .Description("Monotonic target-local deployment sequence"))
    ulong sequence;

    @(NamedArgument(["signing-key"])
        .Placeholder("PATH")
        .Description("OpenSSH private key used to sign the manifest")
        .EnvFallback("MCL_DEPLOY_MANIFEST_SIGNING_KEY"))
    string signingKey;

    @(NamedArgument(["signing-key-id"])
        .Placeholder("ID")
        .Description("Principal/key id written into the manifest signature")
        .EnvFallback("MCL_DEPLOY_MANIFEST_KEY_ID"))
    string signingKeyId;

    @(NamedArgument(["output", "o"])
        .Placeholder("manifest.json")
        .Description("Write signed manifest to this path; stdout when omitted"))
    string output;

    @(NamedArgument(["state-dir"])
        .Placeholder("DIR")
        .Description("Record the desired manifest in a durable state directory"))
    string stateDir;

    @(NamedArgument(["cache"])
        .Placeholder("NAME")
        .Description("Cache name for event metadata and operator context"))
    string cache;

    @(NamedArgument(["substituter"])
        .Placeholder("URL")
        .Description("Substituter URL the target may use to restore the closure"))
    string[] substituters;

    @(NamedArgument(["trusted-public-key"])
        .Placeholder("KEY")
        .Description("Trusted public key for the matching substituter"))
    string[] trustedPublicKeys;

    @(NamedArgument(["availability-mode"])
        .Placeholder("MODE")
        .Description("Cache availability policy: all-roots-substitutable, closure-substitutable, best-effort, none"))
    string availabilityMode = "none";

    @(NamedArgument(["require-availability"])
        .Description("Require cache availability before activation"))
    bool requiredBeforeActivation;

    @(NamedArgument(["health-command"])
        .Placeholder("NAME|TIMEOUT_SECONDS|COMMAND")
        .Description("Post-switch command health check; repeatable"))
    string[] healthCommands;

    @(NamedArgument(["rollback-mode"])
        .Placeholder("automatic|manual|disabled")
        .Description("Rollback policy mode"))
    string rollbackMode = "manual";

    @(NamedArgument(["rollback-max-attempts"])
        .Placeholder("N")
        .Description("Maximum automatic rollback attempts"))
    ulong rollbackMaxAttempts = 0;

    @(NamedArgument(["on-health-check-failure"])
        .Placeholder("rollback|mark-failed|manual-intervention")
        .Description("Action when a health check fails"))
    string onHealthCheckFailure = "mark-failed";
}

export int deploy_plan(DeployPlanArgs args)
{
    return deployPlanImpl(args, (string[] command) => runProcessCapture(command));
}

int deployPlanImpl(DeployPlanArgs args, ProcessRunner runProcess)
{
    enforce(args.target != "", "--target is required.");
    enforce(args.desiredSystemPath != "", "--desired-system-path is required.");
    enforce(args.sequence > 0, "--sequence must be greater than zero.");
    enforce(args.signingKey != "", "--signing-key is required.");

    auto gitRevision = args.gitRevision;
    if (gitRevision == "")
    {
        auto git = runProcess(["git", "rev-parse", "--verify", "HEAD"]);
        enforce(git.succeeded, "--git-revision is required outside a git worktree.");
        gitRevision = git.stdout.strip;
    }
    enforce(gitRevision.length == 40, "--git-revision must be a 40-character commit SHA.");

    Nullable!JSONValue supersededState;
    if (args.stateDir != "")
        supersededState = supersededStateForLatest(args.stateDir, args.target, args.sequence);

    enforce(args.trustedPublicKeys.length == args.substituters.length,
            "Each --substituter requires one matching --trusted-public-key.");
    ManifestSubstituter[] substituters;
    foreach (index, url; args.substituters)
    {
        auto key = args.trustedPublicKeys[index].strip;
        enforce(key.length, "--trusted-public-key cannot be empty.");
        substituters ~= ManifestSubstituter(url: url, trustedPublicKey: key);
    }

    ManifestHealthCheck[] healthChecks = args.healthCommands
        .map!(spec => parseHealthCommand(spec))
        .array;

    auto closure = queryClosureSummary(args.desiredSystemPath, runProcess);
    auto manifest = buildManifest(ManifestBuildRequest(
        deploymentId: deploymentIdFor(args.target, args.desiredSystemPath),
        target: args.target,
        system: args.system,
        gitRevision: gitRevision,
        sequence: args.sequence,
        desiredSystemPath: args.desiredSystemPath,
        closure: closure,
        substituters: substituters,
        availabilityMode: args.availabilityMode,
        requiredBeforeActivation: args.requiredBeforeActivation,
        healthChecks: healthChecks,
        rollbackMode: args.rollbackMode,
        rollbackMaxAttempts: args.rollbackMaxAttempts,
        onHealthCheckFailure: args.onHealthCheckFailure,
        supersededState: supersededState.isNull ? JSONValue(null) : supersededState.get,
    ));

    auto signed = signManifest(manifest, ManifestSigningRequest(
        keyPath: args.signingKey,
        keyId: args.signingKeyId,
    ), runProcess);

    if (args.output == "")
        writeln(signed.toString(JSONOptions.doNotEscapeSlashes));
    else
        args.output.write(signed.toString(JSONOptions.doNotEscapeSlashes));

    if (args.stateDir != "")
        recordDesiredManifest(args.stateDir, signed);

    return 0;
}

@("test_deploy_plan_creates_verifiable_signed_manifest")
unittest
{
    import std.file : remove, rmdirRecurse;
    import std.json : parseJSON;
    import mcl.utils.deploy_manifest : verifyManifestSignature;
    import mcl.utils.process : runProcessCapture;

    auto base = uniqueDeployStateTestPath("deploy-plan-sign");
    auto keyPath = base ~ ".ed25519";
    auto manifestPath = base ~ ".manifest.json";
    auto stateDir = base ~ ".state";
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub", manifestPath])
            if (path.exists) path.remove;
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto keygen = runProcessCapture([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath,
    ]);
    assert(keygen.succeeded, keygen.stderr);

    DeployPlanArgs args;
    args.target = "app-1";
    args.desiredSystemPath = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system";
    args.gitRevision = "0123456789abcdef0123456789abcdef01234567";
    args.sequence = 1;
    args.signingKey = keyPath;
    args.signingKeyId = "deploy-test";
    args.output = manifestPath;
    args.stateDir = stateDir;

    const hadGitHubRunId = "GITHUB_RUN_ID" in environment;
    const oldGitHubRunId = environment.get("GITHUB_RUN_ID", "");
    const hadGitHubSha = "GITHUB_SHA" in environment;
    const oldGitHubSha = environment.get("GITHUB_SHA", "");
    scope(exit)
    {
        if (hadGitHubRunId)
            environment["GITHUB_RUN_ID"] = oldGitHubRunId;
        else
            environment.remove("GITHUB_RUN_ID");

        if (hadGitHubSha)
            environment["GITHUB_SHA"] = oldGitHubSha;
        else
            environment.remove("GITHUB_SHA");
    }
    environment.remove("GITHUB_RUN_ID");
    environment.remove("GITHUB_SHA");

    assert(deployPlanImpl(args, (string[] command) => runProcessCapture(command)) == 0);
    auto manifest = manifestPath.readText.parseJSON;
    assert(manifest["deploymentId"].str == "gh-local-unknown-app-1");
    assert(manifest["manifestSignature"]["keyId"].str == "deploy-test");
    assert(manifest.verifyManifestSignature((keyPath ~ ".pub").readText.strip, ""));
}
