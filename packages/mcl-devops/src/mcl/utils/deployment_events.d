module mcl.utils.deployment_events;

import std.algorithm : canFind, map;
import std.array : array, join, split;
import std.conv : to;
import std.datetime.systime : Clock;
import std.datetime.timezone : UTC;
import std.file : append, exists, mkdirRecurse, readText;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
import std.path : dirName;
import std.process : environment;
import std.range : empty, replicate;
import std.regex : matchFirst;
import std.string : replace, strip, stripLeft, stripRight;
import std.typecons : Nullable;

import mcl.utils.process : ProcessResult, ProcessRunner;

struct ClosureSummary
{
    ulong count;
    Nullable!ulong totalBytes;
    string[] rootHashes;
}

struct DeploymentEventContext
{
    string eventLogPath;
    string deploymentId;
    string correlationId;
    string cache;
    string[] substituters;
    string system = "x86_64-linux";
    string kind = "server";
    string transport = "cachix-agent";
    string controller = "cachix-deploy";
}

string deploymentEventLogPathFromEnv()
{
    auto path = environment.get("MCL_DEPLOY_EVENT_LOG", "");
    return path != "" ? path : environment.get("DEPLOYMENT_EVENT_LOG", "");
}

string utcTimestamp() => Clock.currTime(UTC()).toISOExtString();

string deploymentIdFor(string target, string systemPath)
{
    string runId = ("GITHUB_RUN_ID" in environment) ? environment["GITHUB_RUN_ID"] : "local";
    string sha = ("GITHUB_SHA" in environment) ? environment["GITHUB_SHA"][0 .. $ < 7 ? $ : 7] : "unknown";
    return "gh-" ~ runId ~ "-" ~ sha ~ "-" ~ target;
}

string correlationIdFor(string deploymentId, string systemPath)
{
    auto id = environment.get("DEPLOYMENT_CORRELATION_ID", "");
    if (id != "")
        return id;

    const hash = storePathHash(systemPath);
    return hash == "" ? deploymentId : deploymentId ~ "-" ~ hash;
}

string storePathHash(string systemPath)
{
    auto match = systemPath.matchFirst(`^/nix/store/([^-]+)-`);
    return match.empty ? "" : match[1];
}

string stderrSummary(string stderr, size_t limit = 500)
{
    auto summary = stderr
        .split("\n")
        .map!(line => line.strip)
        .array
        .join(" ")
        .strip;

    if (summary.length <= limit)
        return summary;

    // Keep the TAIL, not just the head. A failing command's error is almost
    // always its last output: nix-darwin's `activate` prints a long progress
    // log ("setting up groups... setting up users...") and only then the line
    // that killed it. Head-only truncation cut m3's 2026-10-14 switch and
    // rollback events off at "ln: failed to create symbolic link '/etc/m...",
    // so the jsonl never named the conflicting /etc path. A short head stays
    // for context; the rest of the budget goes to the end.
    enum marker = " ... ";
    const headLen = limit / 4;
    const tailLen = limit - headLen;
    // Byte budget, but never split a UTF-8 sequence.
    size_t head = headLen;
    while (head > 0 && (summary[head] & 0xC0) == 0x80)
        head--;
    size_t tail = summary.length - tailLen;
    while (tail < summary.length && (summary[tail] & 0xC0) == 0x80)
        tail++;
    return summary[0 .. head].stripRight ~ marker ~ summary[tail .. $].stripLeft;
}

@("test_stderr_summary_keeps_the_failing_tail")
unittest
{
    // The shape of m3's 2026-10-14 nix-darwin activation stderr: a long
    // progress log, then the one line that explains the failure.
    string stderr;
    foreach (i; 0 .. 40)
        stderr ~= "updating group members _github-runner-" ~ i.to!string ~ "...\n";
    stderr ~= "setting up /etc...\n"
        ~ "ln: failed to create symbolic link "
        ~ "'/etc/mcl-dev-certs/isonim.test/fullchain.pem': File exists\n";

    auto summary = stderrSummary(stderr);
    assert(summary.length <= 500 + " ... ".length, summary);
    assert(summary.canFind("'/etc/mcl-dev-certs/isonim.test/fullchain.pem': File exists"),
        summary);
    assert(summary.canFind("updating group members _github-runner-0..."), summary);
    assert(summary.canFind(" ... "), summary);

    // Short output is unchanged.
    assert(stderrSummary("host is busy\n") == "host is busy");

    // A multi-byte character at either cut point is not split.
    auto wide = stderrSummary("é".replicate(400));
    import std.utf : validate;
    validate(wide);
}

