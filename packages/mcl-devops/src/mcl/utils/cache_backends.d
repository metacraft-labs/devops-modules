module mcl.utils.cache_backends;

import std.algorithm : canFind, map;
import std.array : array, join;
import std.conv : to;
import std.file : deleteme, exists, mkdirRecurse, rmdirRecurse;
import std.json : JSONValue;
import std.string : splitLines, strip, toLower;
import std.typecons : Nullable;

import mcl.utils.deployment_events : ClosureSummary, DeploymentEventContext,
    appendDeploymentEvent, deploymentEventJson, queryClosureSummary, stderrSummary;
import mcl.utils.process : ProcessResult, ProcessRunner;

enum ulong defaultCacheProbeTimeoutSeconds = 30;
enum ulong defaultAtticPushTimeoutSeconds = 1800;
enum ulong cacheProbeMaxAttempts = 3;
// Deployment-closure pushes are idempotent (see isTransientAtticPushFailure), so
// a transient network/proxy hiccup is worth several retries with backoff rather
// than aborting the whole per-host publish loop. 5 attempts ≈ 2+5+10+20s of
// backoff around ~flaky-cache windows.
enum ulong atticPushMaxAttempts = 5;

enum CacheBackend
{
    cachix,
    attic,
    none,
}

struct CachePushRequest
{
    CacheBackend backend;
    string cache;
    string[] storePaths;
    string target = "unknown";
    string system = "x86_64-linux";
    string kind = "unknown";
    string transport = "unknown";
    string[] substituters;
    string[] trustedPublicKeys;
    string eventLogPath;
    string correlationId;
    bool requireSubstitute = true;
    ulong probeTimeoutSeconds = defaultCacheProbeTimeoutSeconds;
    ulong atticPushTimeoutSeconds = defaultAtticPushTimeoutSeconds;
}

struct CachePushPlan
{
    string commandName;
    string[] argv;
    string controller;
    string[] substituters;
    bool externalCommand;
}

struct CacheProbeResult
{
    string path;
    string substituter;
    string outcome;
    int exitCode;
    string message;

    bool successful() const => outcome == "successful-substitute";
}

CacheBackend parseCacheBackend(string name)
{
    final switch (name.toLower)
    {
        case "cachix":
            return CacheBackend.cachix;
        case "attic":
            return CacheBackend.attic;
        case "none":
            return CacheBackend.none;
    }
}

string cacheBackendName(CacheBackend backend)
{
    final switch (backend)
    {
        case CacheBackend.cachix:
            return "cachix";
        case CacheBackend.attic:
            return "attic";
        case CacheBackend.none:
            return "none";
    }
}

string defaultSubstituter(CacheBackend backend, string cache)
{
    final switch (backend)
    {
        case CacheBackend.cachix:
            return cache == "" ? "" : "https://" ~ cache ~ ".cachix.org";
        case CacheBackend.attic:
            return "";
        case CacheBackend.none:
            return "";
    }
}

CachePushPlan cachePushPlan(CachePushRequest request)
{
    auto substituters = request.substituters;
    if (substituters.length == 0)
    {
        auto substituter = defaultSubstituter(request.backend, request.cache);
        if (substituter != "")
            substituters ~= substituter;
    }

    final switch (request.backend)
    {
        case CacheBackend.cachix:
            return CachePushPlan(
                commandName: "cachix push",
                argv: ["cachix", "push", request.cache] ~ request.storePaths,
                controller: "cachix",
                substituters: substituters,
                externalCommand: true,
            );
        case CacheBackend.attic:
            return CachePushPlan(
                commandName: "attic push",
                argv: cacheCommandWithTimeout([
                    "attic", "push", "--jobs", "1",
                    "--ignore-upstream-cache-filter", request.cache,
                ] ~ request.storePaths, request.atticPushTimeoutSeconds),
                controller: "attic",
                substituters: substituters,
                externalCommand: true,
            );
        case CacheBackend.none:
            return CachePushPlan(
                commandName: "cache push skipped",
                argv: ["mcl-devops", "cache", "push-closure", "--backend", "none"] ~ request.storePaths,
                controller: "none",
                substituters: substituters,
                externalCommand: false,
            );
    }
}

string[] queryClosurePaths(string rootPath, ProcessRunner runner)
{
    if (runner is null)
        return [rootPath];

    auto result = runner(["nix", "path-info", "--recursive", rootPath]);
    if (!result.succeeded || result.stdout.strip == "")
        return [rootPath];

    auto paths = result.stdout
        .splitLines
        .map!(line => line.strip)
        .array;

    string[] filtered;
    foreach (path; paths)
        if (path != "")
            filtered ~= path;

    return filtered.length == 0 ? [rootPath] : filtered;
}

CacheProbeResult probeCacheSubstitute(
    string path,
    string substituter,
    string[] trustedPublicKeys,
    ProcessRunner runner,
    ulong timeoutSeconds = defaultCacheProbeTimeoutSeconds,
)
{
    auto results = probeCacheSubstitutes([path], substituter, trustedPublicKeys,
        runner, timeoutSeconds);
    return results.length
        ? results[0]
        : CacheProbeResult(path, substituter, "narinfo-missing", 1,
            "no probe result returned");
}

CacheProbeResult[] probeCacheSubstitutes(
    string[] paths,
    string substituter,
    string[] trustedPublicKeys,
    ProcessRunner runner,
    ulong timeoutSeconds = defaultCacheProbeTimeoutSeconds,
)
{
    if (runner is null)
    {
        CacheProbeResult[] results;
        foreach (path; paths)
            results ~= CacheProbeResult(path, substituter, "narinfo-missing", 1,
                "no process runner configured");
        return results;
    }

    if (paths.length == 0)
        return [];

    if (paths.length == 1)
        return probeCacheSubstituteWithRetries(paths[0], substituter,
            trustedPublicKeys, runner, timeoutSeconds);

    auto batch = probeCacheSubstitutesOnce(paths, substituter, trustedPublicKeys,
        runner, timeoutSeconds);
    if (!shouldDegradeBatchProbe(paths, batch))
        return batch;

    CacheProbeResult[] results;
    foreach (path; paths)
        results ~= probeCacheSubstituteWithRetries(path, substituter,
            trustedPublicKeys, runner, timeoutSeconds);
    return results;
}

private CacheProbeResult[] probeCacheSubstituteWithRetries(
    string path,
    string substituter,
    string[] trustedPublicKeys,
    ProcessRunner runner,
    ulong timeoutSeconds,
)
{
    CacheProbeResult[] result;
    foreach (attempt; 1 .. cacheProbeMaxAttempts + 1)
    {
        result = probeCacheSubstitutesOnce([path], substituter, trustedPublicKeys,
            runner, timeoutSeconds);
        if (result.length == 0)
            result ~= CacheProbeResult(path, substituter, "narinfo-missing", 1,
                "no probe result returned");
        if (!isRetryableProbeOutcome(result[0].outcome)
            || attempt == cacheProbeMaxAttempts)
            return result;
        sleepBeforeCacheProbeRetry(attempt);
    }
    return result;
}

private CacheProbeResult[] probeCacheSubstitutesOnce(
    string[] paths,
    string substituter,
    string[] trustedPublicKeys,
    ProcessRunner runner,
    ulong timeoutSeconds,
)
{
    auto pathInfoCommand = [
        "nix", "path-info", "--store", substituter,
    ] ~ paths ~ ["--option", "substituters", ""];
    if (trustedPublicKeys.length)
        pathInfoCommand ~= ["--option", "trusted-public-keys", trustedPublicKeys.join(" ")];

    auto pathInfo = runner(cacheProbeTimeoutCommand(pathInfoCommand, timeoutSeconds));
    auto successfulPaths = successfulProbeOutputPaths(paths, pathInfo.stdout);
    auto failureOutcome = pathInfo.succeeded
        ? "narinfo-missing"
        : (isTimeoutExitCode(pathInfo.exitCode)
            ? "probe-timeout"
            : classifyProbeFailure(pathInfo.stderr));
    auto failureMessage = pathInfo.stderr.stderrSummary;
    if (failureOutcome == "probe-timeout" && failureMessage == "")
        failureMessage = "substitute probe exceeded " ~ timeoutSeconds.to!string ~ "s timeout";
    if (!pathInfo.succeeded && failureOutcome == "narinfo-missing"
        && !hasDisqualifyingMixedProbeFailure(pathInfo.stderr))
    {
        auto missingPaths = missingProbeFailurePaths(paths, pathInfo.stderr);
        if (missingPaths.length)
            foreach (path; paths)
                if (path !in missingPaths)
                    successfulPaths[path] = true;
    }

    // `nix path-info` performs a `HEAD /<hash>.narinfo` against the
    // substituter — this is sufficient evidence that the path is
    // resolvable from that cache. Doing a full `nix copy` to verify
    // (the previous implementation) downloaded every probed path,
    // re-verified its signature, and re-imported into a throwaway local
    // store. On a NixOS system closure that's thousands of paths times
    // dozens of MB; one infra deploy in main observed the probe stuck
    // for 2h24m on a single path (`gnome-settings-daemon`) before being
    // killed. The signature trust check the copy was doing is
    // redundant: every path the deploy targets will have its signature
    // re-verified at install time on the target host. The probe's job
    // is just to answer "is this path available from a trusted cache?"
    // and the narinfo HEAD does that without any download.
    CacheProbeResult[] results;
    foreach (path; paths)
    {
        if (path in successfulPaths)
            results ~= CacheProbeResult(path, substituter, "successful-substitute", 0, "");
        else
            results ~= CacheProbeResult(path, substituter, failureOutcome,
                pathInfo.exitCode, failureMessage);
    }
    return results;
}

