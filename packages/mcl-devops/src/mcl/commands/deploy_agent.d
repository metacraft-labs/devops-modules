module mcl.commands.deploy_agent;

import std.algorithm : canFind, filter, map, sort;
import std.array : array, join;
import std.conv : to;
import std.exception : enforce;
import std.file : SpanMode, dirEntries, exists, mkdir, mkdirRecurse,
    readText, remove, rmdirRecurse, tempDir, write;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.stdio : writeln;
import std.string : endsWith, splitLines, startsWith, strip;
import std.typecons : Nullable;
import std.uuid : randomUUID;

import argparse : Command, Description, EnvFallback, NamedArgument, Placeholder;

import mcl.commands.deploy_apply : DeploymentActivationMode, DeployApplyArgs,
    DeployApplyDependencies, currentGeneration, deployApplyDeferredExitCode,
    deployApplyManifestConflictExitCode, deployApplyImpl, validateDurableManifest;
import mcl.utils.deploy_manifest : manifestDeploymentId, manifestDesiredSystemPath,
    manifestSequence, manifestSystem, manifestTarget, verifyManifestSignature;
import mcl.utils.deploy_state : acquireDeployTargetStateLock,
    DurableManifestSnapshot, enforceDurableManifestSnapshotCurrent,
    ensureDeployStateDirs, loadDurableManifestSnapshot, manifestStatePath,
    safeTargetName;
import mcl.utils.deployment_events : deploymentEventLogPathFromEnv, utcTimestamp;
import mcl.utils.process : ProcessResult, ProcessRunner, runProcessCapture;

version (unittest)
{
    import mcl.utils.deploy_state : uniqueDeployStateTestPath;
}

@(Command("deploy-agent")
    .Description("Target-side pull agent for signed desired-state manifests"))
struct DeployAgentArgs
{
    @(NamedArgument(["target"])
        .Placeholder("name")
        .Description("Expected deployment target name"))
    string target;

    @(NamedArgument(["manifest"])
        .Placeholder("PATH|URL")
        .Description("Signed desired-state manifest source; repeatable"))
    string[] manifests;

    @(NamedArgument(["manifest-dir"])
        .Placeholder("DIR")
        .Description("Directory containing signed desired-state manifests; repeatable"))
    string[] manifestDirs;

    @(NamedArgument(["trusted-manifest-public-key"])
        .Placeholder("KEY")
        .Description("OpenSSH public key trusted to sign manifests")
        .EnvFallback("MCL_DEPLOY_MANIFEST_PUBLIC_KEY"))
    string trustedManifestPublicKey;

    @(NamedArgument(["allowed-signers"])
        .Placeholder("PATH")
        .Description("OpenSSH allowed signers file trusted for manifest verification"))
    string allowedSigners;

    @(NamedArgument(["state-dir"])
        .Placeholder("DIR")
        .Description("Durable target-local deployment state directory"))
    string stateDir = "/var/lib/mcl/deployments";

    @(NamedArgument(["activation-mode"])
        .Placeholder("nixos|nix-darwin")
        .Description("System activation contract; nixos remains the default"))
    DeploymentActivationMode activationMode = DeploymentActivationMode.nixos;

    @(NamedArgument(["system-profile"])
        .Placeholder("PATH")
        .Description("nix-darwin system profile updated atomically before activation"))
    string systemProfile = "/nix/var/nix/profiles/system";

    @(NamedArgument(["pre-switch-hook"])
        .Placeholder("PATH")
        .Description("Executable readiness hook called with DESIRED PREVIOUS; exit 75 defers deployment"))
    string preSwitchHook;

    @(NamedArgument(["post-switch-hook"])
        .Placeholder("PATH")
        .Description("Executable cleanup hook called with DESIRED PREVIOUS OUTCOME"))
    string postSwitchHook;

    @(NamedArgument(["already-current-recovery-hook"])
        .Placeholder("PATH")
        .Description("Executable recovery-only probe called with DESIRED CURRENT before exact-current convergence"))
    string alreadyCurrentRecoveryHook;

    @(NamedArgument(["event-log"])
        .Placeholder("events.jsonl")
        .Description("Write deployment events as JSONL")
        .EnvFallback("MCL_DEPLOY_EVENT_LOG"))
    string eventLog;

    @(NamedArgument(["max-attempts"])
        .Placeholder("N")
        .Description("Maximum apply attempts for one deployment before marking it non-retryable"))
    ulong maxAttempts = 3;

    @(NamedArgument(["fetch-timeout-seconds"])
        .Placeholder("N")
        .Description("Timeout used when fetching HTTP(S) manifest sources"))
    ulong fetchTimeoutSeconds = 30;

    @(NamedArgument(["dry-run"])
        .Description("Verify and record state, but do not restore, switch, health-check, or rollback"))
    bool dryRun;

    @(NamedArgument(["restore-command"])
        .Placeholder("COMMAND")
        .Description("Override closure restore command for deterministic tests")
        .EnvFallback("MCL_DEPLOY_RESTORE_COMMAND"))
    string restoreCommand;

    @(NamedArgument(["switch-command"])
        .Placeholder("COMMAND")
        .Description("Override switch command for deterministic tests")
        .EnvFallback("MCL_DEPLOY_SWITCH_COMMAND"))
    string switchCommand;

    @(NamedArgument(["rollback-command"])
        .Placeholder("COMMAND")
        .Description("Override rollback command for deterministic tests")
        .EnvFallback("MCL_DEPLOY_ROLLBACK_COMMAND"))
    string rollbackCommand;

    @(NamedArgument(["generation-command"])
        .Placeholder("COMMAND")
        .Description("Override command that prints the current generation path")
        .EnvFallback("MCL_DEPLOY_GENERATION_COMMAND"))
    string generationCommand;

    @(NamedArgument(["no-detach-switch"])
        .Description("Run switch-to-configuration in-process instead of a detached systemd-run scope. "
            ~ "Detaching is the default and prevents this agent unit from deadlocking when the switch "
            ~ "restarts mcl-deploy-agent.service; disable only in environments without systemd."))
    bool noDetachSwitch;
}

struct DeployAgentDependencies
{
    ProcessRunner fetchProcess;
    ProcessRunner runProcess;
    ProcessRunner queryProcess;
    void delegate() afterDurableValidation;
}

struct AgentCandidate
{
    string source;
    string bytes;
    JSONValue manifest;
}

export int deploy_agent(DeployAgentArgs args)
{
    return deployAgentImpl(args, DeployAgentDependencies(
        fetchProcess: (string[] command) => runProcessCapture(command),
        runProcess: (string[] command) => runProcessCapture(command, true),
        queryProcess: (string[] command) => runProcessCapture(command),
    ));
}

string agentStatusPath(string stateDir, string target)
{
    return stateDir.buildPath("agent-status", safeTargetName(target) ~ ".json");
}

Nullable!JSONValue loadAgentStatus(string stateDir, string target)
{
    auto path = agentStatusPath(stateDir, target);
    return path.exists ? Nullable!JSONValue(path.readText.parseJSON) : Nullable!JSONValue.init;
}

ulong statusAttempts(
    Nullable!JSONValue status,
    string deploymentId,
    ulong sequence,
)
{
    if (status.isNull || status.get.type != JSONType.object)
        return 0;
    if (auto id = "deploymentId" in status.get.object)
        if (id.str != deploymentId)
            return 0;
    if (auto observedSequence = "sequence" in status.get.object)
        if (observedSequence.integer.to!ulong != sequence)
            return 0;
    if (auto attempts = "attempts" in status.get.object)
        return attempts.integer.to!ulong;
    return 0;
}

JSONValue agentStatusJson(
    string target,
    string deploymentId,
    ulong sequence,
    string state,
    ulong attempts,
    ulong maxAttempts,
    bool retryable,
    string message,
    string errorCode = "",
    string observedTarget = "",
)
{
    JSONValue[string] status = [
        "target": JSONValue(target),
        "deploymentId": JSONValue(deploymentId),
        "sequence": JSONValue(cast(long) sequence),
        "currentState": JSONValue(state),
        "attempts": JSONValue(cast(long) attempts),
        "maxAttempts": JSONValue(cast(long) maxAttempts),
        "retryable": JSONValue(retryable),
        "updatedAt": JSONValue(utcTimestamp()),
        "message": JSONValue(message),
    ];
    if (errorCode != "")
        status["errorCode"] = JSONValue(errorCode);
    if (observedTarget != "")
        status["observedTarget"] = JSONValue(observedTarget);

    return JSONValue(status);
}

