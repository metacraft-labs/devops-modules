module mcl.commands.deploy_ssh;

import argparse : Command, Description, NamedArgument, Placeholder, PositionalArgument;

import mcl.commands.deploy_reconcile : DeployReconcileArgs,
    DeployReconcileDependencies, deployReconcileImpl;

@(Command("deploy-ssh")
    .Description("Direct one-target SSH deployment backed by deploy-reconcile"))
struct DeploySshArgs
{
    @(PositionalArgument(0)
        .Placeholder("MACHINE")
        .Description("Target machine name"))
    string machine;

    @(NamedArgument(["manifest"])
        .Placeholder("manifest.json")
        .Description("Signed desired-state manifest to reconcile"))
    string manifest;

    @(NamedArgument(["state-dir"])
        .Placeholder("DIR")
        .Description("Durable deployment state directory"))
    string stateDir = ".result/mcl-deploy-state";

    @(NamedArgument(["ssh-host"])
        .Placeholder("HOST")
        .Description("SSH host; defaults to MACHINE"))
    string sshHost;

    @(NamedArgument(["ssh-user"])
        .Placeholder("USER")
        .Description("SSH user for the deploy key"))
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
        .Description("Remote command for non-forced-command tests"))
    string remoteCommand;

    @(NamedArgument(["event-log"])
        .Placeholder("events.jsonl")
        .Description("Write deployment events as JSONL"))
    string eventLog;

    @(NamedArgument(["dry-run"])
        .Description("Record desired state and emit pending events without SSH"))
    bool dryRun;
}

export int deploy_ssh(DeploySshArgs args)
{
    DeployReconcileArgs reconcile;
    reconcile.stateDir = args.stateDir;
    if (args.manifest != "")
        reconcile.manifests = [args.manifest];
    reconcile.targets = [args.machine];
    reconcile.sshHost = args.sshHost == "" ? args.machine : args.sshHost;
    reconcile.sshUser = args.sshUser;
    reconcile.identityFile = args.identityFile;
    reconcile.port = args.port;
    reconcile.sshOptions = args.sshOptions;
    reconcile.remoteCommand = args.remoteCommand;
    reconcile.eventLog = args.eventLog;
    reconcile.dryRun = args.dryRun;

    return deployReconcileImpl(reconcile, DeployReconcileDependencies());
}