private bool shouldDegradeBatchProbe(string[] paths, CacheProbeResult[] results)
{
    if (paths.length <= 1)
        return false;

    bool hasFailure;
    bool hasSuccess;
    bool onlyMissingFailures = true;
    foreach (result; results)
    {
        if (result.successful)
        {
            hasSuccess = true;
            continue;
        }
        if (result.outcome == "probe-timeout")
            return false;
        hasFailure = true;
        if (result.outcome != "narinfo-missing")
            onlyMissingFailures = false;
    }

    if (!hasFailure)
        return false;

    // A mixed result with concrete stdout successes and only missing narinfos
    // already preserves safe coverage. Other aggregate failures can hide
    // successful paths behind one unavailable object or signature problem, so
    // split them into single-path probes. Timeout batches stay batched so
    // pushClosure can try later substituters before retrying only the paths
    // still uncovered by the timed-out cache.
    return !(hasSuccess && onlyMissingFailures);
}

private bool isRetryableProbeOutcome(string outcome)
{
    return outcome == "probe-timeout"
        || outcome == "narinfo-present-object-unavailable";
}

private bool[string] successfulProbeOutputPaths(string[] requestedPaths, string stdout)
{
    bool[string] requested;
    foreach (path; requestedPaths)
        requested[path] = true;

    bool[string] successful;
    foreach (line; stdout.splitLines)
    {
        auto path = line.strip;
        if (path != "" && path in requested)
            successful[path] = true;
    }
    return successful;
}

private bool[string] missingProbeFailurePaths(string[] requestedPaths, string stderr)
{
    bool[string] missing;
    foreach (line; stderr.splitLines)
    {
        if (!isMissingProbeFailureLine(line))
            continue;
        foreach (path; requestedPaths)
            if (line.canFind(path))
                missing[path] = true;
    }
    return missing;
}

private bool isMissingProbeFailureLine(string line)
{
    auto text = line.toLower;
    return text.canFind("404")
        || text.canFind("not found")
        || text.canFind("does not exist")
        || text.canFind("no such file")
        || text.canFind("not valid")
        || text.canFind("not a valid")
        || text.canFind("invalid path")
        || text.canFind("is invalid");
}

private bool hasDisqualifyingMixedProbeFailure(string stderr)
{
    auto text = stderr.toLower;
    return text.canFind("timed out")
        || text.canFind("timeout")
        || text.canFind("lacks a signature")
        || text.canFind("not signed")
        || text.canFind("not trusted")
        || text.canFind("bad signature")
        || text.canFind("signature")
        || text.canFind("nar object")
        || text.canFind("object")
        || text.canFind("unexpected eof")
        || text.canFind("unexpected end")
        || text.canFind("hash mismatch")
        || text.canFind("corrupt");
}

string[] cacheProbeTimeoutCommand(string[] command, ulong timeoutSeconds)
{
    return cacheCommandWithTimeout(command, timeoutSeconds);
}

string[] cacheCommandWithTimeout(string[] command, ulong timeoutSeconds)
{
    return ["timeout", "--kill-after=5s", timeoutSeconds.to!string ~ "s"] ~ command;
}

bool isTimeoutExitCode(int exitCode)
{
    return exitCode == 124 || exitCode == 137 || exitCode == 143
        || exitCode == -9 || exitCode == -15;
}

private ProcessResult runCachePushCommand(
    CachePushPlan plan,
    CacheBackend backend,
    ProcessRunner runProcess,
)
{
    auto result = runProcess(plan.argv);
    if (backend != CacheBackend.attic)
        return result;

    ulong attempt = 1;
    while (!result.succeeded
        && attempt < atticPushMaxAttempts
        && isTransientAtticPushFailure(result))
    {
        sleepBeforeAtticPushRetry(attempt);
        result = runProcess(plan.argv);
        ++attempt;
    }
    return result;
}

private bool isTransientAtticPushFailure(ProcessResult result)
{
    if (result.succeeded)
        return false;
    if (isTimeoutExitCode(result.exitCode))
        return true;

    // A deployment-closure push is IDEMPOTENT and content-addressed: re-pushing
    // paths already present on the cache is a harmless no-op (attic skips them),
    // and the closure is signed/CA so a retry can never publish wrong bytes. So
    // we retry generously — any failure that is plausibly a transient
    // network/server/proxy hiccup rather than a deterministic push error. The
    // narrow original list (only 504/gateway-timeout) let real intermittent
    // failures (502/503/500, 429, connection reset, broken pipe, early EOF, TLS
    // handshake, transient DNS) abort the WHOLE per-host publish loop with no
    // retry, blocking healthy hosts' manifests. See the runners campaign.
    auto output = (result.stdout ~ "\n" ~ result.stderr).toLower;
    static immutable string[] transientMarkers = [
        // Gateway / upstream / server-side 5xx (nginx in front of atticd).
        "http 500", "http 502", "http 503", "http 504",
        "500 internal server error", "502 bad gateway",
        "503 service unavailable", "504 gateway timeout",
        "internalservererror", "bad gateway", "gateway timeout",
        "service unavailable", "upstream timed out",
        "upstream connect error", "no healthy upstream",
        // Rate limiting / backpressure.
        "http 429", "429 too many requests", "too many requests",
        "slow down",
        // Timeouts / deadlines (any layer).
        "deadline exceeded", "connection timed out", "connection pool timed out",
        "timed out", "timeout", "i/o timeout", "operation timed out",
        // Connection churn / mid-transfer drops.
        "connection reset", "reset by peer", "broken pipe",
        "connection refused", "connection closed", "connection aborted",
        "unexpected eof", "early eof", "incomplete", "premature",
        "transfer closed", "empty reply from server", "recv failure",
        "send failure", "remote end closed",
        // TLS / handshake churn.
        "tls handshake", "handshake failed", "handshake timeout",
        "eof occurred in violation", "sslerror", "ssl error",
        // Transient DNS.
        "temporary failure in name resolution", "name resolution",
        "could not resolve host", "no address associated",
        // Generic transport hiccups attic/reqwest surface.
        "network is unreachable", "no route to host",
        "connection error", "request error", "error sending request",
        "channel closed", "stream closed", "hyper::error",
    ];
    foreach (marker; transientMarkers)
        if (output.canFind(marker))
            return true;
    return false;
}

private void sleepBeforeAtticPushRetry(ulong failedAttempt)
{
    version (unittest)
    {
    }
    else
    {
        import core.thread : Thread;
        import core.time : seconds;

        // Graduated backoff: 2s, 5s, 10s, then 20s for any further attempts.
        ulong delay = failedAttempt == 1 ? 2
            : failedAttempt == 2 ? 5
            : failedAttempt == 3 ? 10 : 20;
        Thread.sleep(delay.seconds);
    }
}

private void sleepBeforeCacheProbeRetry(ulong failedAttempt)
{
    version (unittest)
    {
    }
    else
    {
        import core.thread : Thread;
        import core.time : msecs;

        Thread.sleep(failedAttempt == 1 ? 200.msecs : 1000.msecs);
    }
}