JSONValue writeAgentStatus(
    string stateDir,
    string target,
    string deploymentId,
    ulong sequence,
    string state,
    ulong attempts,
    ulong maxAttempts,
    bool retryable,
    string message,
    string errorCode = "",
    string observedTarget = "",
)
{
    ensureDeployStateDirs(stateDir);
    auto status = agentStatusJson(
        target,
        deploymentId,
        sequence,
        state,
        attempts,
        maxAttempts,
        retryable,
        message,
        errorCode,
        observedTarget,
    );
    auto path = agentStatusPath(stateDir, target);
    if (path.dirName != "" && !path.dirName.exists)
        path.dirName.mkdirRecurse;
    path.write(status.toString(JSONOptions.doNotEscapeSlashes));
    return status;
}

bool isUrlSource(string source)
{
    return source.startsWith("https://") || source.startsWith("http://");
}

bool isMissingHttpManifest(ProcessResult result)
{
    return result.exitCode == 22 && result.stderr.canFind("404");
}

Nullable!string readManifestSource(string source, ulong timeoutSeconds, ProcessRunner fetchRunner)
{
    if (!isUrlSource(source))
        return Nullable!string(source.readText);

    ProcessResult defaultFetch(string[] command) { return runProcessCapture(command); }
    auto runner = fetchRunner is null ? &defaultFetch : fetchRunner;
    auto result = runner([
        "curl",
        "-fsSL",
        "--connect-timeout",
        timeoutSeconds.to!string,
        "--max-time",
        timeoutSeconds.to!string,
        source,
    ]);
    if (!result.succeeded && isMissingHttpManifest(result))
        return Nullable!string.init;
    enforce(result.succeeded, "Manifest fetch failed for " ~ source ~ ": " ~ result.stderr.strip);
    return Nullable!string(result.stdout);
}

string[] manifestSources(DeployAgentArgs args)
{
    string[] sources = args.manifests;
    foreach (dir; args.manifestDirs)
    {
        enforce(dir.exists, "Manifest directory does not exist: " ~ dir);
        auto paths = dirEntries(dir, SpanMode.shallow)
            .filter!(entry => entry.isFile && entry.name.endsWith(".json"))
            .map!(entry => entry.name)
            .array
            .sort
            .array;
        sources ~= paths;
    }
    return sources;
}

AgentCandidate[] loadAgentCandidates(DeployAgentArgs args, ProcessRunner fetchRunner)
{
    AgentCandidate[] candidates;
    foreach (source; manifestSources(args))
    {
        auto content = readManifestSource(source, args.fetchTimeoutSeconds, fetchRunner);
        if (content.isNull)
            continue;
        candidates ~= AgentCandidate(
            source: source,
            bytes: content.get,
            manifest: content.get.parseJSON,
        );
    }
    return candidates;
}

AgentCandidate latestCandidate(AgentCandidate[] candidates)
{
    enforce(candidates.length > 0, "No desired-state manifests found.");
    auto sorted = candidates
        .sort!((a, b) => manifestSequence(a.manifest) < manifestSequence(b.manifest))
        .array;
    auto latest = sorted[$ - 1];
    foreach (candidate; sorted)
    {
        if (
            manifestSequence(candidate.manifest) == manifestSequence(latest.manifest)
            && candidate.bytes != latest.bytes
        )
            throw new Exception(
                "Ambiguous desired state: different signed manifests share sequence "
                ~ manifestSequence(latest.manifest).to!string
            );
    }
    return latest;
}

bool isConverged(string stateDir, JSONValue manifest)
{
    auto path = manifestStatePath(stateDir, "converged", manifestDeploymentId(manifest));
    if (!path.exists)
        return false;
    try
    {
        auto status = path.readText.parseJSON;
        return status["target"].str == manifestTarget(manifest)
            && status["deploymentId"].str == manifestDeploymentId(manifest)
            && status["sequence"].integer.to!ulong == manifestSequence(manifest)
            && status["desiredSystemPath"].str == manifestDesiredSystemPath(manifest)
            && status["currentState"].str == "succeeded";
    }
    catch (Exception)
    {
        return false;
    }
}

