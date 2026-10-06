module mcl.commands.deploy_spec;

import std.algorithm : canFind, filter, map;
import std.array : array;
import std.logger : infof, warningf;
import std.file : exists;
import std.path : buildPath;
import std.range : empty;
import std.string : split;
import std.typecons : Nullable;

import argparse : Command, Description, EnvFallback, NamedArgument, Placeholder;

import mcl.utils.process : ProcessResult, ProcessRunner, runProcessCapture,
    runProcessInlineCapture, spawnProcessInline;
import mcl.utils.path : resultDir;
import mcl.utils.cachix : DeploySpec, createMachineDeploySpec;
import mcl.utils.tui : bold;
import mcl.utils.json : tryDeserializeFromJsonFile, writeJsonFile;
import mcl.utils.deployment_events : ClosureSummary, DeploymentEventContext,
    appendDeploymentEvent, deploymentEventJson, deploymentEventLogPathFromEnv,
    queryClosureSummary, stderrSummary;

import mcl.commands.ci_matrix : CiMatrixBaseArgs, Package,
    deployableServerMachinesAttrPath, getPrecalcMatrix, nixEvalJobs;

enum deploySpecClosureSummaryEnv = "MCL_DEPLOY_SPEC_CLOSURE_SUMMARIES";

Nullable!ClosureSummary deploySpecClosureSummary(
    bool enabled,
    string systemPath,
    ProcessRunner queryRunner,
)
{
    return enabled
        ? queryClosureSummary(systemPath, queryRunner)
        : Nullable!ClosureSummary.init;
}

@(Command("deploy-spec", "deploy_spec")
    .Description("Evaluate the Nixos machine configurations in bareMetalMachines and deploy them to cachix."))
struct DeploySpecArgs {
    mixin CiMatrixBaseArgs!();

    @(NamedArgument(["event-log"])
        .Placeholder("events.jsonl")
        .Description("Write backend-neutral deployment events as JSONL")
        .EnvFallback("MCL_DEPLOY_EVENT_LOG"))
    string eventLog;

    @(NamedArgument(["closure-summaries"])
        .Description("Include recursive closure summaries in deployment events; expensive on shared CI final runners")
        .EnvFallback(deploySpecClosureSummaryEnv))
    bool closureSummaries;
}

struct DeploySpecDependencies
{
    ProcessRunner runProcess;
    ProcessRunner queryProcess;
    Package[] delegate(DeploySpecArgs args) evaluateServerMachines;
}

export int deploy_spec(DeploySpecArgs args)
{
    return deploySpecImpl(args, DeploySpecDependencies(
        runProcess: (string[] command) => runProcessInlineCapture(command),
        queryProcess: (string[] command) => runProcessCapture(command),
    ));
}

Package[] evaluateServerMachinesWithNixEvalJobs(DeploySpecArgs args)
{
    return deployableServerMachinesAttrPath.nixEvalJobs(args);
}

string deploymentAgentName(Package pkg)
{
    auto parts = pkg.name.split("/");
    return parts.length >= 3 && (parts[0] == "machine" || parts[0] == "serverMachines")
        ? parts[1]
        : pkg.name;
}

Package deploymentAgentPackage(Package pkg)
{
    pkg.name = pkg.deploymentAgentName;
    return pkg;
}

Package[] precomputedDeploymentPackages(DeploySpecArgs args)
{
    return args.getPrecalcMatrix
        .filter!(pkg => pkg.deploymentTarget && pkg.deploymentKind == "server")
        .map!deploymentAgentPackage
        .array;
}

