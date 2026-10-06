module mcl.main;

import std.stdio : writefln, writeln, stderr;
import std.array : replace;
import std.getopt : getopt;
import std.logger : infof, errorf, LogLevel;
import std.string : stripRight, stripLeft;
import std.algorithm : endsWith;
import std.format : format;
import std.meta : staticMap;
import std.traits : Parameters;
import sparkles.core_cli.logger : initLogger;
import mcl.utils.path : rootDir;
import mcl.utils.tui : bold;

import mcl.commands : SubCommandFunctions;

import argparse : Command, Description, SubCommand, NamedArgument, Default, CLI, matchCmd;

@(Command(" ").Description(" "))
struct UnknownCommandArgs { }
int unknown_command(UnknownCommandArgs unused)
{
    stderr.writeln("Unknown command. Use --help for a list of available commands.");
    return 1;
}

struct MCLArgs
{
    @NamedArgument(["log-level"])
    LogLevel logLevel = LogLevel.info;

    SubCommand!(
        staticMap!(Parameters, SubCommandFunctions),
        Default!UnknownCommandArgs
    ) cmd;
}

alias SumTypeCase(alias func) = (Parameters!func args) => func(args);

mixin CLI!MCLArgs.main!((args)
{
    initLogger(args.logLevel);

    int result = args.cmd.matchCmd!(
        staticMap!(SumTypeCase, unknown_command, SubCommandFunctions),
    );

    return result;
});