int deployAgentImpl(DeployAgentArgs args, DeployAgentDependencies deps)
{
    enforce(args.target != "", "--target is required.");
    enforce(args.trustedManifestPublicKey != "" || args.allowedSigners != "",
        "--trusted-manifest-public-key or --allowed-signers is required.");
    enforce(args.maxAttempts > 0, "--max-attempts must be greater than zero.");
    enforce(args.manifests.length > 0 || args.manifestDirs.length > 0,
        "At least one --manifest or --manifest-dir source is required.");

    // This internal lock is the correctness boundary for every agent entry
    // point, including direct CLI invocation without a service-wrapper flock.
    // Keep it through durable-state validation, all decisions, apply, and the
    // final agent status write.
    auto stateLock = acquireDeployTargetStateLock(args.stateDir, args.target);
    scope(exit) stateLock.release();
    auto eventLogPath = args.eventLog != "" ? args.eventLog : deploymentEventLogPathFromEnv();

    AgentCandidate[] candidates;
    try
    {
        candidates = loadAgentCandidates(args, deps.fetchProcess);
    }
    catch (Exception e)
    {
        auto status = writeAgentStatus(args.stateDir, args.target, "", 0, "failed", 0,
            args.maxAttempts, true, e.msg, "source_read_failed");
        writeln(status.toString(JSONOptions.doNotEscapeSlashes));
        return 1;
    }

    if (candidates.length == 0)
    {
        auto status = writeAgentStatus(args.stateDir, args.target, "", 0, "waiting", 0,
            args.maxAttempts, true, "No desired-state manifests found.");
        writeln(status.toString(JSONOptions.doNotEscapeSlashes));
        return 0;
    }

    foreach (candidate; candidates)
    {
        auto observedTarget = manifestTarget(candidate.manifest);
        if (observedTarget != args.target)
        {
            auto status = writeAgentStatus(args.stateDir, args.target,
                manifestDeploymentId(candidate.manifest), manifestSequence(candidate.manifest),
                "non-retryable", 0, args.maxAttempts, false,
                "Manifest target does not match this agent target.", "wrong_target", observedTarget);
            writeln(status.toString(JSONOptions.doNotEscapeSlashes));
            return 1;
        }

        if (!candidate.manifest.verifyManifestSignature(args.trustedManifestPublicKey, args.allowedSigners))
        {
            auto status = writeAgentStatus(args.stateDir, args.target,
                manifestDeploymentId(candidate.manifest), manifestSequence(candidate.manifest),
                "non-retryable", 0, args.maxAttempts, false,
                "Manifest signature verification failed.", "invalid_signature");
            writeln(status.toString(JSONOptions.doNotEscapeSlashes));
            return 1;
        }
    }

    AgentCandidate selected;
    try
    {
        selected = latestCandidate(candidates);
    }
    catch (Exception e)
    {
        auto status = writeAgentStatus(args.stateDir, args.target, "", 0, "non-retryable", 0,
            args.maxAttempts, false, e.msg, "ambiguous_sequence");
        writeln(status.toString(JSONOptions.doNotEscapeSlashes));
        return 1;
    }

    auto manifest = selected.manifest;
    auto deploymentId = manifestDeploymentId(manifest);
    auto sequence = manifestSequence(manifest);
    // A convergence marker is evidence for one deployment identity, but the
    // durable targets/<target>.json record is authoritative for which identity
    // is still latest. It is allowed to affect high-water decisions only after
    // its complete signed payload has been validated with the same trust roots
    // as incoming manifests. Classify an older replay through deploy-apply's
    // supersession path before the convergence shortcut so old convergence
    // evidence cannot make a stale deployment appear current again.
    DurableManifestSnapshot durableLatest;
    try
    {
        durableLatest = loadDurableManifestSnapshot(
            args.stateDir,
            args.target,
            (JSONValue current) => validateDurableManifest(
                current,
                args.target,
                args.trustedManifestPublicKey,
                args.allowedSigners,
            ),
        );
        if (deps.afterDurableValidation !is null)
            deps.afterDurableValidation();
        enforceDurableManifestSnapshotCurrent(
            args.stateDir, args.target, durableLatest);
    }
    catch (Exception e)
    {
        auto status = writeAgentStatus(args.stateDir, args.target, deploymentId, sequence,
            "non-retryable", 0, args.maxAttempts, false,
            "Durable latest-target state is invalid; refusing deployment.",
            "invalid_durable_state");
        writeln(status.toString(JSONOptions.doNotEscapeSlashes));
        return 1;
    }
    auto previousStatus = loadAgentStatus(args.stateDir, args.target);
    auto previousAttempts = statusAttempts(previousStatus, deploymentId, sequence);
    auto supersededByDurableLatest = durableLatest.present
        && manifestSequence(durableLatest.manifest) > sequence;
    auto conflictsWithDurableLatest = durableLatest.present
        && manifestSequence(durableLatest.manifest) == sequence
        && durableLatest.bytes != selected.bytes;
    auto isDurableLatest = durableLatest.present
        && manifestSequence(durableLatest.manifest) == sequence
        && durableLatest.bytes == selected.bytes;

    if (supersededByDurableLatest)
    {
        // The durable high-water decision is observable on stdout, but it must
        // not overwrite the newer deployment's status or any retry accounting.
        auto status = agentStatusJson(args.target, deploymentId, sequence,
            "superseded", previousAttempts, args.maxAttempts, false,
            "A newer deployment is already accepted for this target.",
            "deployment_superseded");
        writeln(status.toString(JSONOptions.doNotEscapeSlashes));
        return 0;
    }

    if (conflictsWithDurableLatest)
    {
        // An equal sequence is a protocol identity: only the exact same signed
        // bytes may be retried. Never overwrite durable state or agent status
        // with a conflicting payload.
        auto status = agentStatusJson(args.target, deploymentId, sequence,
            "non-retryable", previousAttempts, args.maxAttempts, false,
            "A different signed manifest already owns this target sequence.",
            "manifest_sequence_conflict");
        writeln(status.toString(JSONOptions.doNotEscapeSlashes));
        return 1;
    }

    if (isConverged(args.stateDir, manifest) && !durableLatest.present)
    {
        auto status = writeAgentStatus(args.stateDir, args.target, deploymentId, sequence,
            "non-retryable", previousAttempts, args.maxAttempts, false,
            "Convergence evidence has no durable latest-target identity; refusing shortcut.",
            "missing_durable_state");
        writeln(status.toString(JSONOptions.doNotEscapeSlashes));
        return 1;
    }

    if (isDurableLatest && isConverged(args.stateDir, manifest))
    {
        auto status = agentStatusJson(args.target, deploymentId, sequence,
            "succeeded", previousAttempts, args.maxAttempts, false,
            "Deployment already converged.");
        writeln(status.toString(JSONOptions.doNotEscapeSlashes));
        return 0;
    }

    auto recoveryOnlyAtExhaustedBudget = previousAttempts >= args.maxAttempts;
    if (recoveryOnlyAtExhaustedBudget)
    {
        // Retry budget bounds restore/switch transactions, but it must never
        // strand host lifecycle recovery after a transaction selected the
        // desired generation and its cleanup failed. This authenticated,
        // lock-held, read-only preflight permits only the exact-current path
        // below; a non-current generation remains exhausted without reaching
        // deploy-apply or any mutation surface.
        DeployApplyArgs generationArgs;
        generationArgs.activationMode = args.activationMode;
        generationArgs.systemProfile = args.systemProfile;
        generationArgs.generationCommand = args.generationCommand;
        auto generation = currentGeneration(generationArgs, deps.queryProcess);
        if (!generation.succeeded
            || generation.stdout.strip != manifestDesiredSystemPath(manifest))
        {
            auto status = writeAgentStatus(args.stateDir, args.target, deploymentId, sequence,
                "non-retryable", previousAttempts, args.maxAttempts, false,
                "Retry budget exhausted for this deployment.", "retry_budget_exhausted");
            writeln(status.toString(JSONOptions.doNotEscapeSlashes));
            return 1;
        }
    }

    auto temp = tempDir.buildPath("mcl-deploy-agent-" ~ randomUUID.toString);
    temp.mkdir;
    auto manifestPath = temp.buildPath("manifest.json");
    scope(exit) if (temp.exists) temp.rmdirRecurse;
    manifestPath.write(selected.bytes);

    DeployApplyArgs applyArgs;
    applyArgs.manifest = manifestPath;
    applyArgs.target = args.target;
    applyArgs.trustedManifestPublicKey = args.trustedManifestPublicKey;
    applyArgs.allowedSigners = args.allowedSigners;
    applyArgs.stateDir = args.stateDir;
    applyArgs.activationMode = args.activationMode;
    applyArgs.systemProfile = args.systemProfile;
    applyArgs.preSwitchHook = args.preSwitchHook;
    applyArgs.postSwitchHook = args.postSwitchHook;
    applyArgs.alreadyCurrentRecoveryHook = args.alreadyCurrentRecoveryHook;
    applyArgs.eventLog = eventLogPath;
    applyArgs.dryRun = args.dryRun;
    applyArgs.restoreCommand = args.restoreCommand;
    applyArgs.switchCommand = args.switchCommand;
    applyArgs.rollbackCommand = args.rollbackCommand;
    applyArgs.generationCommand = args.generationCommand;
    applyArgs.noDetachSwitch = args.noDetachSwitch;
    applyArgs.transport = "pull-agent";
    applyArgs.controller = "mcl-deploy-agent";

    bool alreadyCurrent;
    auto result = deployApplyImpl(applyArgs, DeployApplyDependencies(
        runProcess: deps.runProcess,
        queryProcess: deps.queryProcess,
        stateLock: stateLock,
        durableLatest: durableLatest,
        durableLatestBound: true,
        retryIdempotentManifest: true,
        requireAlreadyCurrent: recoveryOnlyAtExhaustedBudget,
        onAlreadyCurrent: { alreadyCurrent = true; },
    ));

    if (result == deployApplyDeferredExitCode)
    {
        auto status = writeAgentStatus(args.stateDir, args.target, deploymentId, sequence,
            "deferred", previousAttempts, args.maxAttempts, true,
            "Deployment readiness conditions are not met; retry budget was not consumed.",
            "deployment_deferred");
        writeln(status.toString(JSONOptions.doNotEscapeSlashes));
        return 0;
    }

    if (result == deployApplyManifestConflictExitCode)
    {
        auto status = agentStatusJson(args.target, deploymentId, sequence,
            "non-retryable", previousAttempts, args.maxAttempts, false,
            "A different signed manifest already owns this target sequence.",
            "manifest_sequence_conflict");
        writeln(status.toString(JSONOptions.doNotEscapeSlashes));
        return 1;
    }

    // `attempts` measures deployment transactions, not accepted manifest
    // identities. A desired generation that was already selected performed no
    // restore, lifecycle hook, activation, health check, or rollback, so it
    // succeeds without consuming the retry budget. This is distinct from a
    // readiness deferral above: the no-op is converged and non-retryable.
    auto attempts = previousAttempts
        + (alreadyCurrent || recoveryOnlyAtExhaustedBudget ? 0 : 1);
    auto succeeded = result == 0;
    auto exhausted = !succeeded && !alreadyCurrent
        && (recoveryOnlyAtExhaustedBudget || attempts >= args.maxAttempts);
    auto status = writeAgentStatus(args.stateDir, args.target, deploymentId, sequence,
        succeeded ? "succeeded" : exhausted ? "non-retryable" : "failed",
        attempts,
        args.maxAttempts,
        !succeeded && !exhausted,
        succeeded ? alreadyCurrent
            ? "Desired system generation was already current."
            : "Deployment converged."
            : alreadyCurrent
                ? "Already-current lifecycle recovery failed; retry remains available."
            : exhausted ? "Retry budget exhausted for this deployment."
            : "Deployment apply failed; retry remains available.",
        succeeded ? "" : alreadyCurrent ? "already_current_recovery_failed"
            : exhausted ? "retry_budget_exhausted" : "apply_failed");
    writeln(status.toString(JSONOptions.doNotEscapeSlashes));
    return result;
}

