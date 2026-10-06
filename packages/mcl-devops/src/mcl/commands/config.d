module mcl.commands.config;

import std.algorithm : canFind;
import std.array : array, join;
import std.process : ProcessPipes, Redirect, wait, environment;
import std.range : drop, front;
import std.stdio : writeln;
import std.string : indexOf;
import std.conv : to;

import argparse : Command, Description, SubCommand, Default, PositionalArgument, Placeholder, Optional, matchCmd, NamedArgument, EnvFallback;

import mcl.utils.fetch : fetchJson;
import mcl.utils.log : errorAndExit;
import mcl.utils.nix : nix, queryStorePath;
import mcl.utils.process : execute;
import mcl.utils.string : camelCaseToCapitalCase;

@(Command("config").Description("Manage NixOS machine configurations"))
struct ConfigArgs
{
    SubCommand!(
        SysArgs,
        HomeArgs,
        StartVmArgs,
        Default!UnknownCommandArgs
    ) cmd;
}

@(Command("sys").Description("Manage system configurations"))
struct SysArgs
{
    SubCommand!(
        SysApplyArgs,
        SysEditArgs,
        Default!UnknownCommandArgs
    ) cmd;
}

@(Command("apply").Description("Apply system configuration"))
struct SysApplyArgs
{
    @(PositionalArgument(0).Placeholder("machine-name").Description("Name of the machine"))
    string machineName;
}

@(Command("edit").Description("Edit system configuration"))
struct SysEditArgs
{
    @(PositionalArgument(0).Placeholder("machine-name").Description("Name of the machine"))
    string machineName;
}

@(Command("home").Description("Manage home configurations"))
struct HomeArgs
{
    SubCommand!(
        HomeApplyArgs,
        HomeEditArgs,
        Default!UnknownCommandArgs
    ) cmd;
}

enum HomeConfigType { desktop, server }

@(Command("apply").Description("Apply user configuration"))
struct HomeApplyArgs
{
    @(PositionalArgument(0).Placeholder("desktop/server").Description("Type of home configuration"))
    HomeConfigType type;

    @(NamedArgument(["user"]).Optional().Placeholder("username").Description("Username to apply the configuration for").EnvFallback("USER"))
    string user = "";
}

@(Command("edit").Description("Edit user configuration"))
struct HomeEditArgs
{
    @(PositionalArgument(0).Placeholder("desktop/server").Description("Type of home configuration"))
    HomeConfigType type;
}

@(Command("start-vm").Description("Start a VM"))
struct StartVmArgs
{
    @(PositionalArgument(0).Optional().Placeholder("vm-name").Description("Name of the VM"))
    string vmName = "";
}

@(Command(" ").Description(" "))
struct UnknownCommandArgs { }

int unknown_command(UnknownCommandArgs unused)
{
    errorAndExit("Unknown command. Use --help for a list of available commands.");
    return 1;
}

export int config(ConfigArgs args)
{
    if (!checkRepo())
    {
        errorAndExit(
            "This command must be run from a repository containing a NixOS machine configuration");
    }

    return args.cmd.matchCmd!(
        (SysArgs a) => sys(a),
        (HomeArgs a) => home(a),
        (StartVmArgs a) => startVM(a.vmName),
        (UnknownCommandArgs a) => unknown_command(a)
    );
}

bool checkRepo()
{
    const string[] validRepos = ["infra"];
    string remoteOriginUrl = execute([
        "git", "config", "--get", "remote.origin.url"
    ], false);

    foreach (string repo; validRepos)
    {
        if (remoteOriginUrl.indexOf(repo) != -1)
        {
            return true;
        }
    }
    return false;
}

int executeCommand(string command)
{
    auto exec = execute!ProcessPipes(command, true, false, Redirect.stderrToStdout);
    return wait(exec.pid);
}

int edit(string type, string path)
{
    string editor = environment.get("EDITOR", "vim");
    string user = environment.get("USER", "root");
    writeln("Editing " ~ path ~ " configuration from: ", path);
    final switch (type)
    {
    case "system":
        return executeCommand(editor ~ " machines/*/" ~ path ~ "/*.nix");
    case "user":
        return executeCommand(editor ~ " users/" ~ user ~ "/gitconfig " ~ "users/" ~ user ~ "/*.nix " ~ "users/" ~ user ~ "/home-" ~ path ~ "/*.nix");
    }
}

int apply(string type, string[] args)
{
    writeln("Applying ", type, " configuration from: ", args);
    return executeCommand("just switch-" ~ type ~ " " ~ args.join(" "));
}

int sys(SysArgs args)
{
    return args.cmd.matchCmd!(
        (SysApplyArgs a) => "system".apply([a.machineName]),
        (SysEditArgs a) => "system".edit(a.machineName),
        (UnknownCommandArgs a) => unknown_command(a)
    );
}

int home(HomeArgs args)
{

    return args.cmd.matchCmd!(
        (HomeApplyArgs a) => "home".apply([a.type.to!string, a.user]),
        (HomeEditArgs a) => "user".edit(a.type.to!string),
        (UnknownCommandArgs a) => unknown_command(a)
    );
}

int startVM(string vmName)
{
    writeln("Starting VM: ", vmName);
    return executeCommand("just start-vm " ~ vmName);
}