int deploySpecImpl(DeploySpecArgs args, DeploySpecDependencies deps, string deploySpecFile = resultDir.buildPath("cachix-deploy-spec.json"))
{
    import std.exception : enforce;
    import std.json : JSONValue;

    DeploySpec spec;
    auto eventLogPath = args.eventLog != "" ? args.eventLog : deploymentEventLogPathFromEnv();
    auto context = DeploymentEventContext(
        eventLogPath: eventLogPath,
        cache: args.cachixCache,
        substituters: args.binaryCacheUrls,
    );
    auto queryRunner = deps.queryProcess is null ? deps.runProcess : deps.queryProcess;
    const eventLoggingEnabled = eventLogPath != "";
    // Recursive `nix path-info --json --recursive` is intentionally disabled
    // by default for deploy-spec event logging. In the shared CI final
    // aggregator job, machine closures were built on per-machine runners, so
    // querying closure summaries here can spend minutes substituting closure
    // metadata before activation is even requested. Set
    // MCL_DEPLOY_SPEC_CLOSURE_SUMMARIES=1 locally when debugging event payloads
    // and willing to pay for recursive closure queries.
    const includeClosureSummaries = eventLoggingEnabled && args.closureSummaries;
    Package[] delegate(DeploySpecArgs args) evaluateServerMachines = deps.evaluateServerMachines;
    if (evaluateServerMachines is null)
        evaluateServerMachines = (DeploySpecArgs args) => evaluateServerMachinesWithNixEvalJobs(args);

    if (!exists(deploySpecFile))
    {
        const usePrecomputedMatrix = args.precalcMatrix != "";
        auto nixosConfigs = usePrecomputedMatrix
            ? args.precomputedDeploymentPackages
            : evaluateServerMachines(args);

        auto pkgsNotFoundInCache = nixosConfigs.filter!(c => c.cachedAt.empty);

        if (usePrecomputedMatrix)
            infof(
                "Using %s deployment targets from precomputed CI matrix.",
                nixosConfigs.length
            );
        else
            foreach (pkg; pkgsNotFoundInCache.save())
            {
                warningf(
                    "Nixos configuration '%s' is not in cachix.\nExpected Cachix URL: %s\n",
                    pkg.name.bold,
                    pkg.getNarInfoUrl(args.binaryCacheUrls[0]).bold
                );
            }

        foreach (pkg; nixosConfigs)
        {
            auto closure = deploySpecClosureSummary(includeClosureSummaries, pkg.output, queryRunner);
            appendDeploymentEvent(eventLogPath, deploymentEventJson(
                context,
                "evaluate",
                pkg.name,
                pkg.output,
                usePrecomputedMatrix ? "precomputed CI matrix" : "nix-eval-jobs",
                usePrecomputedMatrix
                    ? ["mcl-devops", "deploy-spec", "--precalc-matrix"]
                    : ["nix-eval-jobs", "--flake", deployableServerMachinesAttrPath],
                "succeeded",
                0,
                closure,
                "",
                "command_failed",
                "",
                [
                    "attrPath": JSONValue(pkg.attrPath),
                    "derivation": JSONValue(pkg.derivation),
                ],
            ));
            appendDeploymentEvent(eventLogPath, deploymentEventJson(
                context,
                "build",
                pkg.name,
                pkg.output,
                "ci build",
                ["nix", "build", ".#" ~ pkg.attrPath],
                "skipped",
                0,
                closure,
                "",
                "command_failed",
                "",
                [
                    "reason": JSONValue("build phase is performed by the reusable workflow before deploy-spec"),
                ],
            ));
            if (!usePrecomputedMatrix)
                appendDeploymentEvent(eventLogPath, deploymentEventJson(
                    context,
                    "closure-prefill",
                    pkg.name,
                    pkg.output,
                    "cache availability check",
                    ["mcl-devops", "deploy-spec"],
                    pkg.cachedAt.empty ? "failed" : "succeeded",
                    pkg.cachedAt.empty ? 1 : 0,
                    closure,
                    pkg.cachedAt.empty ? "System closure is not available in the configured caches" : "",
                    "closure_not_cached",
                    pkg.cachedAt.empty ? pkg.getNarInfoUrl(args.binaryCacheUrls[0]) : "",
                    [
                        "cachedAt": JSONValue(pkg.cachedAt.map!(url => JSONValue(url)).array),
                    ],
                ));
            appendDeploymentEvent(eventLogPath, deploymentEventJson(
                context,
                "cache-push",
                pkg.name,
                pkg.output,
                "cachix push",
                ["cachix", "push", args.cachixCache, pkg.output],
                "skipped",
                0,
                closure,
                "",
                "command_failed",
                "",
                [
                    "reason": JSONValue("cache push is performed by the reusable workflow build job"),
                ],
            ));
        }

        if (!usePrecomputedMatrix && !pkgsNotFoundInCache.empty)
            throw new Exception("Some Nixos configurations are not in cachix. Please cache them first.");

        spec = nixosConfigs.createMachineDeploySpec();
        writeJsonFile(spec, deploySpecFile);
    }
    else
    {
        warningf("Reusing existing deploy spec at:\n'%s'", deploySpecFile.bold);
        spec = deploySpecFile.tryDeserializeFromJsonFile!DeploySpec();
        foreach (target, systemPath; spec.agents)
            appendDeploymentEvent(eventLogPath, deploymentEventJson(
                context,
                "evaluate",
                target,
                systemPath,
                "deploy spec reuse",
                ["mcl-devops", "deploy-spec"],
                "skipped",
                0,
                Nullable!ClosureSummary.init,
                "",
                "command_failed",
                "",
                [
                    "deploySpecFile": JSONValue(deploySpecFile),
                    "reused": JSONValue(true),
                ],
            ));
    }

    infof("\n---\n%s\n---", spec);
    infof("%s machines will be deployed.", spec.agents.length);

    if (!spec.agents.length)
        return 0;

    infof(
        "Pushing deployment closure for %s agents to Cachix cache '%s'.",
        spec.agents.length,
        args.cachixCache
    );

    // NOTE: deploy_spec used to run a second `nix-store -r ... | cachix push`
    // here, but that turned out to be redundant *and* prone to failure on the
    // Final Results runner.
    //
    //   * Redundant: the matrix-build step in the reusable workflow already
    //     ran `mcl-devops cache push-closure` for every machine on the per-machine
    //     runner where the closure was actually built. By the time deploy_spec
    //     runs on the aggregator (Final Results) runner, the closure narinfos
    //     are on the configured Cachix cache and the activation only needs
    //     `cachix deploy activate` to point the agent at the deploy spec.
    //
    //   * Prone to failure: the aggregator runner does not have the closure
    //     in its local /nix/store (matrix builds happen on other runners).
    //     The old `nix-store -r ...` step needed to substitute every system
    //     closure first — and when nix-eval-jobs reports `isCached` based on
    //     narinfo presence alone (without verifying the NAR is also there),
    //     a half-pushed cache entry would let shard-matrix skip the per-
    //     machine build step, leaving deploy_spec unable to substitute,
    //     unable to build, and unable to push. The whole deploy then fails
    //     at the redundant push step (`don't know how to build these paths`).
    //
    // The activate step below is sufficient: cachix-agent on the target host
    // substitutes from the configured caches, and the agent fails clearly if
    // a NAR is missing. Emit a single skipped `cache-push` event per agent
    // so the deployment event log still records the phase.
    if (eventLoggingEnabled)
        foreach (target, systemPath; spec.agents)
            appendDeploymentEvent(eventLogPath, deploymentEventJson(
                context,
                "cache-push",
                target,
                systemPath,
                "mcl-push-deployment-closure",
                ["skipped-by-deploy-spec"],
                "skipped",
                0,
                deploySpecClosureSummary(includeClosureSummaries, systemPath, queryRunner),
                "",
                "command_failed",
                "",
                [
                    "deploySpecFile": JSONValue(deploySpecFile),
                    "reason": JSONValue(
                        "Per-machine matrix push handles the closure upload; "
                        ~ "deploy_spec runs on the aggregator and only triggers activation."
                    ),
                ],
            ));

    auto activateCommand = [
        "cachix", "deploy", "activate", deploySpecFile, "--async"
    ];

    if (!eventLoggingEnabled)
    {
        spawnProcessInline(activateCommand);
        return 0;
    }

    auto result = deps.runProcess(activateCommand);
    foreach (target, systemPath; spec.agents)
        appendDeploymentEvent(eventLogPath, deploymentEventJson(
            context,
            "activate-requested",
            target,
            systemPath,
            "cachix deploy activate",
            activateCommand,
            result.succeeded ? "succeeded" : "failed",
            result.exitCode,
            deploySpecClosureSummary(includeClosureSummaries, systemPath, queryRunner),
            result.succeeded ? "" : "Activation request failed",
            "activation_request_failed",
            result.succeeded ? "" : result.stderr.stderrSummary,
            [
                "deploySpecFile": JSONValue(deploySpecFile),
            ],
        ));

    enforce(result.succeeded, "Process failed.");

    return 0;
}