@("test_deploy_agent_reports_superseded_without_consuming_retry_budget")
unittest
{
    import mcl.utils.deploy_manifest : ManifestBuildRequest, ManifestSigningRequest,
        buildManifest, signManifest;
    import mcl.utils.deploy_state : targetLatestPath;

    auto base = uniqueDeployStateTestPath("deploy-agent-superseded");
    auto keyPath = base ~ ".ed25519";
    auto stateDir = base ~ ".state";
    auto manifestPath = base ~ ".manifest.json";
    auto eventLog = base ~ ".events.jsonl";
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub", manifestPath, eventLog])
            if (path.exists) path.remove;
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto keygen = runProcessCapture([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath,
    ]);
    assert(keygen.succeeded, keygen.stderr);
    auto publicKey = (keyPath ~ ".pub").readText.strip;

    JSONValue signedManifest(string id, ulong sequence, string storeHash)
    {
        return signManifest(buildManifest(ManifestBuildRequest(
            deploymentId: id,
            target: "target",
            gitRevision: "0123456789abcdef0123456789abcdef01234567",
            sequence: sequence,
            desiredSystemPath: "/nix/store/" ~ storeHash ~ "-system",
        )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    }

    auto sequence11 = signedManifest("stable-deployment-id", 11,
        "11111111111111111111111111111111");
    manifestPath.write(sequence11.toString(JSONOptions.doNotEscapeSlashes));

    DeployAgentArgs args;
    args.target = "target";
    args.manifests = [manifestPath];
    args.trustedManifestPublicKey = publicKey;
    args.stateDir = stateDir;
    args.eventLog = eventLog;
    args.maxAttempts = 1;
    args.dryRun = true;

    uint mutations;
    ProcessResult fatalRun(string[] command)
    {
        mutations++;
        return ProcessResult(99, "", "unexpected mutating command");
    }
    ProcessResult fakeQuery(string[] command)
    {
        return ProcessResult(0, "{}", "");
    }

    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &fatalRun,
        queryProcess: &fakeQuery,
    )) == 0);
    auto sequence11Converged = manifestStatePath(
        stateDir, "converged", "stable-deployment-id").readText;
    auto sequence11Events = eventLog.readText;

    // Replaying the durable latest converged identity is still an idempotent
    // convergence shortcut: no apply event or mutation is added.
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &fatalRun,
        queryProcess: &fakeQuery,
    )) == 0);
    auto sameLatestStatus = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(sameLatestStatus["deploymentId"].str == "stable-deployment-id");
    assert(sameLatestStatus["sequence"].integer == 11);
    assert(sameLatestStatus["currentState"].str == "succeeded");
    assert(sameLatestStatus["attempts"].integer == 1);
    assert(eventLog.readText == sequence11Events);
    assert(mutations == 0);

    // Convergence evidence alone is insufficient: a missing or corrupt
    // durable latest-target record fails closed without apply/event mutation.
    auto sequence11Target = targetLatestPath(stateDir, "target").readText;
    targetLatestPath(stateDir, "target").remove;
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &fatalRun,
        queryProcess: &fakeQuery,
    )) == 1);
    auto missingStatus = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(missingStatus["currentState"].str == "non-retryable");
    assert(missingStatus["attempts"].integer == 1);
    assert(missingStatus["errorCode"].str == "missing_durable_state");
    assert(eventLog.readText == sequence11Events);
    assert(mutations == 0);

    targetLatestPath(stateDir, "target").write("{not-json");
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &fatalRun,
        queryProcess: &fakeQuery,
    )) == 1);
    auto corruptStatus = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(corruptStatus["currentState"].str == "non-retryable");
    assert(corruptStatus["attempts"].integer == 0);
    assert(corruptStatus["errorCode"].str == "invalid_durable_state");
    assert(eventLog.readText == sequence11Events);
    assert(mutations == 0);
    targetLatestPath(stateDir, "target").write(sequence11Target);

    auto sequence12 = signedManifest("stable-deployment-id", 12,
        "22222222222222222222222222222222");
    manifestPath.write(sequence12.toString(JSONOptions.doNotEscapeSlashes));
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &fatalRun,
        queryProcess: &fakeQuery,
    )) == 0);
    auto desiredBefore = manifestStatePath(
        stateDir, "desired", "stable-deployment-id").readText;
    auto currentBefore = manifestStatePath(
        stateDir, "current", "stable-deployment-id").readText;
    auto convergedBefore = manifestStatePath(
        stateDir, "converged", "stable-deployment-id").readText;
    auto supersededBefore = manifestStatePath(
        stateDir, "superseded", "stable-deployment-id").readText;
    auto targetBefore = targetLatestPath(stateDir, "target").readText;
    auto statusBefore = agentStatusPath(stateDir, "target").readText;
    auto eventsBefore = eventLog.readText;

    // Exact-byte equality is a convergence no-op, including status/events.
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &fatalRun,
        queryProcess: &fakeQuery,
    )) == 0);
    assert(agentStatusPath(stateDir, "target").readText == statusBefore);
    assert(eventLog.readText == eventsBefore);

    // Sequence 11 has the same deploymentId and historical convergence
    // evidence, but sequence 12 is durably latest. The replay must be
    // superseded without consuming attempts or mutating any durable surface.
    manifestPath.write(sequence11.toString(JSONOptions.doNotEscapeSlashes));
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &fatalRun,
        queryProcess: &fakeQuery,
    )) == 0);

    assert(agentStatusPath(stateDir, "target").readText == statusBefore);
    assert(targetLatestPath(stateDir, "target").readText == targetBefore);
    assert(manifestStatePath(stateDir, "desired", "stable-deployment-id").readText
        == desiredBefore);
    assert(manifestStatePath(stateDir, "current", "stable-deployment-id").readText
        == currentBefore);
    assert(manifestStatePath(stateDir, "converged", "stable-deployment-id").readText
        == convergedBefore);
    assert(manifestStatePath(stateDir, "superseded", "stable-deployment-id").readText
        == supersededBefore);
    assert(convergedBefore != sequence11Converged);
    assert(mutations == 0);
    assert(eventLog.readText == eventsBefore);

    // Same ID and sequence with another valid signed payload is a collision.
    auto sequence12Conflict = signedManifest("stable-deployment-id", 12,
        "abababababababababababababababab");
    manifestPath.write(sequence12Conflict.toString(JSONOptions.doNotEscapeSlashes));
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &fatalRun,
        queryProcess: &fakeQuery,
    )) == 1);
    assert(agentStatusPath(stateDir, "target").readText == statusBefore);
    assert(targetLatestPath(stateDir, "target").readText == targetBefore);
    assert(manifestStatePath(stateDir, "desired", "stable-deployment-id").readText
        == desiredBefore);
    assert(manifestStatePath(stateDir, "current", "stable-deployment-id").readText
        == currentBefore);
    assert(manifestStatePath(stateDir, "converged", "stable-deployment-id").readText
        == convergedBefore);
    assert(manifestStatePath(stateDir, "superseded", "stable-deployment-id").readText
        == supersededBefore);
    assert(eventLog.readText == eventsBefore);
    assert(mutations == 0);

    // A higher sequence may reuse the deploymentId and starts a fresh retry
    // budget instead of inheriting the previous sequence's attempt count.
    auto sequence13 = signedManifest("stable-deployment-id", 13,
        "13131313131313131313131313131313");
    manifestPath.write(sequence13.toString(JSONOptions.doNotEscapeSlashes));
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &fatalRun,
        queryProcess: &fakeQuery,
    )) == 0);
    auto sequence13Status = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(sequence13Status["deploymentId"].str == "stable-deployment-id");
    assert(sequence13Status["sequence"].integer == 13);
    assert(sequence13Status["currentState"].str == "succeeded");
    assert(sequence13Status["attempts"].integer == 1);
    assert(manifestSequence(
        targetLatestPath(stateDir, "target").readText.parseJSON) == 13);
    assert(manifestStatePath(stateDir, "converged", "stable-deployment-id")
        .readText.parseJSON["sequence"].integer == 13);
    assert(mutations == 0);
}