Nullable!ClosureSummary closureSummaryFromEnv(string systemPath)
{
    auto countText = environment.get("MCL_DEPLOY_FAKE_CLOSURE_COUNT", "");
    if (countText != "")
    {
        Nullable!ulong totalBytes;
        auto bytesText = environment.get("MCL_DEPLOY_FAKE_CLOSURE_TOTAL_BYTES", "");
        if (bytesText != "")
            totalBytes = Nullable!ulong(bytesText.to!ulong);

        return Nullable!ClosureSummary(ClosureSummary(
            count: countText.to!ulong,
            totalBytes: totalBytes,
            rootHashes: [storePathHash(systemPath)],
        ));
    }

    return Nullable!ClosureSummary.init;
}

Nullable!ClosureSummary queryClosureSummary(string systemPath, ProcessRunner runner)
{
    auto fake = closureSummaryFromEnv(systemPath);
    if (!fake.isNull)
        return fake;

    if (runner is null)
        return Nullable!ClosureSummary.init;

    auto result = runner([
        "nix", "path-info", "--json", "--recursive", systemPath
    ]);

    if (!result.succeeded || result.stdout.strip == "")
        return Nullable!ClosureSummary.init;

    try
    {
        auto json = result.stdout.parseJSON;
        ulong count;
        Nullable!ulong totalBytes;
        ulong bytes;
        bool sawNarSize;

        void visit(JSONValue value)
        {
            count++;
            if (value.type == JSONType.object)
            {
                if (auto narSize = "narSize" in value.object)
                {
                    if (narSize.type == JSONType.integer)
                    {
                        bytes += narSize.integer.to!ulong;
                        sawNarSize = true;
                    }
                }
            }
        }

        if (json.type == JSONType.object)
            foreach (_path, value; json.object)
                visit(value);
        else if (json.type == JSONType.array)
            foreach (value; json.array)
                visit(value);
        else
            return Nullable!ClosureSummary.init;

        if (sawNarSize)
            totalBytes = Nullable!ulong(bytes);

        return count == 0
            ? Nullable!ClosureSummary.init
            : Nullable!ClosureSummary(ClosureSummary(
                count: count,
                totalBytes: totalBytes,
                rootHashes: [storePathHash(systemPath)],
            ));
    }
    catch (Exception)
    {
        return Nullable!ClosureSummary.init;
    }
}

JSONValue deploymentEventJson(
    DeploymentEventContext context,
    string phase,
    string target,
    string systemPath,
    string commandName,
    string[] argv,
    string status,
    int exitCode,
    Nullable!ClosureSummary closure = Nullable!ClosureSummary.init,
    string errorMessage = "",
    string errorCode = "command_failed",
    string errorDetails = "",
    JSONValue[string] metadata = null,
    bool errorRetryable = false,
)
{
    JSONValue[string] event;
    JSONValue[string] targetJson = [
        "name": JSONValue(target),
        "system": JSONValue(context.system),
        "kind": JSONValue(context.kind),
        "transport": JSONValue(context.transport),
    ];
    JSONValue[string] backend = [
        "cache": JSONValue(context.cache),
        "substituters": JSONValue(context.substituters.map!(s => JSONValue(s)).array),
        "controller": JSONValue(context.controller),
    ];
    JSONValue[string] storePaths = [
        "system": JSONValue(systemPath),
    ];
    JSONValue[string] timestamps = [
        "startedAt": JSONValue(utcTimestamp()),
        "finishedAt": JSONValue(utcTimestamp()),
    ];
    JSONValue[string] command = [
        "name": JSONValue(commandName),
        "argv": JSONValue(argv.map!(arg => JSONValue(arg)).array),
        "status": JSONValue(status),
        "exitCode": JSONValue(exitCode),
    ];

    if (!closure.isNull)
    {
        auto summary = closure.get;
        JSONValue[string] closureJson = [
            "count": JSONValue(cast(long) summary.count),
            "totalBytes": summary.totalBytes.isNull
                ? JSONValue(null)
                : JSONValue(cast(long) summary.totalBytes.get),
            "rootHashes": JSONValue(summary.rootHashes.map!(h => JSONValue(h)).array),
        ];
        storePaths["closure"] = JSONValue(closureJson);
    }

    event["schemaVersion"] = JSONValue(1);
    event["deploymentId"] = JSONValue(
        context.deploymentId == "" ? deploymentIdFor(target, systemPath) : context.deploymentId
    );
    event["correlationId"] = JSONValue(
        context.correlationId == ""
            ? correlationIdFor(event["deploymentId"].str, systemPath)
            : context.correlationId
    );
    event["phase"] = JSONValue(phase);
    event["target"] = JSONValue(targetJson);
    event["backend"] = JSONValue(backend);
    event["storePaths"] = JSONValue(storePaths);
    event["timestamps"] = JSONValue(timestamps);
    event["command"] = JSONValue(command);

    if (status == "failed" || errorMessage != "")
    {
        JSONValue[string] details;
        if (errorDetails != "")
            details["stderrSummary"] = JSONValue(errorDetails);

        event["error"] = JSONValue([
            "code": JSONValue(errorCode),
            "message": JSONValue(errorMessage == "" ? "Deployment phase failed" : errorMessage),
            "retryable": JSONValue(errorRetryable),
            "details": JSONValue(details),
        ]);
    }

    if (metadata !is null)
        event["metadata"] = JSONValue(metadata);

    return JSONValue(event);
}

