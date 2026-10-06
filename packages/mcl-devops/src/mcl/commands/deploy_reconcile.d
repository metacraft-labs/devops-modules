module mcl.commands.deploy_reconcile;

import std.algorithm : canFind, filter, map;
import std.array : array, split;
import std.conv : to;
import std.exception : enforce;
import std.file : readText;
import std.json : JSONValue, parseJSON;
import std.string : strip;

import argparse : Command, Description, EnvFallback, NamedArgument, Placeholder;

import mcl.utils.deploy_manifest : manifestDeploymentId, manifestDesiredSystemPath,
    manifestTarget;
import mcl.utils.deploy_state : loadLatestManifests, markDeploymentState,
    recordDesiredManifest;
import mcl.utils.deployment_events : DeploymentEventContext, appendDeploymentEvent,
    deploymentEventJson, deploymentEventLogPathFromEnv, queryClosureSummary,
    stderrSummary;
import mcl.utils.process : ProcessInputRunner, ProcessResult, ProcessRunner,
    runProcessCapture, runProcessWithInputCapture;

version (unittest)
{
    import mcl.utils.deploy_state : uniqueDeployStateTestPath;
}

@(Command("deploy-reconcile")
    .Description("Converge signed desired-state deployments with latest-only semantics"))
struct DeployReconcileArgs
{
    @(NamedArgument(["state-dir"])
        .Placeholder("DIR")
        .Description("Durable deployment state directory"))
    string stateDir = ".result/mcl-deploy-state";

    @(NamedArgument(["manifest"])
        .Placeholder("manifest.json")
        .Description("Record this signed manifest before reconciling"))
    string[] manifests;

    @(NamedArgument(["target"])
        .Placeholder("name")
        .Description("Limit reconciliation to a target; repeatable"))
    string[] targets;

    @(NamedArgument(["ssh-host"])
        .Placeholder("HOST")
        .Description("SSH host for a single selected target"))
    string sshHost;

    @(NamedArgument(["target-host"])
        .Placeholder("TARGET=HOST")
        .Description("Map target name to SSH host; repeatable"))
    string[] targetHosts;

    @(NamedArgument(["ssh-user"])
        .Placeholder("USER")
        .Description("SSH user for target connections"))
    string sshUser = "deploy";

    @(NamedArgument(["identity-file"])
        .Placeholder("PATH")
        .Description("SSH identity file"))
    string identityFile;

    @(NamedArgument(["port"])
        .Placeholder("PORT")
        .Description("SSH port"))
    ushort port = 22;

    @(NamedArgument(["ssh-option"])
        .Placeholder("OPTION")
        .Description("Extra ssh -o option; repeatable"))
    string[] sshOptions;

    @(NamedArgument(["remote-command"])
        .Placeholder("COMMAND")
        .Description("Remote command for non-forced-command tests; omitted for hardened forced-command keys"))
    string remoteCommand;

    @(NamedArgument(["event-log"])
        .Placeholder("events.jsonl")
        .Description("Write deployment events as JSONL")
        .EnvFallback("MCL_DEPLOY_EVENT_LOG"))
    string eventLog;

    @(NamedArgument(["dry-run"])
        .Description("Record desired state and emit pending events without SSH"))
    bool dryRun;
}

struct DeployReconcileDependencies
{
    ProcessRunner queryProcess;
    ProcessInputRunner runProcessWithInput;
}

export int deploy_reconcile(DeployReconcileArgs args)
{
    return deployReconcileImpl(args, DeployReconcileDependencies(
        queryProcess: (string[] command) => runProcessCapture(command),
        runProcessWithInput: (string[] command, string input) => runProcessWithInputCapture(command, input, true),
    ));
}

string[string] parseTargetHosts(string[] specs)
{
    string[string] result;
    foreach (spec; specs)
    {
        auto parts = spec.split("=");
        if (parts.length != 2 || parts[0] == "" || parts[1] == "")
            throw new Exception("--target-host must use TARGET=HOST.");
        result[parts[0]] = parts[1];
    }
    return result;
}

string hostFor(JSONValue manifest, DeployReconcileArgs args, string[string] targetHosts)
{
    auto target = manifestTarget(manifest);
    if (auto mapped = target in targetHosts)
        return *mapped;
    if (args.sshHost != "")
        return args.sshHost;
    return target;
}

string[] sshCommand(JSONValue manifest, DeployReconcileArgs args, string host)
{
    string[] command = ["ssh"];
    if (args.identityFile != "")
        command ~= ["-i", args.identityFile];
    if (args.port != 22)
        command ~= ["-p", args.port.to!string];
    foreach (option; args.sshOptions)
        command ~= ["-o", option];
    command ~= [args.sshUser ~ "@" ~ host];
    if (args.remoteCommand != "")
        command ~= [args.remoteCommand];
    return command;
}