@("test_deploy_agent_rejects_invalid_durable_latest_state_without_applying")
unittest
{
    import mcl.utils.deploy_manifest : ManifestBuildRequest, ManifestSigningRequest,
        buildManifest, signManifest;
    import mcl.utils.deploy_state : targetLatestPath;

    auto base = uniqueDeployStateTestPath("deploy-agent-invalid-durable");
    auto keyPath = base ~ ".ed25519";
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub"])
            if (path.exists) path.remove;
        foreach (variant; [
            "parse-invalid",
            "wrong-types",
            "missing-fields",
            "wrong-target",
            "tampered-sequence",
            "tampered-signature",
        ])
        {
            auto root = base ~ "." ~ variant;
            foreach (suffix; [".manifest.json", ".events.jsonl"])
                if ((root ~ suffix).exists) (root ~ suffix).remove;
            if ((root ~ ".state").exists) (root ~ ".state").rmdirRecurse;
        }
    }

    auto keygen = runProcessCapture([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath,
    ]);
    assert(keygen.succeeded, keygen.stderr);
    auto publicKey = (keyPath ~ ".pub").readText.strip;

    JSONValue signedManifest(string id, string target, ulong sequence, string storeHash)
    {
        return signManifest(buildManifest(ManifestBuildRequest(
            deploymentId: id,
            target: target,
            gitRevision: "0123456789abcdef0123456789abcdef01234567",
            sequence: sequence,
            desiredSystemPath: "/nix/store/" ~ storeHash ~ "-system",
        )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    }

    auto sequence11 = signedManifest("deploy-11", "target", 11,
        "11111111111111111111111111111111");
    auto sequence12 = signedManifest("deploy-12", "target", 12,
        "22222222222222222222222222222222");
    auto otherTarget = signedManifest("deploy-other", "other-target", 999,
        "99999999999999999999999999999999");

    foreach (variant; [
        "parse-invalid",
        "wrong-types",
        "missing-fields",
        "wrong-target",
        "tampered-sequence",
        "tampered-signature",
    ])
    {
        auto root = base ~ "." ~ variant;
        auto stateDir = root ~ ".state";
        auto manifestPath = root ~ ".manifest.json";
        auto eventLog = root ~ ".events.jsonl";
        manifestPath.write(sequence11.toString(JSONOptions.doNotEscapeSlashes));

        DeployAgentArgs args;
        args.target = "target";
        args.manifests = [manifestPath];
        args.trustedManifestPublicKey = publicKey;
        args.stateDir = stateDir;
        args.eventLog = eventLog;
        args.maxAttempts = 3;
        args.dryRun = true;

        uint mutations;
        ProcessResult fatalRun(string[] command)
        {
            mutations++;
            return ProcessResult(99, "", "unexpected mutating command");
        }
        ProcessResult fakeQuery(string[] command)
        {
            return ProcessResult(0, "{}", "");
        }

        assert(deployAgentImpl(args, DeployAgentDependencies(
            runProcess: &fatalRun,
            queryProcess: &fakeQuery,
        )) == 0);
        assert(mutations == 0);

        auto targetBefore = targetLatestPath(stateDir, "target").readText;
        auto desiredBefore = manifestStatePath(stateDir, "desired", "deploy-11").readText;
        auto currentBefore = manifestStatePath(stateDir, "current", "deploy-11").readText;
        auto convergedBefore = manifestStatePath(stateDir, "converged", "deploy-11").readText;
        auto eventsBefore = eventLog.readText;

        switch (variant)
        {
            case "parse-invalid":
                targetLatestPath(stateDir, "target").write("{not-json");
                break;
            case "wrong-types":
                targetLatestPath(stateDir, "target").write(
                    `{"deploymentId":42,"sequence":"bad","target":{"name":"target"}}`);
                break;
            case "missing-fields":
                targetLatestPath(stateDir, "target").write(`{}`);
                break;
            case "wrong-target":
                targetLatestPath(stateDir, "target").write(
                    otherTarget.toString(JSONOptions.doNotEscapeSlashes));
                break;
            case "tampered-sequence":
                auto tampered = targetBefore.parseJSON;
                tampered.object["sequence"] = JSONValue(999);
                targetLatestPath(stateDir, "target").write(
                    tampered.toString(JSONOptions.doNotEscapeSlashes));
                break;
            case "tampered-signature":
                auto tampered = targetBefore.parseJSON;
                auto signature = tampered["manifestSignature"];
                signature.object["signature"] = JSONValue("not-an-openssh-signature");
                tampered.object["manifestSignature"] = signature;
                targetLatestPath(stateDir, "target").write(
                    tampered.toString(JSONOptions.doNotEscapeSlashes));
                break;
            default:
                assert(false, "Unhandled durable-state fixture: " ~ variant);
        }

        manifestPath.write(sequence12.toString(JSONOptions.doNotEscapeSlashes));
        assert(deployAgentImpl(args, DeployAgentDependencies(
            runProcess: &fatalRun,
            queryProcess: &fakeQuery,
        )) == 1);

        auto status = agentStatusPath(stateDir, "target").readText.parseJSON;
        assert(status["deploymentId"].str == "deploy-12");
        assert(status["sequence"].integer == 12);
        assert(status["currentState"].str == "non-retryable");
        assert(status["attempts"].integer == 0);
        assert(status["maxAttempts"].integer == 3);
        assert(status["retryable"].boolean is false);
        assert(status["errorCode"].str == "invalid_durable_state");
        assert(eventLog.readText == eventsBefore);
        assert(manifestStatePath(stateDir, "desired", "deploy-11").readText == desiredBefore);
        assert(manifestStatePath(stateDir, "current", "deploy-11").readText == currentBefore);
        assert(manifestStatePath(stateDir, "converged", "deploy-11").readText
            == convergedBefore);
        assert(!manifestStatePath(stateDir, "desired", "deploy-12").exists);
        assert(!manifestStatePath(stateDir, "current", "deploy-12").exists);
        assert(!manifestStatePath(stateDir, "converged", "deploy-12").exists);
        assert(!manifestStatePath(stateDir, "superseded", "deploy-12").exists);
        assert(mutations == 0);

        // Restoring the last authentic durable record must let the same later
        // signed candidate proceed. A forged high-water sequence can never
        // permanently suppress a legitimate deployment.
        targetLatestPath(stateDir, "target").write(targetBefore);
        assert(deployAgentImpl(args, DeployAgentDependencies(
            runProcess: &fatalRun,
            queryProcess: &fakeQuery,
        )) == 0);
        auto recoveredStatus = agentStatusPath(stateDir, "target").readText.parseJSON;
        assert(recoveredStatus["deploymentId"].str == "deploy-12");
        assert(recoveredStatus["sequence"].integer == 12);
        assert(recoveredStatus["currentState"].str == "succeeded");
        assert(recoveredStatus["attempts"].integer == 1);
        auto latest = targetLatestPath(stateDir, "target").readText.parseJSON;
        assert(manifestDeploymentId(latest) == "deploy-12");
        assert(latest.verifyManifestSignature(publicKey, ""));
        assert(mutations == 0);
    }
}

@("test_deploy_agent_binds_verified_durable_bytes_before_state_or_apply")
unittest
{
    import mcl.utils.deploy_manifest : ManifestBuildRequest, ManifestSigningRequest,
        buildManifest, signManifest;
    import mcl.utils.deploy_state : targetLatestPath;

    auto base = uniqueDeployStateTestPath("deploy-agent-bind-durable");
    auto keyPath = base ~ ".ed25519";
    auto stateDir = base ~ ".state";
    auto manifestPath = base ~ ".manifest.json";
    auto eventLog = base ~ ".events.jsonl";
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub", manifestPath, eventLog])
            if (path.exists) path.remove;
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto keygen = runProcessCapture([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath,
    ]);
    assert(keygen.succeeded, keygen.stderr);
    auto publicKey = (keyPath ~ ".pub").readText.strip;

    JSONValue signedManifest(string id, ulong sequence, string hash)
    {
        return signManifest(buildManifest(ManifestBuildRequest(
            deploymentId: id,
            target: "target",
            gitRevision: "0123456789abcdef0123456789abcdef01234567",
            sequence: sequence,
            desiredSystemPath: "/nix/store/" ~ hash ~ "-system",
        )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    }

    auto oldManifest = signedManifest("deploy-11", 11,
        "11111111111111111111111111111111");
    auto newManifest = signedManifest("deploy-12", 12,
        "22222222222222222222222222222222");
    manifestPath.write(oldManifest.toString(JSONOptions.doNotEscapeSlashes));

    DeployAgentArgs args;
    args.target = "target";
    args.manifests = [manifestPath];
    args.trustedManifestPublicKey = publicKey;
    args.stateDir = stateDir;
    args.eventLog = eventLog;
    args.maxAttempts = 3;
    args.dryRun = true;

    uint mutations;
    uint queries;
    // These dependency runners are poison counters, not state mocks: the test
    // uses real files and OpenSSH signatures and must fail before apply/query.
    ProcessResult poisonMutation(string[] command)
    {
        mutations++;
        return ProcessResult(99, "", "unexpected mutation");
    }
    ProcessResult countedQuery(string[] command)
    {
        queries++;
        return ProcessResult(1, "", "closure metadata unavailable");
    }

    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &poisonMutation,
        queryProcess: &countedQuery,
    )) == 0);
    auto authenticTarget = targetLatestPath(stateDir, "target").readText;
    auto desiredBefore = manifestStatePath(stateDir, "desired", "deploy-11").readText;
    auto currentBefore = manifestStatePath(stateDir, "current", "deploy-11").readText;
    auto convergedBefore = manifestStatePath(stateDir, "converged", "deploy-11").readText;
    auto eventsBefore = eventLog.readText;
    auto queriesBefore = queries;

    auto forged = authenticTarget.parseJSON;
    forged.object["sequence"] = JSONValue(999);
    auto forgedBytes = forged.toString(JSONOptions.doNotEscapeSlashes);
    manifestPath.write(newManifest.toString(JSONOptions.doNotEscapeSlashes));

    bool seamCalled;
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &poisonMutation,
        queryProcess: &countedQuery,
        afterDurableValidation: {
            seamCalled = true;
            targetLatestPath(stateDir, "target").write(forgedBytes);
        },
    )) == 1);

    assert(seamCalled);
    auto status = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(status["deploymentId"].str == "deploy-12");
    assert(status["sequence"].integer == 12);
    assert(status["currentState"].str == "non-retryable");
    assert(status["attempts"].integer == 0);
    assert(status["errorCode"].str == "invalid_durable_state");
    assert(targetLatestPath(stateDir, "target").readText == forgedBytes);
    assert(manifestStatePath(stateDir, "desired", "deploy-11").readText == desiredBefore);
    assert(manifestStatePath(stateDir, "current", "deploy-11").readText == currentBefore);
    assert(manifestStatePath(stateDir, "converged", "deploy-11").readText
        == convergedBefore);
    assert(!manifestStatePath(stateDir, "desired", "deploy-12").exists);
    assert(!manifestStatePath(stateDir, "current", "deploy-12").exists);
    assert(!manifestStatePath(stateDir, "converged", "deploy-12").exists);
    assert(!manifestStatePath(stateDir, "superseded", "deploy-12").exists);
    assert(eventLog.readText == eventsBefore);
    assert(queries == queriesBefore);
    assert(mutations == 0);

    targetLatestPath(stateDir, "target").write(authenticTarget);
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &poisonMutation,
        queryProcess: &countedQuery,
    )) == 0);
    auto recovered = targetLatestPath(stateDir, "target").readText.parseJSON;
    assert(manifestDeploymentId(recovered) == "deploy-12");
    assert(recovered.verifyManifestSignature(publicKey, ""));
}