@("test_deploy_event_log_success_shape")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.algorithm : filter;
    import std.string : splitLines;

    auto tempBase = deleteme;
    auto eventLog = tempBase ~ ".success.events.jsonl";
    auto specFile = tempBase ~ ".success.spec.json";
    scope(exit)
    {
        if (tempBase.exists) tempBase.remove;
        if (eventLog.exists) eventLog.remove;
        if (specFile.exists) specFile.remove;
    }

    DeploySpecArgs args;
    args.cachixCache = "example-cache";
    args.cachixAuthToken = "token";
    args.eventLog = eventLog;

    uint pathInfoCalls;
    ProcessResult fakeRunner(string[] command)
    {
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info")
        {
            pathInfoCalls++;
            return ProcessResult(
                0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7},"/nix/store/1123456789abcdfghijklmnpqrsvwxyz-dep":{"narSize":11}}`,
                "",
            );
        }
        return ProcessResult(0, "", "");
    }

    writeJsonFile(DeploySpec(agents: [
        "app-server-01": "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-app-server-01",
    ]), specFile);

    assert(deploySpecImpl(args, DeploySpecDependencies(&fakeRunner), specFile) == 0);
    assert(pathInfoCalls == 0);

    auto events = eventLog.readText.splitLines.filter!(line => line != "").map!(line => line.parseJSON).array;
    assert(events.length == 3);
    assert(events[0]["phase"].str == "evaluate");
    // deploy_spec no longer invokes its own cache push; it records a
    // "skipped" cache-push event to keep the event sequence shape stable
    // for consumers. The per-machine matrix push step in the workflow is
    // the actual cache push.
    assert(events[1]["phase"].str == "cache-push");
    assert(events[1]["command"]["status"].str == "skipped");
    assert(events[2]["phase"].str == "activate-requested");
    assert(events[2]["command"]["status"].str == "succeeded");
    assert("closure" !in events[1]["storePaths"].object);
    assert("closure" !in events[2]["storePaths"].object);
}

@("test_deploy_event_log_closure_summary_opt_in")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.algorithm : filter;
    import std.string : splitLines;

    auto tempBase = deleteme;
    auto eventLog = tempBase ~ ".closure-summary.events.jsonl";
    auto specFile = tempBase ~ ".closure-summary.spec.json";
    scope(exit)
    {
        if (tempBase.exists) tempBase.remove;
        if (eventLog.exists) eventLog.remove;
        if (specFile.exists) specFile.remove;
    }

    DeploySpecArgs args;
    args.cachixCache = "example-cache";
    args.cachixAuthToken = "token";
    args.eventLog = eventLog;
    args.closureSummaries = true;

    uint pathInfoCalls;
    ProcessResult fakeRunner(string[] command)
    {
        if (command.length >= 5
            && command[0] == "nix"
            && command[1] == "path-info"
            && command[2] == "--json"
            && command[3] == "--recursive")
        {
            pathInfoCalls++;
            return ProcessResult(
                0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7},"/nix/store/1123456789abcdfghijklmnpqrsvwxyz-dep":{"narSize":11}}`,
                "",
            );
        }
        return ProcessResult(0, "", "");
    }

    writeJsonFile(DeploySpec(agents: [
        "app-server-01": "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-app-server-01",
    ]), specFile);

    assert(deploySpecImpl(args, DeploySpecDependencies(&fakeRunner), specFile) == 0);
    assert(pathInfoCalls == 2);

    auto events = eventLog.readText.splitLines.filter!(line => line != "").map!(line => line.parseJSON).array;
    assert(events.length == 3);
    assert(events[1]["storePaths"]["closure"]["count"].integer == 2);
    assert(events[1]["storePaths"]["closure"]["totalBytes"].integer == 18);
    assert(events[2]["storePaths"]["closure"]["count"].integer == 2);
    assert(events[2]["storePaths"]["closure"]["totalBytes"].integer == 18);
}