string classifyProbeFailure(string stderr)
{
    auto text = stderr.toLower;
    if (text.canFind("lacks a signature") || text.canFind("not signed")
        || text.canFind("not trusted") || text.canFind("bad signature")
        || text.canFind("signature"))
        return "signature-not-trusted";
    if (text.canFind("nar object") || text.canFind("object")
        || text.canFind("unexpected eof") || text.canFind("unexpected end")
        || text.canFind("hash mismatch") || text.canFind("corrupt"))
        return "narinfo-present-object-unavailable";
    if (text.canFind("404") || text.canFind("not found") || text.canFind("does not exist")
        || text.canFind("no such file") || text.canFind("narinfo"))
        return "narinfo-missing";
    return "narinfo-missing";
}

JSONValue cachePushMetadata(
    CachePushRequest request,
    CachePushPlan plan,
    CacheProbeResult[] probes,
    string[] unavailableSubstituters,
)
{
    JSONValue[] probeJson;
    foreach (probe; probes)
    {
        probeJson ~= JSONValue([
            "path": JSONValue(probe.path),
            "substituter": JSONValue(probe.substituter),
            "outcome": JSONValue(probe.outcome),
            "exitCode": JSONValue(cast(long) probe.exitCode),
            "message": JSONValue(probe.message),
        ]);
    }

    auto coverage = probeCoverage(probes);

    JSONValue[string] metadata = [
        "backend": JSONValue(cacheBackendName(request.backend)),
        "controller": JSONValue(plan.controller),
        "coverage": JSONValue([
            "rootPathCount": JSONValue(cast(long) request.storePaths.length),
            "probedPathCount": JSONValue(cast(long) coverage.probedPathCount),
            "probeAttemptCount": JSONValue(cast(long) probes.length),
            "successfulSubstituteCount": JSONValue(cast(long) coverage.successfulPathCount),
            "complete": JSONValue(probes.length > 0 && coverage.complete),
        ]),
        "probeTimeoutSeconds": JSONValue(cast(long) request.probeTimeoutSeconds),
        "probes": JSONValue(probeJson),
    ];

    if (request.backend == CacheBackend.attic)
        metadata["atticPushTimeoutSeconds"] = JSONValue(
            cast(long) request.atticPushTimeoutSeconds);

    if (unavailableSubstituters.length)
        metadata["unavailableSubstituters"] = JSONValue(
            unavailableSubstituters.map!(substituter => JSONValue(substituter)).array);

    if (request.trustedPublicKeys.length)
        metadata["trustedPublicKeys"] = JSONValue(
            request.trustedPublicKeys.map!(key => JSONValue(key)).array);

    return JSONValue(metadata);
}

int pushClosure(CachePushRequest request, ProcessRunner runProcess, ProcessRunner queryProcess)
{
    import std.exception : enforce;

    auto plan = cachePushPlan(request);
    auto queryRunner = queryProcess is null ? runProcess : queryProcess;
    auto context = DeploymentEventContext(
        eventLogPath: request.eventLogPath,
        correlationId: request.correlationId,
        cache: request.cache,
        substituters: plan.substituters,
        system: request.system,
        kind: request.kind,
        transport: request.transport,
        controller: plan.controller,
    );

    Nullable!ClosureSummary closure;
    if (request.storePaths.length)
        closure = queryClosureSummary(request.storePaths[0], queryRunner);

    ProcessResult pushResult = ProcessResult(0, "", "");
    if (plan.externalCommand)
        pushResult = runCachePushCommand(plan, request.backend, runProcess);

    CacheProbeResult[] probes;
    bool[string] timedOutSubstituters;
    string[] timedOutSubstituterList;
    string[] unavailableSubstituterList;
    const missingRequiredSubstituter = pushResult.succeeded
        && request.requireSubstitute
        && plan.substituters.length == 0;

    if (pushResult.succeeded && request.requireSubstitute && plan.substituters.length)
    {
        // A path is considered substitutable if ANY trusted substituter
        // resolves it. Target hosts are configured with multiple substituters
        // (deployment cache + auxiliary caches), so "the closure is resolvable
        // for deploys" -- not "every path lives on the primary cache" -- is what
        // matters. Batch each substituter over the still-uncovered closure paths
        // and record one metadata row per requested path so failure events can
        // explain timeouts and later misses.
        foreach (root; request.storePaths)
        {
            auto remaining = uniquePaths(queryClosurePaths(root, queryRunner));
            bool[string] attempted;
            foreach (substituter; plan.substituters)
            {
                if (remaining.length == 0)
                    break;
                if (substituter in timedOutSubstituters)
                    continue;

                auto batch = probeCacheSubstitutes(remaining, substituter,
                    request.trustedPublicKeys, queryRunner,
                    request.probeTimeoutSeconds);
                probes ~= batch;

                bool timedOut;
                bool[string] covered;
                foreach (probe; batch)
                {
                    attempted[probe.path] = true;
                    if (probe.outcome == "probe-timeout")
                        timedOut = true;
                    if (probe.successful)
                        covered[probe.path] = true;
                }
                remaining = pathsNotIn(remaining, covered);
                if (timedOut)
                {
                    timedOutSubstituters[substituter] = true;
                    appendUnique(timedOutSubstituterList, substituter);
                }
            }

            if (remaining.length && timedOutSubstituterList.length)
            {
                foreach (substituter; timedOutSubstituterList)
                {
                    if (remaining.length == 0)
                        break;

                    bool retryTimedOut;
                    bool[string] covered;
                    foreach (path; remaining)
                    {
                        auto retry = probeCacheSubstitute(path, substituter,
                            request.trustedPublicKeys, queryRunner,
                            request.probeTimeoutSeconds);
                        probes ~= retry;
                        attempted[retry.path] = true;
                        if (retry.outcome == "probe-timeout")
                            retryTimedOut = true;
                        if (retry.successful)
                            covered[retry.path] = true;
                    }
                    remaining = pathsNotIn(remaining, covered);
                    if (retryTimedOut)
                        appendUnique(unavailableSubstituterList, substituter);
                }
            }
            foreach (path; remaining)
                if (path !in attempted)
                    probes ~= CacheProbeResult(path, "", "substituter-unavailable", 1,
                        "no available substituter covered path");
        }
    }

    const probeFailed = probes.length > 0 && !probeCoverage(probes).complete;
    const substituteCheckFailed = missingRequiredSubstituter || probeFailed;
    const status = substituteCheckFailed
        ? "failed"
        : (plan.externalCommand ? (pushResult.succeeded ? "succeeded" : "failed") : "skipped");
    const exitCode = pushResult.succeeded && substituteCheckFailed ? 1 : pushResult.exitCode;
    const errorMessage = !pushResult.succeeded
        ? "Cache push failed"
        : (missingRequiredSubstituter
            ? "Cache substitute integrity probe requires at least one substituter"
            : (probeFailed ? "Cache substitute integrity probe failed" : ""));
    const errorCode = !pushResult.succeeded ? "cache_push_failed" : "cache_probe_failed";
    const errorDetails = !pushResult.succeeded
        ? pushResult.stderr.stderrSummary
        : (missingRequiredSubstituter
            ? "No substituter was configured for --require-substitute"
            : probeFailureSummary(probes));

    foreach (root; request.storePaths)
        appendDeploymentEvent(request.eventLogPath, deploymentEventJson(
            context,
            "cache-push",
            request.target,
            root,
            plan.commandName,
            plan.argv,
            status,
            exitCode,
            closure,
            errorMessage,
            errorCode,
            errorDetails,
            cachePushMetadata(request, plan, probes, unavailableSubstituterList).object,
        ));

    enforce(status != "failed", errorMessage == "" ? "Cache push failed" : errorMessage);
    return 0;
}

string probeFailureSummary(CacheProbeResult[] probes)
{
    string failedPath;
    auto successfulPaths = successfulProbePaths(probes);
    foreach (probe; probes)
        if (!probe.successful && (probe.path !in successfulPaths))
        {
            failedPath = probe.path;
            break;
        }
    if (failedPath == "")
        return "";

    string[] attempts;
    foreach (probe; probes)
        if (probe.path == failedPath && !probe.successful)
            attempts ~= probeAttemptSummary(probe);

    return failedPath ~ ": no substituter succeeded (" ~ attempts.join("; ") ~ ")";
}

private struct ProbeCoverage
{
    ulong probedPathCount;
    ulong successfulPathCount;
    bool complete;
}