@("test_deploy_agent_filters_to_latest_signed_target")
unittest
{
    import mcl.utils.deploy_manifest : ManifestBuildRequest, ManifestSigningRequest,
        buildManifest, signManifest;

    auto base = uniqueDeployStateTestPath("deploy-agent-latest");
    auto keyPath = base ~ ".ed25519";
    auto stateDir = base ~ ".state";
    auto manifestDir = base ~ ".manifests";
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub"])
            if (path.exists) path.remove;
        if (stateDir.exists) stateDir.rmdirRecurse;
        if (manifestDir.exists) manifestDir.rmdirRecurse;
    }
    manifestDir.mkdirRecurse;

    auto keygen = runProcessCapture([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath,
    ]);
    assert(keygen.succeeded, keygen.stderr);
    auto publicKey = (keyPath ~ ".pub").readText.strip;

    auto oldManifest = signManifest(buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-41",
        target: "target",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 41,
        desiredSystemPath: "/nix/store/11111111111111111111111111111111-system-old",
    )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    auto newManifest = signManifest(buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-42",
        target: "target",
        gitRevision: "0123456789abcdef0123456789abcdef01234568",
        sequence: 42,
        desiredSystemPath: "/nix/store/22222222222222222222222222222222-system-new",
    )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    manifestDir.buildPath("old.json").write(oldManifest.toString(JSONOptions.doNotEscapeSlashes));
    manifestDir.buildPath("new.json").write(newManifest.toString(JSONOptions.doNotEscapeSlashes));

    DeployAgentArgs args;
    args.target = "target";
    args.manifestDirs = [manifestDir];
    args.trustedManifestPublicKey = publicKey;
    args.stateDir = stateDir;
    args.dryRun = true;

    assert(deployAgentImpl(args, DeployAgentDependencies(
        queryProcess: (string[] command) => ProcessResult(0, "{}", ""),
    )) == 0);

    auto status = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(status["deploymentId"].str == "deploy-42");
    assert(status["sequence"].integer == 42);
    assert(status["currentState"].str == "succeeded");
    assert(manifestStatePath(stateDir, "converged", "deploy-42").exists);
    assert(!manifestStatePath(stateDir, "converged", "deploy-41").exists);
}

@("test_deploy_agent_rejects_wrong_target")
unittest
{
    import mcl.utils.deploy_manifest : ManifestBuildRequest, ManifestSigningRequest,
        buildManifest, signManifest;

    auto base = uniqueDeployStateTestPath("deploy-agent-wrong-target");
    auto keyPath = base ~ ".ed25519";
    auto stateDir = base ~ ".state";
    auto manifestPath = base ~ ".manifest.json";
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
    auto publicKey = (keyPath ~ ".pub").readText.strip;
    auto manifest = signManifest(buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-1",
        target: "other-target",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 1,
        desiredSystemPath: "/nix/store/11111111111111111111111111111111-system",
    )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    manifestPath.write(manifest.toString(JSONOptions.doNotEscapeSlashes));

    DeployAgentArgs args;
    args.target = "target";
    args.manifests = [manifestPath];
    args.trustedManifestPublicKey = publicKey;
    args.stateDir = stateDir;

    assert(deployAgentImpl(args, DeployAgentDependencies(
        queryProcess: (string[] command) => ProcessResult(0, "{}", ""),
    )) == 1);

    auto status = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(status["currentState"].str == "non-retryable");
    assert(status["errorCode"].str == "wrong_target");
    assert(status["observedTarget"].str == "other-target");
}

@("test_deploy_agent_waits_when_http_manifest_is_missing")
unittest
{
    auto stateDir = uniqueDeployStateTestPath("deploy-agent-missing-http");
    scope(exit) if (stateDir.exists) stateDir.rmdirRecurse;

    ProcessResult missingFetch(string[] command)
    {
        assert(command.canFind("curl"));
        return ProcessResult(22, "", "curl: (22) The requested URL returned error: 404");
    }

    DeployAgentArgs args;
    args.target = "target";
    args.manifests = ["https://cache.example.test/mcl-deployments/target/latest.json"];
    args.trustedManifestPublicKey = "ssh-ed25519 test-key";
    args.stateDir = stateDir;

    assert(deployAgentImpl(args, DeployAgentDependencies(
        fetchProcess: &missingFetch,
    )) == 0);

    auto status = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(status["target"].str == "target");
    assert(status["currentState"].str == "waiting");
    assert(status["retryable"].boolean is true);
    assert(status["message"].str == "No desired-state manifests found.");
    assert(("errorCode" in status.object) is null);
}

@("test_deploy_agent_fails_on_non_missing_http_fetch_error")
unittest
{
    auto stateDir = uniqueDeployStateTestPath("deploy-agent-http-error");
    scope(exit) if (stateDir.exists) stateDir.rmdirRecurse;

    ProcessResult failingFetch(string[] command)
    {
        assert(command.canFind("curl"));
        return ProcessResult(22, "", "curl: (22) The requested URL returned error: 503");
    }

    DeployAgentArgs args;
    args.target = "target";
    args.manifests = ["https://cache.example.test/mcl-deployments/target/latest.json"];
    args.trustedManifestPublicKey = "ssh-ed25519 test-key";
    args.stateDir = stateDir;

    assert(deployAgentImpl(args, DeployAgentDependencies(
        fetchProcess: &failingFetch,
    )) == 1);

    auto status = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(status["target"].str == "target");
    assert(status["currentState"].str == "failed");
    assert(status["retryable"].boolean is true);
    assert(status["errorCode"].str == "source_read_failed");
}

@("test_deploy_agent_bounds_failed_apply_retries")
unittest
{
    import mcl.utils.deploy_manifest : ManifestBuildRequest, ManifestSigningRequest,
        buildManifest, signManifest;

    auto base = uniqueDeployStateTestPath("deploy-agent-retry");
    auto keyPath = base ~ ".ed25519";
    auto stateDir = base ~ ".state";
    auto manifestPath = base ~ ".manifest.json";
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
    auto publicKey = (keyPath ~ ".pub").readText.strip;
    auto manifest = signManifest(buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-1",
        target: "target",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 1,
        desiredSystemPath: "/nix/store/11111111111111111111111111111111-system",
    )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    manifestPath.write(manifest.toString(JSONOptions.doNotEscapeSlashes));

    uint restoreRuns;
    ProcessResult fakeRun(string[] command)
    {
        if (command.canFind("false"))
            restoreRuns++;
        return ProcessResult(1, "", "restore failed");
    }

    DeployAgentArgs args;
    args.target = "target";
    args.manifests = [manifestPath];
    args.trustedManifestPublicKey = publicKey;
    args.stateDir = stateDir;
    args.maxAttempts = 2;
    args.restoreCommand = "false";

    foreach (i; 0 .. 3)
        assert(deployAgentImpl(args, DeployAgentDependencies(
            runProcess: &fakeRun,
            queryProcess: (string[] command) => ProcessResult(0, "{}", ""),
        )) == 1);

    auto status = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(status["currentState"].str == "non-retryable");
    assert(status["attempts"].integer == 2);
    assert(status["errorCode"].str == "retry_budget_exhausted");
    assert(restoreRuns == 2);
}