int deployReconcileImpl(DeployReconcileArgs args, DeployReconcileDependencies deps)
{
    import std.json : JSONOptions;

    foreach (manifestPath; args.manifests)
        recordDesiredManifest(args.stateDir, manifestPath.readText.parseJSON);

    auto manifests = loadLatestManifests(args.stateDir, args.targets);
    auto targetHosts = parseTargetHosts(args.targetHosts);
    auto eventLogPath = args.eventLog != "" ? args.eventLog : deploymentEventLogPathFromEnv();
    ProcessResult defaultQueryRunner(string[] command) { return runProcessCapture(command); }
    ProcessResult defaultInputRunner(string[] command, string input)
    {
        return runProcessWithInputCapture(command, input);
    }
    auto queryRunner = deps.queryProcess is null ? &defaultQueryRunner : deps.queryProcess;
    auto inputRunner = deps.runProcessWithInput is null
        ? &defaultInputRunner
        : deps.runProcessWithInput;

    foreach (manifest; manifests)
    {
        auto context = DeploymentEventContext(
            eventLogPath: eventLogPath,
            deploymentId: manifestDeploymentId(manifest),
            correlationId: "",
            cache: "",
            substituters: [],
            system: manifest["target"]["system"].str,
            kind: "server",
            transport: "ssh",
            controller: "mcl-reconciler",
        );
        auto host = hostFor(manifest, args, targetHosts);
        auto command = sshCommand(manifest, args, host);
        auto closure = queryClosureSummary(manifestDesiredSystemPath(manifest), queryRunner);

        if (args.dryRun)
        {
            markDeploymentState(args.stateDir, manifest, "accepted", "Dry-run reconciliation left target pending.");
            appendDeploymentEvent(eventLogPath, deploymentEventJson(
                context,
                "activate-requested",
                manifestTarget(manifest),
                manifestDesiredSystemPath(manifest),
                "mcl-devops deploy-reconcile --dry-run",
                command,
                "pending",
                0,
                closure,
                "",
                "command_failed",
                "",
                [
                    "sshHost": JSONValue(host),
                    "dryRun": JSONValue(true),
                ],
            ));
            continue;
        }

        auto result = inputRunner(command, manifest.toString(JSONOptions.doNotEscapeSlashes));
        appendDeploymentEvent(eventLogPath, deploymentEventJson(
            context,
            "activate-requested",
            manifestTarget(manifest),
            manifestDesiredSystemPath(manifest),
            "mcl-devops deploy-reconcile ssh",
            command,
            result.succeeded ? "succeeded" : "failed",
            result.exitCode,
            closure,
            result.succeeded ? "" : "SSH reconciliation failed",
            "ssh_reconcile_failed",
            result.succeeded ? "" : result.stderr.stderrSummary,
            [
                "sshHost": JSONValue(host),
            ],
        ));

        markDeploymentState(args.stateDir, manifest,
            result.succeeded ? "succeeded" : "failed",
            result.succeeded ? "Target accepted manifest." : "SSH reconciliation failed.");
        if (!result.succeeded)
            return 1;
    }

    return 0;
}

@("test_deploy_reconcile_sends_only_latest_manifest")
unittest
{
    import std.file : rmdirRecurse;
    import mcl.utils.deploy_manifest : ManifestBuildRequest, buildManifest;

    auto stateDir = uniqueDeployStateTestPath("deploy-reconcile");
    scope(exit)
    {
        import std.file : exists;
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto oldManifest = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-41",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 41,
        desiredSystemPath: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system-41",
    ));
    auto newManifest = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-42",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234568",
        sequence: 42,
        desiredSystemPath: "/nix/store/1123456789abcdfghijklmnpqrsvwxyz-system-42",
    ));
    recordDesiredManifest(stateDir, oldManifest);
    recordDesiredManifest(stateDir, newManifest);

    string sent;
    ProcessResult fakeSsh(string[] command, string input)
    {
        sent = input;
        return ProcessResult(0, "", "");
    }

    DeployReconcileArgs args;
    args.stateDir = stateDir;
    args.targets = ["app-1"];
    args.sshHost = "127.0.0.1";
    args.remoteCommand = "mcl-devops deploy-apply --manifest -";

    assert(deployReconcileImpl(args, DeployReconcileDependencies(
        queryProcess: (string[] command) => ProcessResult(0, "{}", ""),
        runProcessWithInput: &fakeSsh,
    )) == 0);
    assert(sent.parseJSON["deploymentId"].str == "deploy-42");
}