private ProbeCoverage probeCoverage(CacheProbeResult[] probes)
{
    bool[string] probedPaths;
    auto successfulPaths = successfulProbePaths(probes);

    foreach (probe; probes)
        probedPaths[probe.path] = true;

    bool complete = probes.length > 0;
    foreach (path, _; probedPaths)
        if (path !in successfulPaths)
            complete = false;

    return ProbeCoverage(
        probedPathCount: cast(ulong) probedPaths.length,
        successfulPathCount: cast(ulong) successfulPaths.length,
        complete: complete,
    );
}

private string[] uniquePaths(string[] paths)
{
    bool[string] seen;
    string[] result;
    foreach (path; paths)
    {
        if (path in seen)
            continue;
        seen[path] = true;
        result ~= path;
    }
    return result;
}

private string[] pathsNotIn(string[] paths, bool[string] excluded)
{
    string[] result;
    foreach (path; paths)
        if (path !in excluded)
            result ~= path;
    return result;
}

private void appendUnique(ref string[] values, string value)
{
    foreach (existing; values)
        if (existing == value)
            return;
    values ~= value;
}

private bool[string] successfulProbePaths(CacheProbeResult[] probes)
{
    bool[string] paths;
    foreach (probe; probes)
        if (probe.successful)
            paths[probe.path] = true;
    return paths;
}

private string probeAttemptSummary(CacheProbeResult probe)
{
    auto substituter = probe.substituter == "" ? "<none>" : probe.substituter;
    return substituter ~ ": " ~ probe.outcome ~
        (probe.message == "" ? "" : ": " ~ probe.message);
}

version (unittest)
private string probeCommandStorePathStdout(string[] command)
{
    string[] paths;
    foreach (arg; command)
        if (arg.canFind("/nix/store/"))
            paths ~= arg;
    return paths.join("\n") ~ (paths.length ? "\n" : "");
}

version (unittest)
private bool isCommandInvocation(string[] command, string executable, string subcommand)
{
    foreach (i, arg; command)
        if (arg == executable && i + 1 < command.length && command[i + 1] == subcommand)
            return true;
    return false;
}

@("test_cache_push_closure_invokes_backend")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : any, filter;

    auto eventLog = deleteme ~ ".cache-push.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root\n", "");
        if (command.canFind("--store"))
            return ProcessResult(0, "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root\n", "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "copy")
            return ProcessResult(0, "", "");
        return ProcessResult(0, "", "");
    }

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.cachix,
        cache: "example-cache",
        storePaths: [root],
        target: "app-server-01",
        substituters: ["https://example-cache.cachix.org"],
        eventLogPath: eventLog,
    ), &fakeRunner, &fakeRunner) == 0);

    assert(commands.any!(cmd => cmd == ["cachix", "push", "example-cache", root]));

    commands.length = 0;
    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.attic,
        cache: "example-deploy-cache",
        storePaths: [root],
        target: "app-server-01",
        substituters: ["https://cache.example/example-deploy-cache"],
        eventLogPath: eventLog,
    ), &fakeRunner, &fakeRunner) == 0);

    assert(commands.any!(cmd => cmd == [
        "timeout", "--kill-after=5s", defaultAtticPushTimeoutSeconds.to!string ~ "s",
        "attic", "push", "--jobs", "1",
        "--ignore-upstream-cache-filter", "example-deploy-cache", root,
    ]));

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 2);
    assert(events[0]["backend"]["controller"].str == "cachix");
    assert(events[1]["backend"]["controller"].str == "attic");
    assert(events[1]["metadata"]["coverage"]["complete"].boolean);
    assert(events[1]["metadata"]["probes"][0]["outcome"].str == "successful-substitute");
}

@("test_attic_push_retries_transient_gateway_timeout_and_succeeds")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".attic-push-retry-success.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    string[][] commands;
    ulong atticPushes;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        if (isCommandInvocation(command, "attic", "push"))
        {
            ++atticPushes;
            return atticPushes == 1
                ? ProcessResult(1, "", "HTTP 504 Gateway Timeout\n<html>nginx</html>")
                : ProcessResult(0, "", "");
        }
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n", "");
        if (command.canFind("--store"))
            return ProcessResult(0, root ~ "\n", "");
        return ProcessResult(0, "", "");
    }

    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.attic,
        cache: "example-deploy-cache",
        storePaths: [root],
        substituters: ["https://cache.example/example-deploy-cache"],
        eventLogPath: eventLog,
    ), &fakeRunner, &fakeRunner) == 0);

    assert(atticPushes == 2);
    assert(commands[1] == [
        "timeout", "--kill-after=5s", defaultAtticPushTimeoutSeconds.to!string ~ "s",
        "attic", "push", "--jobs", "1",
        "--ignore-upstream-cache-filter", "example-deploy-cache", root,
    ]);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 1);
    assert(events[0]["command"]["status"].str == "succeeded");
    assert(events[0]["metadata"]["coverage"]["complete"].boolean);
}

@("test_attic_push_retries_timeout_exit_and_succeeds")
unittest
{
    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    ulong atticPushes;
    ProcessResult fakeRunner(string[] command)
    {
        if (isCommandInvocation(command, "attic", "push"))
        {
            ++atticPushes;
            return atticPushes == 1
                ? ProcessResult(124, "", "")
                : ProcessResult(0, "", "");
        }
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n", "");
        if (command.canFind("--store"))
            return ProcessResult(0, root ~ "\n", "");
        return ProcessResult(0, "", "");
    }

    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.attic,
        cache: "example-deploy-cache",
        storePaths: [root],
        substituters: ["https://cache.example/example-deploy-cache"],
    ), &fakeRunner, &fakeRunner) == 0);

    assert(atticPushes == 2);
}