@("test_deploy_agent_deferred_pre_switch_does_not_consume_retry_budget")
unittest
{
    import std.file : rmdirRecurse;
    import mcl.utils.deploy_manifest : ManifestBuildRequest, ManifestSigningRequest,
        buildManifest, signManifest;

    auto base = uniqueDeployStateTestPath("deploy-agent-deferred");
    auto keyPath = base ~ ".ed25519";
    auto stateDir = base ~ ".state";
    auto manifestPath = base ~ ".manifest.json";
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
    auto desired = "/nix/store/77777777777777777777777777777777-system";
    auto previous = "/nix/store/88888888888888888888888888888888-system";
    auto manifest = signManifest(buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-deferred",
        target: "target",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 1,
        desiredSystemPath: desired,
    )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    manifestPath.write(manifest.toString(JSONOptions.doNotEscapeSlashes));

    uint readinessRuns;
    ProcessResult fakeRun(string[] command)
    {
        if (command == ["/hooks/readiness", desired, previous])
        {
            readinessRuns++;
            return ProcessResult(deployApplyDeferredExitCode, "", "host is busy");
        }
        return ProcessResult(0, "", "");
    }
    ProcessResult fakeQuery(string[] command)
    {
        if (command == ["/bin/sh", "-c", "current-generation"])
            return ProcessResult(0, previous ~ "\n", "");
        return ProcessResult(0, "{}", "");
    }

    DeployAgentArgs args;
    args.target = "target";
    args.manifests = [manifestPath];
    args.trustedManifestPublicKey = (keyPath ~ ".pub").readText.strip;
    args.stateDir = stateDir;
    args.maxAttempts = 1;
    args.restoreCommand = "restore";
    args.generationCommand = "current-generation";
    args.preSwitchHook = "/hooks/readiness";

    foreach (_; 0 .. 3)
        assert(deployAgentImpl(args, DeployAgentDependencies(
            runProcess: &fakeRun,
            queryProcess: &fakeQuery,
        )) == 0);

    auto status = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(status["currentState"].str == "deferred");
    assert(status["attempts"].integer == 0);
    assert(status["maxAttempts"].integer == 1);
    assert(status["retryable"].boolean is true);
    assert(status["errorCode"].str == "deployment_deferred");
    assert(readinessRuns == 3);
    assert(!manifestStatePath(stateDir, "converged", "deploy-deferred").exists);
}

@("test_deploy_agent_accepts_higher_already_current_manifest_without_activation_attempt")
unittest
{
    import mcl.utils.deploy_manifest : ManifestBuildRequest, ManifestSigningRequest,
        buildManifest, signManifest;
    import mcl.utils.deploy_state : targetLatestPath;

    auto base = uniqueDeployStateTestPath("deploy-agent-already-current");
    auto keyPath = base ~ ".ed25519";
    auto stateDir = base ~ ".state";
    auto manifestPath = base ~ ".manifest.json";
    auto eventLog = base ~ ".events.jsonl";
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub", manifestPath, eventLog])
            if (path.exists) path.remove;
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto keygen = runProcessCapture([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath,
    ]);
    assert(keygen.succeeded, keygen.stderr);
    auto publicKey = (keyPath ~ ".pub").readText.strip;
    auto desired = "/nix/store/77777777777777777777777777777777-system";

    JSONValue signedManifest(string id, ulong sequence, string revision, string path)
    {
        return signManifest(buildManifest(ManifestBuildRequest(
            deploymentId: id,
            target: "target",
            gitRevision: revision,
            sequence: sequence,
            desiredSystemPath: path,
        )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    }

    auto sequence10 = signedManifest(
        "deploy-10",
        10,
        "1010101010101010101010101010101010101010",
        desired,
    );
    auto sequence11 = signedManifest(
        "deploy-11",
        11,
        "1111111111111111111111111111111111111111",
        desired,
    );
    manifestPath.write(sequence10.toString(JSONOptions.doNotEscapeSlashes));

    DeployAgentArgs args;
    args.target = "target";
    args.manifests = [manifestPath];
    args.trustedManifestPublicKey = publicKey;
    args.stateDir = stateDir;
    args.eventLog = eventLog;
    args.maxAttempts = 1;
    args.dryRun = true;

    uint restoreRuns;
    uint preHookRuns;
    uint recoveryHookRuns;
    uint otherUnsafeMutations;
    ProcessResult poisonMutation(string[] command)
    {
        if (command == ["/bin/sh", "-c", "poison-restore"])
        {
            restoreRuns++;
            return ProcessResult(0, "", "");
        }
        if (command == ["/hooks/poison-pre", desired, desired])
        {
            preHookRuns++;
            return ProcessResult(97, "", "poison pre-switch hook ran");
        }
        if (command == ["/hooks/already-current-recovery", desired, desired])
        {
            recoveryHookRuns++;
            return ProcessResult(0, "", "");
        }
        otherUnsafeMutations++;
        return ProcessResult(97, "", "unsafe deployment surface ran: " ~ command.join(" "));
    }
    ProcessResult realEngineQuery(string[] command)
    {
        if (command == ["/bin/sh", "-c", "current-generation"])
            return ProcessResult(0, desired ~ "\n", "");
        return ProcessResult(0, "{}", "");
    }

    // Seed a lower, authentic durable high-water identity without activating.
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &poisonMutation,
        queryProcess: &realEngineQuery,
    )) == 0);
    assert(restoreRuns == 0);
    assert(preHookRuns == 0);
    assert(otherUnsafeMutations == 0);

    // A new signed identity and higher sequence can legitimately name the
    // generation that is already selected. It must advance durable identity
    // and convergence without spending an activation attempt or entering any
    // restore/lifecycle/activation/health/rollback surface.
    manifestPath.write(sequence11.toString(JSONOptions.doNotEscapeSlashes));
    args.dryRun = false;
    args.restoreCommand = "poison-restore";
    args.generationCommand = "current-generation";
    args.preSwitchHook = "/hooks/poison-pre";
    args.postSwitchHook = "/hooks/poison-post";
    auto statusPath = agentStatusPath(stateDir, "target");
    auto desiredPath = manifestStatePath(stateDir, "desired", "deploy-11");
    auto currentPath = manifestStatePath(stateDir, "current", "deploy-11");
    auto convergedPath = manifestStatePath(stateDir, "converged", "deploy-11");

    // Lifecycle-enabled callers fail closed when they omit the dedicated
    // equality recovery contract. The authentic high-water identity is kept,
    // but the generation is not converged and no transaction attempt or unsafe
    // deployment surface is consumed.
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &poisonMutation,
        queryProcess: &realEngineQuery,
    )) == 1);
    auto missingHookStatus = statusPath.readText.parseJSON;
    assert(missingHookStatus["currentState"].str == "failed");
    assert(missingHookStatus["attempts"].integer == 0);
    assert(missingHookStatus["retryable"].boolean);
    assert(missingHookStatus["errorCode"].str == "already_current_recovery_failed");
    assert(!convergedPath.exists);
    assert(restoreRuns == 0);
    assert(preHookRuns == 0);
    assert(recoveryHookRuns == 0);
    assert(otherUnsafeMutations == 0);

    args.alreadyCurrentRecoveryHook = "/hooks/already-current-recovery";
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &poisonMutation,
        queryProcess: &realEngineQuery,
    )) == 0);

    auto exactManifestBytes = manifestPath.readText;
    auto status = statusPath.readText.parseJSON;
    assert(status["deploymentId"].str == "deploy-11");
    assert(status["sequence"].integer == 11);
    assert(status["currentState"].str == "succeeded");
    assert(status["attempts"].integer == 0);
    assert(status["maxAttempts"].integer == 1);
    assert(status["retryable"].boolean is false);
    assert(targetLatestPath(stateDir, "target").readText == exactManifestBytes);
    assert(desiredPath.readText.parseJSON == sequence11);
    assert(currentPath.readText.parseJSON["currentState"].str == "accepted");
    assert(convergedPath.readText.parseJSON["currentState"].str == "succeeded");
    assert(restoreRuns == 0);
    assert(preHookRuns == 0);
    assert(recoveryHookRuns == 1);
    assert(otherUnsafeMutations == 0);

    auto events = eventLog.readText
        .splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .filter!(event => event["deploymentId"].str == "deploy-11")
        .array;
    assert(events.length == 4);
    assert(events[0]["phase"].str == "activate-requested");
    assert(events[1]["phase"].str == "complete");
    assert(events[1]["command"]["status"].str == "failed");
    assert(events[1]["error"]["code"].str == "missing_already_current_recovery_hook");
    assert(events[2]["phase"].str == "activate-requested");
    assert(events[3]["phase"].str == "complete");
    assert(events[3]["command"]["status"].str == "succeeded");
    assert(events[3]["metadata"]["outcome"].str == "already-current");
    assert(!events.canFind!(event => event["phase"].str == "agent-restore"));
    assert(!events.canFind!(event => event["phase"].str == "switch"));
    assert(!events.canFind!(event => event["phase"].str == "healthcheck"));
    assert(!events.canFind!(event => event["phase"].str == "rollback"));

    auto targetBeforeReplay = targetLatestPath(stateDir, "target").readText;
    auto desiredBeforeReplay = desiredPath.readText;
    auto currentBeforeReplay = currentPath.readText;
    auto convergedBeforeReplay = convergedPath.readText;
    auto statusBeforeReplay = statusPath.readText;
    auto eventsBeforeReplay = eventLog.readText;
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &poisonMutation,
        queryProcess: &realEngineQuery,
    )) == 0);
    assert(targetLatestPath(stateDir, "target").readText == targetBeforeReplay);
    assert(desiredPath.readText == desiredBeforeReplay);
    assert(currentPath.readText == currentBeforeReplay);
    assert(convergedPath.readText == convergedBeforeReplay);
    assert(statusPath.readText == statusBeforeReplay);
    assert(eventLog.readText == eventsBeforeReplay);
    assert(restoreRuns == 0);
    assert(preHookRuns == 0);
    assert(recoveryHookRuns == 1);
    assert(otherUnsafeMutations == 0);
}