@("test_deploy_spec_uses_precomputed_matrix_without_nix_eval_jobs")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.algorithm : filter;
    import std.string : splitLines;

    auto tempBase = deleteme;
    auto eventLog = tempBase ~ ".precalc.events.jsonl";
    auto specFile = tempBase ~ ".precalc.spec.json";
    scope(exit)
    {
        if (tempBase.exists) tempBase.remove;
        if (eventLog.exists) eventLog.remove;
        if (specFile.exists) specFile.remove;
    }

    enum serverOutput = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-app-server-01";
    DeploySpecArgs args;
    args.eventLog = eventLog;
    args.extraCacheUrls = ["http://127.0.0.1:9"];
    args.precalcMatrix = `{"include":[`
        ~ `{"name":"machine/app-server-01/x86_64-linux",`
        ~ `"allowedToFail":false,`
        ~ `"attrPath":"mcl.shard-matrix.result.shards.shard-0.machine/app-server-01/x86_64-linux",`
        ~ `"cachedAt":[],`
        ~ `"ghRunner":["self-hosted"],`
        ~ `"system":"x86_64-linux",`
        ~ `"derivation":"/nix/store/11111111111111111111111111111111-app-server-01.drv",`
        ~ `"output":"` ~ serverOutput ~ `",`
        ~ `"deploymentTarget":true,`
        ~ `"deploymentKind":"server"},`
        ~ `{"name":"machine/workstation-01/x86_64-linux",`
        ~ `"allowedToFail":false,`
        ~ `"attrPath":"mcl.shard-matrix.result.shards.shard-0.machine/workstation-01/x86_64-linux",`
        ~ `"cachedAt":[],`
        ~ `"ghRunner":["self-hosted"],`
        ~ `"system":"x86_64-linux",`
        ~ `"derivation":"/nix/store/22222222222222222222222222222222-workstation-01.drv",`
        ~ `"output":"/nix/store/22222222222222222222222222222222-nixos-system-workstation-01",`
        ~ `"deploymentTarget":false,`
        ~ `"deploymentKind":""}`
        ~ `]}`;

    uint evalCalls;
    Package[] failIfEvaluated(DeploySpecArgs args)
    {
        evalCalls++;
        assert(0, "precomputed deploy-spec path must not invoke nix-eval-jobs");
    }

    uint pathInfoCalls;
    ProcessResult fakeRunner(string[] command)
    {
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info")
            pathInfoCalls++;
        return ProcessResult(0, "", "");
    }

    assert(deploySpecImpl(
        args,
        DeploySpecDependencies(
            runProcess: &fakeRunner,
            queryProcess: &fakeRunner,
            evaluateServerMachines: &failIfEvaluated,
        ),
        specFile,
    ) == 0);
    assert(evalCalls == 0);
    assert(pathInfoCalls == 0);

    auto spec = specFile.tryDeserializeFromJsonFile!DeploySpec();
    assert(spec.agents.length == 1);
    assert(spec.agents["app-server-01"] == serverOutput);
    assert("machine/app-server-01/x86_64-linux" !in spec.agents);

    auto events = eventLog.readText.splitLines.filter!(line => line != "").map!(line => line.parseJSON).array;
    assert(events[$ - 1]["phase"].str == "activate-requested");
    assert(events[$ - 1]["target"]["name"].str == "app-server-01");
    assert(events[$ - 1]["storePaths"]["system"].str == serverOutput);
}