@("test_attic_push_retries_broadened_transient_errors_and_succeeds")
unittest
{
    // Each of these transient failure signatures used to abort with NO retry
    // (only 504/gateway-timeout was recognised); now they retry and succeed.
    static immutable string[] transientStderrs = [
        "error: HTTP 502 Bad Gateway",
        "error: HTTP 503 Service Unavailable",
        "error: unexpected EOF during handshake",
        "error: connection reset by peer",
        "error: HTTP 429 Too Many Requests",
        "error: broken pipe while uploading nar",
        "error: temporary failure in name resolution",
    ];
    foreach (stderr; transientStderrs)
    {
        auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
        ulong atticPushes;
        ProcessResult fakeRunner(string[] command)
        {
            if (isCommandInvocation(command, "attic", "push"))
            {
                ++atticPushes;
                return atticPushes == 1 ? ProcessResult(1, "", stderr) : ProcessResult(0, "", "");
            }
            if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
                && command.canFind("--json"))
                return ProcessResult(0,
                    `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
            if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
                && command.canFind("--recursive"))
                return ProcessResult(0, root ~ "\n", "");
            if (command.canFind("--store"))
                return ProcessResult(0, root ~ "\n", "");
            return ProcessResult(0, "", "");
        }

        assert(pushClosure(CachePushRequest(
            backend: CacheBackend.attic,
            cache: "example-deploy-cache",
            storePaths: [root],
            substituters: ["https://cache.example/example-deploy-cache"],
        ), &fakeRunner, &fakeRunner) == 0, "should retry+succeed for: " ~ stderr);
        assert(atticPushes == 2, "expected exactly one retry for: " ~ stderr);
    }
}

@("test_attic_push_does_not_retry_permanent_auth_failure")
unittest
{
    import std.file : deleteme, remove;

    auto eventLog = deleteme ~ ".attic-push-permanent.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    // A deterministic auth/permission failure (403 Forbidden) is NOT transient:
    // retrying is pointless, so the push fails after a single attempt.
    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    ulong atticPushes;
    ProcessResult fakeRunner(string[] command)
    {
        if (isCommandInvocation(command, "attic", "push"))
        {
            ++atticPushes;
            return ProcessResult(1, "", "error: HTTP 403 Forbidden: invalid token");
        }
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n", "");
        if (command.canFind("--store"))
            return ProcessResult(0, root ~ "\n", "");
        return ProcessResult(0, "", "");
    }

    bool threw;
    try
        pushClosure(CachePushRequest(
            backend: CacheBackend.attic,
            cache: "example-deploy-cache",
            storePaths: [root],
            substituters: ["https://cache.example/example-deploy-cache"],
            eventLogPath: eventLog,
        ), &fakeRunner, &fakeRunner);
    catch (Exception e)
        threw = true;
    assert(threw);
    assert(atticPushes == 1, "permanent 403 must not be retried");
}

@("test_attic_push_uses_configured_timeout")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".attic-push-timeout-config.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n", "");
        if (command.canFind("--store"))
            return ProcessResult(0, root ~ "\n", "");
        return ProcessResult(0, "", "");
    }

    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.attic,
        cache: "example-deploy-cache",
        storePaths: [root],
        substituters: ["https://cache.example/example-deploy-cache"],
        eventLogPath: eventLog,
        atticPushTimeoutSeconds: 42,
    ), &fakeRunner, &fakeRunner) == 0);

    assert(commands[1] == [
        "timeout", "--kill-after=5s", "42s",
        "attic", "push", "--jobs", "1",
        "--ignore-upstream-cache-filter", "example-deploy-cache", root,
    ]);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 1);
    assert(events[0]["metadata"]["atticPushTimeoutSeconds"].integer == 42);
}

@("test_attic_push_transient_gateway_timeout_stops_after_bounded_retries")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".attic-push-retry-failure.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    ulong atticPushes;
    ProcessResult fakeRunner(string[] command)
    {
        if (isCommandInvocation(command, "attic", "push"))
        {
            ++atticPushes;
            return ProcessResult(1, "", "HTTP 504 Gateway Timeout\n<html>nginx</html>");
        }
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        return ProcessResult(0, "", "");
    }

    bool threw;
    try
    {
        pushClosure(CachePushRequest(
            backend: CacheBackend.attic,
            cache: "example-deploy-cache",
            storePaths: [root],
            substituters: ["https://cache.example/example-deploy-cache"],
            eventLogPath: eventLog,
        ), &fakeRunner, &fakeRunner);
    }
    catch (Exception e)
    {
        threw = true;
        assert(e.msg == "Cache push failed");
    }
    assert(threw);
    assert(atticPushes == atticPushMaxAttempts);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 1);
    assert(events[0]["command"]["status"].str == "failed");
    assert(events[0]["error"]["details"]["stderrSummary"].str.canFind("HTTP 504 Gateway Timeout"));
}

@("test_attic_push_non_transient_failure_does_not_retry")
unittest
{
    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    ulong atticPushes;
    ProcessResult fakeRunner(string[] command)
    {
        if (isCommandInvocation(command, "attic", "push"))
        {
            ++atticPushes;
            return ProcessResult(1, "", "error: cache does not exist");
        }
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        return ProcessResult(0, "", "");
    }

    bool threw;
    try
    {
        pushClosure(CachePushRequest(
            backend: CacheBackend.attic,
            cache: "missing-cache",
            storePaths: [root],
            substituters: ["https://cache.example/missing-cache"],
        ), &fakeRunner, &fakeRunner);
    }
    catch (Exception e)
    {
        threw = true;
        assert(e.msg == "Cache push failed");
    }
    assert(threw);
    assert(atticPushes == 1);
}

@("test_attic_push_retries_database_pool_timeout")
unittest
{
    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    ulong atticPushes;
    ProcessResult fakeRunner(string[] command)
    {
        if (isCommandInvocation(command, "attic", "push"))
        {
            ++atticPushes;
            return atticPushes == 1
                ? ProcessResult(1, "",
                    "InternalServerError: Database error: Failed to acquire connection from pool: Connection pool timed out")
                : ProcessResult(0, "", "");
        }
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n", "");
        if (command.canFind("--store"))
            return ProcessResult(0, root ~ "\n", "");
        return ProcessResult(0, "", "");
    }

    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.attic,
        cache: "example-deploy-cache",
        storePaths: [root],
        substituters: ["https://cache.example/example-deploy-cache"],
    ), &fakeRunner, &fakeRunner) == 0);

    assert(atticPushes == 2);
}

@("test_attic_push_retries_visible_internal_server_error")
unittest
{
    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    ulong atticPushes;
    ProcessResult fakeRunner(string[] command)
    {
        if (isCommandInvocation(command, "attic", "push"))
        {
            ++atticPushes;
            return atticPushes == 1
                ? ProcessResult(1, "",
                    "InternalServerError: The server encountered an internal error or misconfiguration.")
                : ProcessResult(0, "", "");
        }
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n", "");
        if (command.canFind("--store"))
            return ProcessResult(0, root ~ "\n", "");
        return ProcessResult(0, "", "");
    }

    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.attic,
        cache: "example-deploy-cache",
        storePaths: [root],
        substituters: ["https://cache.example/example-deploy-cache"],
    ), &fakeRunner, &fakeRunner) == 0);

    assert(atticPushes == 2);
}

@("test_cachix_push_failure_does_not_retry")
unittest
{
    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    ulong cachixPushes;
    ProcessResult fakeRunner(string[] command)
    {
        if (command.length >= 2 && command[0] == "cachix" && command[1] == "push")
        {
            ++cachixPushes;
            return ProcessResult(1, "", "HTTP 504 Gateway Timeout");
        }
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        return ProcessResult(0, "", "");
    }

    bool threw;
    try
    {
        pushClosure(CachePushRequest(
            backend: CacheBackend.cachix,
            cache: "example-cache",
            storePaths: [root],
            substituters: ["https://example-cache.cachix.org"],
        ), &fakeRunner, &fakeRunner);
    }
    catch (Exception e)
    {
        threw = true;
        assert(e.msg == "Cache push failed");
    }
    assert(threw);
    assert(cachixPushes == 1);
}

@("test_cache_probe_wraps_path_info_with_timeout")
unittest
{
    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        return ProcessResult(0, root ~ "\n", "");
    }

    auto result = probeCacheSubstitute(root, "https://cache.example",
        ["cache.example-1:abc"], &fakeRunner, 7);

    assert(result.successful);
    assert(commands.length == 1);
    assert(commands[0] == [
        "timeout", "--kill-after=5s", "7s",
        "nix", "path-info", "--store", "https://cache.example", root,
        "--option", "substituters", "",
        "--option", "trusted-public-keys", "cache.example-1:abc",
    ]);
}

@("test_cache_probe_ambiguous_batch_degrades_to_per_path_success")
unittest
{
    auto pathA = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-present-a";
    auto pathB = "/nix/store/11111111111111111111111111111111-present-b";
    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        if (command.canFind(pathA) && command.canFind(pathB))
            return ProcessResult(1, "",
                "error: don't know how to build these paths:\n"
                ~ "  " ~ pathA ~ "\n"
                ~ "  " ~ pathB ~ "\n");
        if (command.canFind(pathA))
            return ProcessResult(0, pathA ~ "\n", "");
        if (command.canFind(pathB))
            return ProcessResult(0, pathB ~ "\n", "");
        return ProcessResult(0, "", "");
    }

    auto results = probeCacheSubstitutes([pathA, pathB],
        "https://cache.example", [], &fakeRunner, 7);

    assert(results.length == 2);
    assert(results[0].path == pathA);
    assert(results[0].outcome == "successful-substitute");
    assert(results[1].path == pathB);
    assert(results[1].outcome == "successful-substitute");
    assert(commands.length == 3);
}

@("test_cache_probe_batch_timeout_stays_batched_for_deferred_retry")
unittest
{
    auto pathA = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-present-a";
    auto pathB = "/nix/store/11111111111111111111111111111111-present-b";
    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        return ProcessResult(124, "", "");
    }

    auto results = probeCacheSubstitutes([pathA, pathB],
        "https://cache.example", [], &fakeRunner, 7);

    assert(results.length == 2);
    assert(results[0].path == pathA);
    assert(results[0].outcome == "probe-timeout");
    assert(results[1].path == pathB);
    assert(results[1].outcome == "probe-timeout");
    assert(commands.length == 1);
}

@("test_cache_probe_transient_object_unavailable_retries_to_success")
unittest
{
    auto path = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-eventual";
    ulong attempts;
    ProcessResult fakeRunner(string[] command)
    {
        if (command.canFind("--store") && command.canFind("https://cache.example"))
        {
            ++attempts;
            return attempts < cacheProbeMaxAttempts
                ? ProcessResult(1, "", "error: cannot download NAR object from binary cache\n")
                : ProcessResult(0, path ~ "\n", "");
        }
        return ProcessResult(0, "", "");
    }

    auto result = probeCacheSubstitute(path, "https://cache.example",
        [], &fakeRunner, 7);

    assert(result.outcome == "successful-substitute");
    assert(attempts == cacheProbeMaxAttempts);
}

@("test_cache_probe_permanent_object_unavailable_stops_after_bounded_retries")
unittest
{
    auto path = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-unavailable";
    ulong attempts;
    ProcessResult fakeRunner(string[] command)
    {
        if (command.canFind("--store") && command.canFind("https://cache.example"))
        {
            ++attempts;
            return ProcessResult(1, "", "error: cannot download NAR object from binary cache\n");
        }
        return ProcessResult(0, "", "");
    }

    auto result = probeCacheSubstitute(path, "https://cache.example",
        [], &fakeRunner, 7);

    assert(result.outcome == "narinfo-present-object-unavailable");
    assert(attempts == cacheProbeMaxAttempts);
}

@("test_cache_probe_transient_timeout_retries_to_success")
unittest
{
    auto path = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-eventual-timeout";
    ulong attempts;
    ProcessResult fakeRunner(string[] command)
    {
        if (command.canFind("--store") && command.canFind("https://cache.example"))
        {
            ++attempts;
            return attempts < cacheProbeMaxAttempts
                ? ProcessResult(124, "", "")
                : ProcessResult(0, path ~ "\n", "");
        }
        return ProcessResult(0, "", "");
    }

    auto result = probeCacheSubstitute(path, "https://cache.example",
        [], &fakeRunner, 7);

    assert(result.outcome == "successful-substitute");
    assert(attempts == cacheProbeMaxAttempts);
}

@("test_cache_probe_permanent_timeout_stops_after_bounded_retries")
unittest
{
    auto path = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-timeout";
    ulong attempts;
    ProcessResult fakeRunner(string[] command)
    {
        if (command.canFind("--store") && command.canFind("https://cache.example"))
        {
            ++attempts;
            return ProcessResult(124, "", "");
        }
        return ProcessResult(0, "", "");
    }

    auto result = probeCacheSubstitute(path, "https://cache.example",
        [], &fakeRunner, 7);

    assert(result.outcome == "probe-timeout");
    assert(attempts == cacheProbeMaxAttempts);
}

@("test_cache_probe_permanent_missing_and_signature_failures_not_masked")
unittest
{
    auto present = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-present";
    auto missing = "/nix/store/11111111111111111111111111111111-missing";
    auto unsigned = "/nix/store/22222222222222222222222222222222-unsigned";
    ulong attempts;
    ProcessResult fakeRunner(string[] command)
    {
        if (command.canFind("--store") && command.canFind("https://cache.example"))
            ++attempts;
        if (command.canFind(present) && command.canFind(missing)
            && command.canFind(unsigned))
            return ProcessResult(1, "",
                "error: don't know how to build these paths:\n"
                ~ "  " ~ present ~ "\n"
                ~ "  " ~ missing ~ "\n"
                ~ "  " ~ unsigned ~ "\n");
        if (command.canFind(present))
            return ProcessResult(0, present ~ "\n", "");
        if (command.canFind(missing))
            return ProcessResult(1, "",
                "error: path '" ~ missing
                ~ "' does not exist in binary cache 'https://cache.example'\n");
        if (command.canFind(unsigned))
            return ProcessResult(1, "", "error: path is not signed by a trusted key\n");
        return ProcessResult(0, "", "");
    }

    auto results = probeCacheSubstitutes([present, missing, unsigned],
        "https://cache.example", [], &fakeRunner, 7);

    assert(results.length == 3);
    assert(results[0].outcome == "successful-substitute");
    assert(results[1].outcome == "narinfo-missing");
    assert(results[2].outcome == "signature-not-trusted");
    assert(attempts == 4);
}

@("test_cache_probe_mixed_missing_batch_counts_unmentioned_paths")
unittest
{
    auto presentA = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-present-a";
    auto presentB = "/nix/store/11111111111111111111111111111111-present-b";
    auto missing = "/nix/store/22222222222222222222222222222222-missing";
    ProcessResult fakeRunner(string[] command)
    {
        return ProcessResult(1, "",
            "error: path '" ~ missing ~ "' does not exist in binary cache 'https://cache.example'\n");
    }

    auto results = probeCacheSubstitutes([presentA, missing, presentB],
        "https://cache.example", [], &fakeRunner, 7);

    assert(results.length == 3);
    assert(results[0].path == presentA);
    assert(results[0].outcome == "successful-substitute");
    assert(results[1].path == missing);
    assert(results[1].outcome == "narinfo-missing");
    assert(results[2].path == presentB);
    assert(results[2].outcome == "successful-substitute");
}

@("test_cache_probe_mixed_missing_batch_requires_named_missing_path")
unittest
{
    auto present = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-present";
    auto maybeMissing = "/nix/store/11111111111111111111111111111111-maybe-missing";
    ProcessResult fakeRunner(string[] command)
    {
        return ProcessResult(1, "", "404 Not Found\n");
    }

    auto results = probeCacheSubstitutes([present, maybeMissing],
        "https://cache.example", [], &fakeRunner, 7);

    assert(results.length == 2);
    assert(results[0].outcome == "narinfo-missing");
    assert(results[1].outcome == "narinfo-missing");
}

@("test_cache_probe_mixed_missing_batch_does_not_mask_integrity_failures")
unittest
{
    auto present = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-present";
    auto missing = "/nix/store/11111111111111111111111111111111-missing";
    ProcessResult fakeRunner(string[] command)
    {
        return ProcessResult(1, "",
            "error: path '" ~ missing ~ "' does not exist in binary cache 'https://cache.example'\n"
            ~ "error: cannot download NAR object from binary cache\n");
    }

    auto results = probeCacheSubstitutes([present, missing],
        "https://cache.example", [], &fakeRunner, 7);

    assert(results.length == 2);
    assert(results[0].outcome == "narinfo-present-object-unavailable");
    assert(results[1].outcome == "narinfo-present-object-unavailable");
}

@("test_cache_probe_mixed_missing_batch_does_not_mask_signature_failures")
unittest
{
    auto present = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-present";
    auto missing = "/nix/store/11111111111111111111111111111111-missing";
    ProcessResult fakeRunner(string[] command)
    {
        return ProcessResult(1, "",
            "error: path '" ~ missing ~ "' does not exist in binary cache 'https://cache.example'\n"
            ~ "error: path is not signed by a trusted key\n");
    }

    auto results = probeCacheSubstitutes([present, missing],
        "https://cache.example", [], &fakeRunner, 7);

    assert(results.length == 2);
    assert(results[0].outcome == "signature-not-trusted");
    assert(results[1].outcome == "signature-not-trusted");
}

@("test_cache_probe_mixed_missing_batch_does_not_mask_timeouts")
unittest
{
    auto present = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-present";
    auto missing = "/nix/store/11111111111111111111111111111111-missing";
    ProcessResult fakeRunner(string[] command)
    {
        return ProcessResult(-9, "",
            "error: path '" ~ missing ~ "' does not exist in binary cache 'https://cache.example'\n");
    }

    auto results = probeCacheSubstitutes([present, missing],
        "https://cache.example", [], &fakeRunner, 7);

    assert(results.length == 2);
    assert(results[0].outcome == "probe-timeout");
    assert(results[1].outcome == "probe-timeout");
}

@("test_cache_probe_mixed_missing_batch_does_not_mask_timeout_stderr")
unittest
{
    auto present = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-present";
    auto missing = "/nix/store/11111111111111111111111111111111-missing";
    ProcessResult fakeRunner(string[] command)
    {
        return ProcessResult(1, "",
            "error: path '" ~ missing ~ "' does not exist in binary cache 'https://cache.example'\n"
            ~ "error: request timed out while probing cache\n");
    }

    auto results = probeCacheSubstitutes([present, missing],
        "https://cache.example", [], &fakeRunner, 7);

    assert(results.length == 2);
    assert(results[0].outcome == "narinfo-missing");
    assert(results[1].outcome == "narinfo-missing");
}

@("test_cache_probe_timeout_command_executes_inner_command")
unittest
{
    import mcl.utils.process : runProcessCapture;

    auto result = runProcessCapture(
        cacheProbeTimeoutCommand(["sh", "-c", "printf probe-ok"], 1));

    assert(result.exitCode == 0);
    assert(result.stdout == "probe-ok");
}

@("test_cache_push_closure_batches_probe_commands")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".cache-push-batch-probes.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    auto depA = "/nix/store/11111111111111111111111111111111-dep-a";
    auto depB = "/nix/store/22222222222222222222222222222222-dep-b";
    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n" ~ depA ~ "\n" ~ depB ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://cache.example"))
            return ProcessResult(0, probeCommandStorePathStdout(command), "");
        return ProcessResult(0, "", "");
    }

    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.cachix,
        cache: "example-cache",
        storePaths: [root],
        substituters: ["https://cache.example"],
        eventLogPath: eventLog,
    ), &fakeRunner, &fakeRunner) == 0);

    ulong probeCommandCount;
    foreach (command; commands)
        if (command.canFind("--store") && command.canFind("https://cache.example"))
            ++probeCommandCount;

    assert(probeCommandCount == 1);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 1);
    assert(events[0]["metadata"]["coverage"]["probeAttemptCount"].integer == 3);
    assert(events[0]["metadata"]["coverage"]["successfulSubstituteCount"].integer == 3);
}

@("test_cache_probe_timeout_continues_to_later_substituter")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : any, filter;

    auto eventLog = deleteme ~ ".cache-push-timeout-success.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0, `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://slow.example"))
            return ProcessResult(124, "", "");
        if (command.canFind("--store") && command.canFind("https://good.example"))
            return ProcessResult(0, root ~ "\n", "");
        return ProcessResult(0, "", "");
    }

    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.cachix,
        cache: "example-cache",
        storePaths: [root],
        substituters: ["https://slow.example", "https://good.example"],
        eventLogPath: eventLog,
        probeTimeoutSeconds: 3,
    ), &fakeRunner, &fakeRunner) == 0);

    assert(commands.any!(cmd => cmd.canFind("3s") && cmd.canFind("https://slow.example")));
    assert(commands.any!(cmd => cmd.canFind("3s") && cmd.canFind("https://good.example")));

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 1);
    assert(events[0]["command"]["status"].str == "succeeded");
    assert(events[0]["metadata"]["coverage"]["complete"].boolean);
    assert(events[0]["metadata"]["coverage"]["probeAttemptCount"].integer == 2);
    assert(events[0]["metadata"]["probes"][0]["outcome"].str == "probe-timeout");
    assert(events[0]["metadata"]["probes"][1]["outcome"].str == "successful-substitute");
}