void appendDeploymentEvent(string eventLogPath, JSONValue event)
{
    if (eventLogPath == "")
        return;

    const parent = eventLogPath.dirName;
    if (parent != "" && !parent.exists)
        mkdirRecurse(parent);

    eventLogPath.append(event.toString(JSONOptions.doNotEscapeSlashes) ~ "\n");
}

JSONValue[] readDeploymentEvents(string eventLogPath)
{
    JSONValue[] events;
    foreach (line; eventLogPath.readText.split("\n"))
    {
        if (line.strip == "")
            continue;
        events ~= line.parseJSON;
    }
    return events;
}

JSONValue deploymentSummaryJson(JSONValue[] events)
{
    JSONValue[string] byTarget;
    JSONValue[] failures;
    string finalState = "unknown";

    foreach (event; events)
    {
        const target = event["target"]["name"].str;
        const status = event["command"]["status"].str;
        byTarget[target] = event;
        if (status == "failed")
            failures ~= event;
    }

    if (!failures.empty)
        finalState = "failed";
    else if (!events.empty)
        finalState = "succeeded";

    JSONValue[] targets = byTarget
        .byKeyValue
        .map!(kv => JSONValue([
            "name": JSONValue(kv.key),
            "phase": JSONValue(kv.value["phase"].str),
            "status": JSONValue(kv.value["command"]["status"].str),
            "systemPath": JSONValue(kv.value["storePaths"]["system"].str),
        ]))
        .array;

    return JSONValue([
        "finalState": JSONValue(finalState),
        "targetCount": JSONValue(cast(long) targets.length),
        "failureCount": JSONValue(cast(long) failures.length),
        "targets": JSONValue(targets),
    ]);
}

string renderDeploymentSummaryMarkdown(JSONValue[] events)
{
    auto summary = deploymentSummaryJson(events);
    string markdown = "# Deployment Summary\n\n";
    markdown ~= "- Final state: `" ~ summary["finalState"].str ~ "`\n";
    markdown ~= "- Targets: " ~ summary["targetCount"].integer.to!string ~ "\n";
    markdown ~= "- Failures: " ~ summary["failureCount"].integer.to!string ~ "\n\n";
    markdown ~= "| Target | Phase | Status | Closure | Failure |\n";
    markdown ~= "| --- | --- | --- | --- | --- |\n";

    JSONValue[string] byTarget;
    foreach (event; events)
        byTarget[event["target"]["name"].str] = event;

    foreach (target, event; byTarget)
    {
        string closure = "unknown";
        if (auto closureJson = "closure" in event["storePaths"].object)
        {
            closure = (*closureJson)["count"].integer.to!string ~ " paths";
            if (!(*closureJson)["totalBytes"].isNull)
                closure ~= ", " ~ (*closureJson)["totalBytes"].integer.to!string ~ " bytes";
        }

        string failure = "";
        if (auto error = "error" in event.object)
        {
            failure = (*error)["message"].str;
            if (auto details = "details" in (*error).object)
                if (auto stderr = "stderrSummary" in details.object)
                    failure ~= ": " ~ stderr.str;
        }

        markdown ~= "| " ~ target ~
            " | " ~ event["phase"].str ~
            " | " ~ event["command"]["status"].str ~
            " | " ~ closure.replace("|", "\\|") ~
            " | " ~ failure.replace("|", "\\|") ~
            " |\n";
    }

    if (!events.empty)
    {
        markdown ~= "\n## Phases\n\n";
        foreach (event; events)
            markdown ~= "- `" ~ event["target"]["name"].str ~ "` `" ~
                event["phase"].str ~ "`: `" ~
                event["command"]["status"].str ~ "`\n";
    }

    return markdown;
}

@("test_deploy_summary_from_events")
unittest
{
    auto events = [
        deploymentEventJson(
            DeploymentEventContext(
                eventLogPath: "",
                correlationId: "corr",
                cache: "cache",
                substituters: ["https://cache.example"],
            ),
            "activate-requested",
            "app-server-01",
            "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-app-server-01",
            "cachix deploy activate",
            ["cachix", "deploy", "activate"],
            "failed",
            42,
            Nullable!ClosureSummary(ClosureSummary(
                count: 3,
                totalBytes: Nullable!ulong(99),
                rootHashes: ["0123456789abcdfghijklmnpqrsvwxyz"],
            )),
            "Activation request failed",
            "command_failed",
            "cachix said no",
        )
    ];

    auto markdown = renderDeploymentSummaryMarkdown(events);
    assert(markdown.canFind("app-server-01"));
    assert(markdown.canFind("Activation request failed"));
    assert(markdown.canFind("cachix said no"));
}
