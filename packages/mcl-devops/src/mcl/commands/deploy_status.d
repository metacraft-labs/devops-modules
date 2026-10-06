module mcl.commands.deploy_status;

import std.file : write;
import std.json : JSONOptions;
import std.stdio : writeln;

import argparse : Command, Default, Description, NamedArgument,
    Placeholder, PositionalArgument, SubCommand, matchCmd;

import mcl.utils.deployment_events : deploymentSummaryJson,
    readDeploymentEvents, renderDeploymentSummaryMarkdown;

@(Command("deploy-status")
    .Description("Inspect deployment event logs"))
struct DeployStatusArgs
{
    SubCommand!(
        DeployStatusSummarizeArgs,
        Default!UnknownCommandArgs
    ) cmd;
}

@(Command("summarize")
    .Description("Render a concise markdown summary from deployment JSONL events"))
struct DeployStatusSummarizeArgs
{
    @(PositionalArgument(0)
        .Placeholder("events.jsonl")
        .Description("Deployment event JSONL file"))
    string eventsPath;

    @(NamedArgument(["output", "o"])
        .Placeholder("summary.md")
        .Description("Write markdown summary to this path instead of stdout"))
    string output;

    @(NamedArgument(["json-output"])
        .Placeholder("summary.json")
        .Description("Write machine-readable summary JSON to this path"))
    string jsonOutput;
}

@(Command(" ").Description(" "))
struct UnknownCommandArgs { }

int unknown_command(UnknownCommandArgs unused)
{
    import std.stdio : stderr;

    stderr.writeln("Unknown deploy-status command. Use --help for a list of available commands.");
    return 1;
}

export int deploy_status(DeployStatusArgs args)
{
    return args.cmd.matchCmd!(
        (DeployStatusSummarizeArgs a) => summarize(a),
        (UnknownCommandArgs a) => unknown_command(a),
    );
}

int summarize(DeployStatusSummarizeArgs args)
{
    auto events = readDeploymentEvents(args.eventsPath);
    auto markdown = renderDeploymentSummaryMarkdown(events);
    auto summary = deploymentSummaryJson(events);

    if (args.output == "")
        writeln(markdown);
    else
        args.output.write(markdown);

    if (args.jsonOutput != "")
        args.jsonOutput.write(summary.toString(JSONOptions.doNotEscapeSlashes));

    return 0;
}