@("test_cache_probe_timeout_retries_uncovered_paths_against_timed_out_substituter")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".cache-push-timeout-leftover-success.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    auto publicDepA = "/nix/store/11111111111111111111111111111111-public-a";
    auto publicDepB = "/nix/store/22222222222222222222222222222222-public-b";
    auto deployDep = "/nix/store/33333333333333333333333333333333-deploy-specific";
    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0,
                root ~ "\n" ~ publicDepA ~ "\n" ~ publicDepB ~ "\n" ~ deployDep ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://deploy.example")
            && command.canFind(publicDepA))
            return ProcessResult(124, "", "");
        if (command.canFind("--store") && command.canFind("https://deploy.example"))
            return ProcessResult(0, deployDep ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://cache.nixos.org"))
            return ProcessResult(1, root ~ "\n" ~ publicDepA ~ "\n" ~ publicDepB ~ "\n",
                "error: path '" ~ deployDep
                ~ "' does not exist in binary cache 'https://cache.nixos.org'\n");
        return ProcessResult(0, "", "");
    }

    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.cachix,
        cache: "example-cache",
        storePaths: [root],
        substituters: ["https://deploy.example", "https://cache.nixos.org"],
        eventLogPath: eventLog,
        probeTimeoutSeconds: 3,
    ), &fakeRunner, &fakeRunner) == 0);

    ulong deployProbeCount;
    foreach (command; commands)
        if (command.canFind("--store") && command.canFind("https://deploy.example"))
            ++deployProbeCount;
    assert(deployProbeCount == 2);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 1);
    assert(events[0]["command"]["status"].str == "succeeded");
    assert(events[0]["metadata"]["coverage"]["complete"].boolean);
    assert(events[0]["metadata"]["coverage"]["probeAttemptCount"].integer == 9);
    assert("unavailableSubstituters" !in events[0]["metadata"].object);
    assert(events[0]["metadata"]["probes"][0]["outcome"].str == "probe-timeout");
    assert(events[0]["metadata"]["probes"][7]["path"].str == deployDep);
    assert(events[0]["metadata"]["probes"][7]["substituter"].str == "https://cache.nixos.org");
    assert(events[0]["metadata"]["probes"][7]["outcome"].str == "narinfo-missing");
    assert(events[0]["metadata"]["probes"][8]["path"].str == deployDep);
    assert(events[0]["metadata"]["probes"][8]["substituter"].str == "https://deploy.example");
    assert(events[0]["metadata"]["probes"][8]["outcome"].str == "successful-substitute");
}

