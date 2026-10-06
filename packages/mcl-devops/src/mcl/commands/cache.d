module mcl.commands.cache;

import std.exception : enforce;
import std.process : environment;
import std.stdio : stderr;

import argparse : Command, Default, Description, EnvFallback, NamedArgument,
    Placeholder, PositionalArgument, SubCommand, matchCmd;

import mcl.utils.cache_backends : CacheBackend, CachePushRequest,
    defaultAtticPushTimeoutSeconds, defaultCacheProbeTimeoutSeconds,
    parseCacheBackend, pushClosure;
import mcl.utils.deployment_events : deploymentEventLogPathFromEnv;
import mcl.utils.process : ProcessRunner, runProcessCapture, runProcessInlineCapture;

@(Command("cache")
    .Description("Operate on deployment cache backends"))
struct CacheArgs
{
    SubCommand!(
        PushClosureArgs,
        Default!UnknownCacheCommandArgs
    ) cmd;
}

@(Command("push-closure")
    .Description("Push store path closures to a deployment cache backend"))
struct PushClosureArgs
{
    @(NamedArgument(["backend"])
        .Placeholder("cachix|attic|none")
        .Description("Cache backend implementation")
        .EnvFallback("MCL_CACHE_BACKEND"))
    string backend = "cachix";

    @(NamedArgument(["cache"])
        .Placeholder("cache")
        .Description("Cache name")
        .EnvFallback("MCL_CACHE_NAME"))
    string cache;

    @(NamedArgument(["target"])
        .Placeholder("name")
        .Description("Deployment target name for event logs")
        .EnvFallback("DEPLOY_TARGET"))
    string target = "unknown";

    @(NamedArgument(["system"])
        .Placeholder("system")
        .Description("Nix system for event logs")
        .EnvFallback("DEPLOY_SYSTEM"))
    string system = "x86_64-linux";

    @(NamedArgument(["kind"])
        .Placeholder("kind")
        .Description("Target kind for event logs"))
    string kind = "unknown";

    @(NamedArgument(["transport"])
        .Placeholder("transport")
        .Description("Target transport for event logs"))
    string transport = "unknown";

    @(NamedArgument(["event-log"])
        .Placeholder("events.jsonl")
        .Description("Write deployment events as JSONL")
        .EnvFallback("MCL_DEPLOY_EVENT_LOG"))
    string eventLog;

    @(NamedArgument(["correlation-id"])
        .Placeholder("id")
        .Description("Override deployment event correlation id")
        .EnvFallback("DEPLOYMENT_CORRELATION_ID"))
    string correlationId;

    @(NamedArgument(["substituter"])
        .Placeholder("URL")
        .Description("Substituter URL to probe after upload"))
    string[] substituters;

    @(NamedArgument(["trusted-public-key"])
        .Placeholder("KEY")
        .Description("Trusted public key used by substitute probes"))
    string[] trustedPublicKeys;

    @(NamedArgument(["require-substitute"])
        .Description("Fail when uploaded closure paths cannot be substituted from the cache"))
    bool requireSubstitute = false;

    @(NamedArgument(["probe-timeout-seconds"])
        .Placeholder("SECONDS")
        .Description("Maximum seconds to wait for each substitute probe")
        .EnvFallback("MCL_CACHE_PROBE_TIMEOUT_SECONDS"))
    ulong probeTimeoutSeconds = defaultCacheProbeTimeoutSeconds;

    @(NamedArgument(["attic-push-timeout-seconds"])
        .Placeholder("SECONDS")
        .Description("Maximum seconds to wait for each attic push attempt")
        .EnvFallback("MCL_ATTIC_PUSH_TIMEOUT_SECONDS"))
    ulong atticPushTimeoutSeconds = defaultAtticPushTimeoutSeconds;

    @(PositionalArgument(0)
        .Placeholder("STORE_PATH")
        .Description("Root store path to push; repeat for multiple roots"))
    string[] storePaths;
}

@(Command(" ").Description(" "))
struct UnknownCacheCommandArgs { }

int unknown_cache_command(UnknownCacheCommandArgs unused)
{
    stderr.writeln("Unknown cache command. Use --help for a list of available commands.");
    return 1;
}

export int cache(CacheArgs args)
{
    return args.cmd.matchCmd!(
        (PushClosureArgs a) => cachePushClosure(a),
        (UnknownCacheCommandArgs a) => unknown_cache_command(a),
    );
}

int cachePushClosure(PushClosureArgs args)
{
    return cachePushClosureImpl(args,
        (string[] command) => runProcessInlineCapture(command),
        (string[] command) => runProcessCapture(command));
}

int cachePushClosureImpl(PushClosureArgs args, ProcessRunner runProcess, ProcessRunner queryProcess)
{
    auto backend = parseCacheBackend(args.backend);
    auto cacheName = args.cache;
    if (cacheName == "" && backend == CacheBackend.cachix)
        cacheName = environment.get("CACHIX_CACHE", "");
    if (cacheName == "" && backend == CacheBackend.attic)
        cacheName = environment.get("ATTIC_CACHE", "");

    enforce(args.storePaths.length > 0, "At least one store path is required.");
    enforce(backend == CacheBackend.none || cacheName != "",
        "A cache name is required for cachix and attic backends.");
    enforce(args.probeTimeoutSeconds > 0,
        "--probe-timeout-seconds must be greater than zero.");
    enforce(args.atticPushTimeoutSeconds > 0,
        "--attic-push-timeout-seconds must be greater than zero.");

    auto eventLogPath = args.eventLog != ""
        ? args.eventLog
        : deploymentEventLogPathFromEnv();

    return pushClosure(CachePushRequest(
        backend: backend,
        cache: cacheName,
        storePaths: args.storePaths,
        target: args.target,
        system: args.system,
        kind: args.kind,
        transport: args.transport,
        substituters: args.substituters,
        trustedPublicKeys: args.trustedPublicKeys,
        eventLogPath: eventLogPath,
        correlationId: args.correlationId,
        requireSubstitute: args.requireSubstitute,
        probeTimeoutSeconds: args.probeTimeoutSeconds,
        atticPushTimeoutSeconds: args.atticPushTimeoutSeconds,
    ), runProcess, queryProcess);
}