@("test_deploy_event_log_failure_shape")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.algorithm : filter;
    import std.string : splitLines;
    import std.exception : assertThrown;

    auto tempBase = deleteme;
    auto eventLog = tempBase ~ ".failure.events.jsonl";
    auto specFile = tempBase ~ ".failure.spec.json";
    scope(exit)
    {
        if (tempBase.exists) tempBase.remove;
        if (eventLog.exists) eventLog.remove;
        if (specFile.exists) specFile.remove;
    }

    DeploySpecArgs args;
    args.cachixCache = "example-cache";
    args.cachixAuthToken = "token";
    args.eventLog = eventLog;

    ProcessResult fakeRunner(string[] command)
    {
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info")
            return ProcessResult(0, `{}`, "");
        // Activation fails; closure push and other commands succeed so this
        // test exercises the activation failure path specifically.
        if (command.length >= 3 && command[0] == "cachix"
            && command[1] == "deploy" && command[2] == "activate")
            return ProcessResult(23, "", "activation stderr details");
        return ProcessResult(0, "", "");
    }

    writeJsonFile(DeploySpec(agents: [
        "app-server-01": "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-app-server-01",
    ]), specFile);

    assertThrown!Exception(deploySpecImpl(args, DeploySpecDependencies(&fakeRunner), specFile));

    auto events = eventLog.readText.splitLines.filter!(line => line != "").map!(line => line.parseJSON).array;
    auto failed = events[$ - 1];
    assert(failed["phase"].str == "activate-requested");
    assert(failed["command"]["status"].str == "failed");
    assert(failed["command"]["exitCode"].integer == 23);
    assert(failed["error"]["details"]["stderrSummary"].str.canFind("activation stderr details"));
}