@("test_cache_probe_timeout_retry_missing_keeps_full_closure_failure")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".cache-push-timeout-leftover-missing.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    auto publicDep = "/nix/store/11111111111111111111111111111111-public";
    auto deployDep = "/nix/store/22222222222222222222222222222222-deploy-specific";
    ProcessResult fakeRunner(string[] command)
    {
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n" ~ publicDep ~ "\n" ~ deployDep ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://deploy.example")
            && command.canFind(publicDep))
            return ProcessResult(124, "", "");
        if (command.canFind("--store") && command.canFind("https://deploy.example"))
            return ProcessResult(1, "",
                "error: path '" ~ deployDep
                ~ "' does not exist in binary cache 'https://deploy.example'\n");
        if (command.canFind("--store") && command.canFind("https://cache.nixos.org"))
            return ProcessResult(1, root ~ "\n" ~ publicDep ~ "\n",
                "error: path '" ~ deployDep
                ~ "' does not exist in binary cache 'https://cache.nixos.org'\n");
        return ProcessResult(0, "", "");
    }

    bool threw;
    try
    {
        pushClosure(CachePushRequest(
            backend: CacheBackend.cachix,
            cache: "example-cache",
            storePaths: [root],
            substituters: ["https://deploy.example", "https://cache.nixos.org"],
            eventLogPath: eventLog,
            probeTimeoutSeconds: 3,
        ), &fakeRunner, &fakeRunner);
    }
    catch (Exception e)
    {
        threw = true;
        assert(e.msg == "Cache substitute integrity probe failed");
    }
    assert(threw);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 1);
    assert(events[0]["command"]["status"].str == "failed");
    assert(events[0]["metadata"]["coverage"]["complete"].boolean == false);
    assert(events[0]["metadata"]["coverage"]["successfulSubstituteCount"].integer == 2);
    assert(events[0]["metadata"]["coverage"]["probeAttemptCount"].integer == 7);
    assert(events[0]["error"]["details"]["stderrSummary"].str.canFind(deployDep));
    assert(events[0]["metadata"]["probes"][6]["path"].str == deployDep);
    assert(events[0]["metadata"]["probes"][6]["substituter"].str == "https://deploy.example");
    assert(events[0]["metadata"]["probes"][6]["outcome"].str == "narinfo-missing");
}

@("test_cache_probe_timeout_retry_does_not_mask_signature_failure")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".cache-push-timeout-leftover-signature.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    auto publicDep = "/nix/store/11111111111111111111111111111111-public";
    auto deployDep = "/nix/store/22222222222222222222222222222222-deploy-specific";
    ProcessResult fakeRunner(string[] command)
    {
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n" ~ publicDep ~ "\n" ~ deployDep ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://deploy.example")
            && command.canFind(publicDep))
            return ProcessResult(124, "", "");
        if (command.canFind("--store") && command.canFind("https://deploy.example"))
            return ProcessResult(1, "", "error: path is not signed by a trusted key\n");
        if (command.canFind("--store") && command.canFind("https://cache.nixos.org"))
            return ProcessResult(1, root ~ "\n" ~ publicDep ~ "\n",
                "error: path '" ~ deployDep
                ~ "' does not exist in binary cache 'https://cache.nixos.org'\n");
        return ProcessResult(0, "", "");
    }

    bool threw;
    try
    {
        pushClosure(CachePushRequest(
            backend: CacheBackend.cachix,
            cache: "example-cache",
            storePaths: [root],
            substituters: ["https://deploy.example", "https://cache.nixos.org"],
            eventLogPath: eventLog,
            probeTimeoutSeconds: 3,
        ), &fakeRunner, &fakeRunner);
    }
    catch (Exception e)
    {
        threw = true;
        assert(e.msg == "Cache substitute integrity probe failed");
    }
    assert(threw);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 1);
    assert(events[0]["command"]["status"].str == "failed");
    assert(events[0]["metadata"]["coverage"]["complete"].boolean == false);
    assert(events[0]["metadata"]["probes"][6]["path"].str == deployDep);
    assert(events[0]["metadata"]["probes"][6]["substituter"].str == "https://deploy.example");
    assert(events[0]["metadata"]["probes"][6]["outcome"].str == "signature-not-trusted");
    assert(events[0]["error"]["details"]["stderrSummary"].str.canFind("signature-not-trusted"));
}