@("test_deploy_agent_already_current_completes_pending_recovery_before_convergence")
unittest
{
    import mcl.utils.deploy_manifest : ManifestBuildRequest, ManifestSigningRequest,
        buildManifest, signManifest;

    auto base = uniqueDeployStateTestPath("deploy-agent-already-current-recovery");
    auto keyPath = base ~ ".ed25519";
    auto stateDir = base ~ ".state";
    auto manifestPath = base ~ ".manifest.json";
    auto eventLog = base ~ ".events.jsonl";
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub", manifestPath, eventLog])
            if (path.exists) path.remove;
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto keygen = runProcessCapture([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath,
    ]);
    assert(keygen.succeeded, keygen.stderr);
    auto desired = "/nix/store/88888888888888888888888888888888-darwin-system";
    auto previous = "/nix/store/99999999999999999999999999999999-darwin-system";
    auto manifest = signManifest(buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-recovery",
        target: "m3",
        system: "aarch64-darwin",
        gitRevision: "8888888888888888888888888888888888888888",
        sequence: 8,
        desiredSystemPath: desired,
    )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    manifestPath.write(manifest.toString(JSONOptions.doNotEscapeSlashes));

    string current = previous;
    bool retainedRecovery;
    bool failRecovery = true;
    bool simulateGenerationRace;
    uint generationRaceReads;
    uint restoreRuns;
    uint preRuns;
    uint profileSets;
    uint activations;
    uint postRuns;
    uint recoveryRuns;
    ProcessResult fakeRun(string[] command)
    {
        if (command == ["/bin/sh", "-c", "restore"])
        {
            restoreRuns++;
            return ProcessResult(0, "", "");
        }
        if (command == ["/hooks/pre", desired, previous])
        {
            preRuns++;
            return ProcessResult(0, "", "");
        }
        if (command == ["nix-env", "--profile", base ~ ".profile", "--set", desired])
        {
            profileSets++;
            current = desired;
            return ProcessResult(0, "", "");
        }
        if (command == [desired ~ "/activate"])
        {
            activations++;
            return ProcessResult(0, "", "");
        }
        if (command == ["/hooks/post", desired, previous, "succeeded"])
        {
            postRuns++;
            retainedRecovery = true;
            return ProcessResult(91, "", "CI restoration failed");
        }
        if (command == ["/hooks/already-current-recovery", desired, desired])
        {
            recoveryRuns++;
            assert(retainedRecovery);
            if (failRecovery)
                return ProcessResult(92, "", "CI recovery still failed");
            retainedRecovery = false;
            return ProcessResult(0, "", "");
        }
        return ProcessResult(97, "", "unexpected mutation: " ~ command.join(" "));
    }
    ProcessResult fakeQuery(string[] command)
    {
        if (command == ["/bin/sh", "-c", "current-generation"])
        {
            if (simulateGenerationRace)
            {
                generationRaceReads++;
                return ProcessResult(0,
                    (generationRaceReads == 1 ? desired : previous) ~ "\n", "");
            }
            return ProcessResult(0, current ~ "\n", "");
        }
        return ProcessResult(0, "{}", "");
    }

    DeployAgentArgs args;
    args.target = "m3";
    args.manifests = [manifestPath];
    args.trustedManifestPublicKey = (keyPath ~ ".pub").readText.strip;
    args.stateDir = stateDir;
    args.eventLog = eventLog;
    args.maxAttempts = 1;
    args.activationMode = DeploymentActivationMode.nixDarwin;
    args.systemProfile = base ~ ".profile";
    args.generationCommand = "current-generation";
    args.restoreCommand = "restore";
    args.preSwitchHook = "/hooks/pre";
    args.postSwitchHook = "/hooks/post";
    args.alreadyCurrentRecoveryHook = "/hooks/already-current-recovery";

    // The generation transaction succeeds, but its lifecycle cleanup fails and
    // leaves authenticated recovery state behind. This consumes one attempt.
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &fakeRun,
        queryProcess: &fakeQuery,
    )) == 1);
    auto statusPath = agentStatusPath(stateDir, "m3");
    auto status = statusPath.readText.parseJSON;
    assert(status["currentState"].str == "non-retryable");
    assert(status["attempts"].integer == 1);
    assert(!status["retryable"].boolean);
    assert(status["errorCode"].str == "retry_budget_exhausted");
    assert(current == desired);
    assert(retainedRecovery);
    assert(restoreRuns == 1);
    assert(preRuns == 1);
    assert(profileSets == 1);
    assert(activations == 1);
    assert(postRuns == 1);
    assert(recoveryRuns == 0);

    // The profile can change after the max-attempt preflight but before the
    // apply-side equality decision. That race must fail closed at the last
    // boundary before restore and ordinary lifecycle/activation work, while
    // preserving the exhausted attempt count.
    simulateGenerationRace = true;
    generationRaceReads = 0;
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &fakeRun,
        queryProcess: &fakeQuery,
    )) == 1);
    simulateGenerationRace = false;
    status = statusPath.readText.parseJSON;
    assert(generationRaceReads == 2);
    assert(status["currentState"].str == "non-retryable");
    assert(status["attempts"].integer == 1);
    assert(!status["retryable"].boolean);
    assert(status["errorCode"].str == "retry_budget_exhausted");
    assert(!manifestStatePath(stateDir, "converged", "deploy-recovery").exists);
    assert(retainedRecovery);
    assert(recoveryRuns == 0);
    assert(restoreRuns == 1);
    assert(preRuns == 1);
    assert(profileSets == 1);
    assert(activations == 1);
    assert(postRuns == 1);

    // Exact-current is not convergence while retained lifecycle recovery still
    // fails. Recovery is not a second deployment transaction, so the attempt
    // count stays at one and the retry remains available.
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &fakeRun,
        queryProcess: &fakeQuery,
    )) == 1);
    status = statusPath.readText.parseJSON;
    assert(status["currentState"].str == "failed");
    assert(status["attempts"].integer == 1);
    assert(status["maxAttempts"].integer == 1);
    assert(status["retryable"].boolean);
    assert(!manifestStatePath(stateDir, "converged", "deploy-recovery").exists);
    assert(retainedRecovery);
    assert(recoveryRuns == 1);
    assert(restoreRuns == 1);
    assert(preRuns == 1);
    assert(profileSets == 1);
    assert(activations == 1);
    assert(postRuns == 1);

    // A later recovery-only success clears the retained state before the same
    // generation can be declared converged. It still consumes no new attempt
    // and does not re-enter any deployment mutation surface.
    failRecovery = false;
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &fakeRun,
        queryProcess: &fakeQuery,
    )) == 0);
    status = statusPath.readText.parseJSON;
    assert(status["currentState"].str == "succeeded");
    assert(status["attempts"].integer == 1);
    assert(!status["retryable"].boolean);
    assert(!retainedRecovery);
    assert(recoveryRuns == 2);
    assert(restoreRuns == 1);
    assert(preRuns == 1);
    assert(profileSets == 1);
    assert(activations == 1);
    assert(postRuns == 1);
    assert(manifestStatePath(stateDir, "converged", "deploy-recovery").exists);

    auto statusBeforeReplay = statusPath.readText;
    auto eventsBeforeReplay = eventLog.readText;
    assert(deployAgentImpl(args, DeployAgentDependencies(
        runProcess: &fakeRun,
        queryProcess: &fakeQuery,
    )) == 0);
    assert(statusPath.readText == statusBeforeReplay);
    assert(eventLog.readText == eventsBeforeReplay);
    assert(recoveryRuns == 2);
}