@("test_cache_probe_timeout_skips_substituter_for_later_paths")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".cache-push-timeout-skip.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    auto dep = "/nix/store/11111111111111111111111111111111-dep";
    auto secondRoot = "/nix/store/22222222222222222222222222222222-second-root";
    auto secondDep = "/nix/store/33333333333333333333333333333333-second-dep";
    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive") && command.canFind(secondRoot))
            return ProcessResult(0, secondRoot ~ "\n" ~ secondDep ~ "\n", "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n" ~ dep ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://slow.example"))
            return ProcessResult(124, "", "");
        if (command.canFind("--store") && command.canFind("https://good.example"))
            return ProcessResult(0, probeCommandStorePathStdout(command), "");
        return ProcessResult(0, "", "");
    }

    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.cachix,
        cache: "example-cache",
        storePaths: [root, secondRoot],
        substituters: ["https://slow.example", "https://good.example"],
        eventLogPath: eventLog,
        probeTimeoutSeconds: 3,
    ), &fakeRunner, &fakeRunner) == 0);

    ulong probeCommandCount(string substituter)
    {
        ulong count;
        foreach (command; commands)
            if (command.canFind("--store") && command.canFind(substituter))
                ++count;
        return count;
    }

    assert(probeCommandCount("https://slow.example") == 1);
    assert(probeCommandCount("https://good.example") == 2);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 2);
    assert(events[0]["command"]["status"].str == "succeeded");
    assert(events[0]["metadata"]["coverage"]["complete"].boolean);
    assert(events[0]["metadata"]["coverage"]["probeAttemptCount"].integer == 6);
    assert("unavailableSubstituters" !in events[0]["metadata"].object);
}

@("test_cache_probe_non_timeout_failure_does_not_skip_later_batches")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".cache-push-non-timeout-retry.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    auto dep = "/nix/store/11111111111111111111111111111111-dep";
    auto secondRoot = "/nix/store/22222222222222222222222222222222-second-root";
    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive") && command.canFind(secondRoot))
            return ProcessResult(0, secondRoot ~ "\n", "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n" ~ dep ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://slow.example")
            && command.canFind(secondRoot))
            return ProcessResult(0, secondRoot ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://slow.example"))
            return ProcessResult(1, dep ~ "\n", "404 Not Found");
        if (command.canFind("--store") && command.canFind("https://good.example"))
            return ProcessResult(0, probeCommandStorePathStdout(command), "");
        return ProcessResult(0, "", "");
    }

    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.cachix,
        cache: "example-cache",
        storePaths: [root, secondRoot],
        substituters: ["https://slow.example", "https://good.example"],
        eventLogPath: eventLog,
        probeTimeoutSeconds: 3,
    ), &fakeRunner, &fakeRunner) == 0);

    ulong probeCommandCount(string substituter)
    {
        ulong count;
        foreach (command; commands)
            if (command.canFind("--store") && command.canFind(substituter))
                ++count;
        return count;
    }

    assert(probeCommandCount("https://slow.example") == 2);
    assert(probeCommandCount("https://good.example") == 1);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 2);
    assert(events[0]["command"]["status"].str == "succeeded");
    assert(events[0]["metadata"]["coverage"]["complete"].boolean);
    assert(events[0]["metadata"]["coverage"]["probeAttemptCount"].integer == 4);
    assert(events[0]["metadata"]["probes"][0]["path"].str == root);
    assert(events[0]["metadata"]["probes"][0]["outcome"].str == "narinfo-missing");
    assert(events[0]["metadata"]["probes"][1]["path"].str == dep);
    assert(events[0]["metadata"]["probes"][1]["outcome"].str == "successful-substitute");
    assert(events[0]["metadata"]["probes"][2]["path"].str == root);
    assert(events[0]["metadata"]["probes"][2]["substituter"].str == "https://good.example");
    assert(events[0]["metadata"]["probes"][2]["outcome"].str == "successful-substitute");
    assert("unavailableSubstituters" !in events[0]["metadata"].object);
}

@("test_cache_probe_timeout_failure_metadata")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".cache-push-timeout-failure.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    ProcessResult fakeRunner(string[] command)
    {
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0, `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://slow.example"))
            return ProcessResult(124, "", "");
        if (command.canFind("--store") && command.canFind("https://missing.example"))
            return ProcessResult(1, "", "404 Not Found");
        return ProcessResult(0, "", "");
    }

    bool threw;
    try
    {
        pushClosure(CachePushRequest(
            backend: CacheBackend.cachix,
            cache: "example-cache",
            storePaths: [root],
            substituters: ["https://slow.example", "https://missing.example"],
            eventLogPath: eventLog,
            probeTimeoutSeconds: 3,
        ), &fakeRunner, &fakeRunner);
    }
    catch (Exception e)
    {
        threw = true;
        assert(e.msg == "Cache substitute integrity probe failed");
    }
    assert(threw);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 1);
    assert(events[0]["command"]["status"].str == "failed");
    assert(events[0]["error"]["code"].str == "cache_probe_failed");
    assert(events[0]["error"]["details"]["stderrSummary"].str.canFind("probe-timeout"));
    assert(events[0]["error"]["details"]["stderrSummary"].str.canFind("https://slow.example"));
    assert(events[0]["error"]["details"]["stderrSummary"].str.canFind("narinfo-missing"));
    assert(events[0]["metadata"]["probeTimeoutSeconds"].integer == 3);
    assert(events[0]["metadata"]["coverage"]["complete"].boolean == false);
    assert(events[0]["metadata"]["coverage"]["probeAttemptCount"].integer == 3);
    assert(events[0]["metadata"]["probes"][0]["outcome"].str == "probe-timeout");
    assert(events[0]["metadata"]["probes"][0]["message"].str.canFind("3s timeout"));
    assert(events[0]["metadata"]["probes"][1]["outcome"].str == "narinfo-missing");
    assert(events[0]["metadata"]["probes"][2]["outcome"].str == "probe-timeout");
    assert(events[0]["metadata"]["unavailableSubstituters"].array.length == 1);
    assert(events[0]["metadata"]["unavailableSubstituters"][0].str == "https://slow.example");
}

@("test_cache_probe_requires_every_closure_path_covered")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".cache-push-requires-full-closure.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    auto dep = "/nix/store/11111111111111111111111111111111-dep";
    ProcessResult fakeRunner(string[] command)
    {
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n" ~ dep ~ "\n", "");
        if (command.canFind("--store"))
            return ProcessResult(1, root ~ "\n", "404 Not Found");
        return ProcessResult(0, "", "");
    }

    bool threw;
    try
    {
        pushClosure(CachePushRequest(
            backend: CacheBackend.cachix,
            cache: "example-cache",
            storePaths: [root],
            substituters: ["https://partial.example"],
            eventLogPath: eventLog,
        ), &fakeRunner, &fakeRunner);
    }
    catch (Exception e)
    {
        threw = true;
        assert(e.msg == "Cache substitute integrity probe failed");
    }
    assert(threw);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 1);
    assert(events[0]["command"]["status"].str == "failed");
    assert(events[0]["metadata"]["coverage"]["complete"].boolean == false);
    assert(events[0]["metadata"]["coverage"]["successfulSubstituteCount"].integer == 1);
    assert(events[0]["error"]["details"]["stderrSummary"].str.canFind(dep));
}

@("test_cache_probe_classifies_failures")
unittest
{
    assert(isTimeoutExitCode(124));
    assert(isTimeoutExitCode(137));
    assert(isTimeoutExitCode(143));
    assert(isTimeoutExitCode(-9));
    assert(isTimeoutExitCode(-15));
    assert(classifyProbeFailure("404 Not Found") == "narinfo-missing");
    assert(classifyProbeFailure("cannot download NAR object") == "narinfo-present-object-unavailable");
    assert(classifyProbeFailure("path is not signed by a trusted key") == "signature-not-trusted");
}
