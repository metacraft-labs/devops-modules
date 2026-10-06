module mcl.commands.deploy_apply;

import std.algorithm : map;
import std.array : array, join;
import std.conv : to;
import std.exception : enforce;
import std.file : deleteme, exists, readText, remove, write;
import std.json : JSONValue, parseJSON;
import std.process : environment;
import std.stdio : stdin;
import std.string : endsWith, startsWith, strip;
import std.typecons : Nullable;

import argparse : AllowedValues, Command, Description, EnvFallback, NamedArgument,
    Placeholder;

import mcl.utils.deploy_manifest : ManifestBuildRequest, buildManifest,
    manifestDeploymentId, manifestDesiredSystemPath, manifestSequence, manifestSystem,
    manifestTarget, verifyManifestSignature;
import mcl.utils.deploy_state : acquireDeployTargetStateLock, DeployTargetStateLock,
    DesiredManifestDecision, DurableManifestSnapshot, loadDurableManifestSnapshot,
    markDeploymentState, recordDesiredManifestBound;
import mcl.utils.deployment_events : ClosureSummary, DeploymentEventContext,
    appendDeploymentEvent, deploymentEventJson, deploymentEventLogPathFromEnv,
    queryClosureSummary, stderrSummary;
import mcl.utils.process : ProcessResult, ProcessRunner, runProcessCapture;

version (unittest)
{
    import core.sync.semaphore : Semaphore;
    import core.thread.osthread : Thread;
    import mcl.utils.deploy_state : uniqueDeployStateTestPath;

    // Assertions before a manual notify/join used to strand the blocked writer,
    // causing the unittest runner itself to hang while tearing down threads.
    private struct ReleaseJoinThreadGuard
    {
        private Semaphore release;
        private Thread thread;
        private bool started;
        private bool joined;

        @disable this(this);

        this(Semaphore release, Thread thread)
        {
            this.release = release;
            this.thread = thread;
        }

        void start()
        {
            thread.start();
            started = true;
        }

        void releaseAndJoin()
        {
            if (started && !joined)
            {
                release.notify();
                thread.join();
                joined = true;
            }
        }

        ~this()
        {
            releaseAndJoin();
        }
    }
}

enum DeploymentActivationMode
{
    nixos,

    @AllowedValues("nix-darwin")
    nixDarwin,
}

enum deployApplyDeferredExitCode = 75;
enum deployApplyManifestConflictExitCode = 76;

@(Command("deploy-apply")
    .Description("Target-side signed deployment apply wrapper"))
struct DeployApplyArgs
{
    @(NamedArgument(["manifest"])
        .Placeholder("manifest.json|-")
        .Description("Signed desired-state manifest; '-' reads stdin"))
    string manifest = "-";

    @(NamedArgument(["target"])
        .Placeholder("name")
        .Description("Expected deployment target name"))
    string target;

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

    @(NamedArgument(["dry-run"])
        .Description("Verify and record state, but do not restore, switch, health-check, or rollback"))
    bool dryRun;

    @(NamedArgument(["reject-ssh-original-command"])
        .Description("Reject non-empty SSH_ORIGINAL_COMMAND for forced-command keys"))
    bool rejectSshOriginalCommand;

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
            ~ "Detaching is the default and prevents the agent unit from deadlocking when the switch "
            ~ "restarts mcl-deploy-agent.service; disable only in environments without systemd."))
    bool noDetachSwitch;

    @(NamedArgument(["transport"])
        .Placeholder("NAME")
        .Description("Deployment transport recorded in target-side events"))
    string transport = "ssh";

    @(NamedArgument(["controller"])
        .Placeholder("NAME")
        .Description("Deployment controller recorded in target-side events"))
    string controller = "mcl-reconciler";
}

struct DeployApplyDependencies
{
    ProcessRunner runProcess;
    ProcessRunner queryProcess;
    DeployTargetStateLock stateLock;
    DurableManifestSnapshot durableLatest;
    bool durableLatestBound;
    bool retryIdempotentManifest;
    bool requireAlreadyCurrent;
    void delegate() beforeStateLock;
    void delegate() afterDurableValidation;
    void delegate() onAlreadyCurrent;
}

export int deploy_apply(DeployApplyArgs args)
{
    return deployApplyImpl(args, DeployApplyDependencies(
        runProcess: (string[] command) => runProcessCapture(command, true),
        queryProcess: (string[] command) => runProcessCapture(command),
    ));
}

string readManifestText(string path)
{
    if (path == "-")
    {
        // The signed JSON value is also the protocol identity for an accepted
        // sequence.  Read stdin as an uninterpreted byte stream: line ranges
        // discard terminators and would make distinct wire payloads compare
        // equal after validation.
        ubyte[] bytes;
        foreach (chunk; stdin.byChunk(64 * 1024))
            bytes ~= chunk;
        return cast(string) bytes;
    }
    return path.readText;
}

string[] manifestSubstituters(JSONValue manifest)
{
    string[] result;
    foreach (substituter; manifest["cacheRequirements"]["substituters"].array)
        result ~= substituter["url"].str;
    return result;
}

string[] manifestTrustedPublicKeys(JSONValue manifest)
{
    string[] result;
    foreach (substituter; manifest["cacheRequirements"]["substituters"].array)
        if (substituter["trustedPublicKey"].str != "")
            result ~= substituter["trustedPublicKey"].str;
    return result;
}

bool automaticRollbackRequested(JSONValue manifest)
{
    auto policy = manifest["rollbackPolicy"];
    return policy["mode"].str == "automatic"
        && policy["onHealthCheckFailure"].str == "rollback"
        && policy["maxAttempts"].integer > 0;
}

ProcessResult shell(ProcessRunner runner, string command)
{
    return runner(["/bin/sh", "-c", command]);
}

// Run an activation command (switch-to-configuration) detached from the caller's
// systemd unit.
//
// The pull agent and the reconciler both run switch-to-configuration from inside
// their own oneshot unit's cgroup. The activated closure legitimately contains a
// new version of that very unit, so switch-to-configuration issues
// `systemctl start/restart mcl-deploy-agent.service` (the timer-wanted oneshot).
// systemd cannot complete that start while the current invocation is still alive,
// so switch-to-configuration blocks forever waiting on a job that can never finish,
// wedging the deploy until the service start-timeout kills it.
//
// systemd-run moves the switch into its own transient scope with a distinct cgroup,
// so systemd is free to (re)start mcl-deploy-agent.service concurrently. --wait
// propagates the switch exit code back to the agent, --pipe forwards stdout/stderr
// so events keep their diagnostics, and --collect garbage-collects the transient
// unit even if it fails.
ProcessResult detachedSwitch(ProcessRunner runner, string command, bool detach)
{
    if (!detach)
        return shell(runner, command);

    import std.uuid : randomUUID;

    auto unitName = "mcl-deploy-activate-" ~ randomUUID.toString;

    // The transient scope does not inherit the agent unit's environment, so
    // forward PATH explicitly; switch-to-configuration's activation scripts call
    // unqualified tools (mkdir, systemctl, ...) that must resolve on PATH.
    auto path = environment.get("PATH", "");

    string[] cmd = [
        "systemd-run",
        "--collect",
        "--pipe",
        "--wait",
        "--quiet",
        "--service-type=exec",
        "--unit=" ~ unitName,
    ];
    if (path != "")
        cmd ~= "--setenv=PATH=" ~ path;
    cmd ~= ["/bin/sh", "-c", command];
    return runner(cmd);
}

ProcessResult currentGeneration(
    DeployApplyArgs args,
    ProcessRunner runner,
)
{
    if (args.generationCommand != "")
        return shell(runner, args.generationCommand);

    final switch (args.activationMode)
    {
        case DeploymentActivationMode.nixos:
            return shell(runner, "readlink -f /run/current-system");
        case DeploymentActivationMode.nixDarwin:
            return runner(["nix-store", "--realise", args.systemProfile]);
    }
}

ProcessResult runLifecycleHook(
    ProcessRunner runner,
    string hook,
    string desired,
    string previous,
    string outcome = "",
)
{
    if (hook == "")
        return ProcessResult(0, "", "");

    auto command = [hook, desired, previous];
    if (outcome != "")
        command ~= outcome;
    return runner(command);
}

ProcessResult setDarwinSystemProfile(
    ProcessRunner runner,
    string profile,
    string generation,
)
{
    return runner(["nix-env", "--profile", profile, "--set", generation]);
}

ProcessResult activateDarwinGeneration(ProcessRunner runner, string generation)
{
    return runner([generation ~ "/activate"]);
}

void validateDurableManifest(
    JSONValue manifest,
    string target,
    string trustedManifestPublicKey,
    string allowedSigners,
)
{
    enforce(manifestTarget(manifest) == target,
        "Durable latest-target state belongs to a different target.");
    manifestDeploymentId(manifest);
    manifestSequence(manifest);
    enforce(manifest.verifyManifestSignature(
            trustedManifestPublicKey, allowedSigners),
        "Durable latest-target state failed signature verification.");
}

int deployApplyImpl(DeployApplyArgs args, DeployApplyDependencies deps)
{
    import std.json : JSONOptions;

    enforce(args.target != "", "--target is required.");
    enforce(args.trustedManifestPublicKey != "" || args.allowedSigners != "",
        "--trusted-manifest-public-key or --allowed-signers is required.");
    if (args.activationMode == DeploymentActivationMode.nixDarwin)
    {
        enforce(args.systemProfile != "", "--system-profile must not be empty for nix-darwin activation.");
        // Dry-run exits before restore, generation lookup, switch, health
        // checks, and rollback.  Accepting deliberately fatal test overrides
        // in that mode lets the public wrapper prove those paths are inert.
        if (!args.dryRun)
        {
            enforce(args.switchCommand == "",
                "--switch-command is incompatible with explicit nix-darwin activation.");
            enforce(args.rollbackCommand == "",
                "--rollback-command is incompatible with explicit nix-darwin activation.");
        }
    }

    if (args.rejectSshOriginalCommand)
        enforce(environment.get("SSH_ORIGINAL_COMMAND", "") == "",
            "Forced-command deployment key does not accept arbitrary SSH commands.");

    ProcessResult defaultRunner(string[] command) { return runProcessCapture(command); }
    auto runner = deps.runProcess is null ? &defaultRunner : deps.runProcess;
    auto queryRunner = deps.queryProcess is null ? runner : deps.queryProcess;
    auto manifestBytes = readManifestText(args.manifest);
    auto manifest = manifestBytes.parseJSON;
    enforce(manifestTarget(manifest) == args.target,
        "Manifest target '" ~ manifestTarget(manifest) ~ "' does not match expected target '" ~ args.target ~ "'.");
    enforce(manifest.verifyManifestSignature(args.trustedManifestPublicKey, args.allowedSigners),
        "Manifest signature verification failed.");

    auto stateLock = deps.stateLock;
    auto ownsStateLock = false;
    scope(exit)
        if (ownsStateLock)
            stateLock.release();
    auto durableLatest = deps.durableLatest;
    if (!deps.durableLatestBound)
    {
        if (deps.beforeStateLock !is null)
            deps.beforeStateLock();
        stateLock = acquireDeployTargetStateLock(args.stateDir, args.target);
        ownsStateLock = true;
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
    }
    else
    {
        enforce(stateLock !is null,
            "A bound durable deployment snapshot requires its held target state lock.");
    }

    auto desiredDecision = recordDesiredManifestBound(
        args.stateDir, manifest, manifestBytes, durableLatest);
    if (desiredDecision == DesiredManifestDecision.superseded)
        return 0;
    if (desiredDecision == DesiredManifestDecision.conflict)
        return deployApplyManifestConflictExitCode;
    if (desiredDecision == DesiredManifestDecision.idempotent
        && !deps.retryIdempotentManifest)
        return 0;

    auto eventLogPath = args.eventLog != "" ? args.eventLog : deploymentEventLogPathFromEnv();
    auto context = DeploymentEventContext(
        eventLogPath: eventLogPath,
        deploymentId: manifestDeploymentId(manifest),
        correlationId: "",
        cache: "",
        substituters: manifestSubstituters(manifest),
        system: manifestSystem(manifest),
        kind: manifestSystem(manifest).endsWith("-darwin") ? "darwin" : "server",
        transport: args.transport,
        controller: args.controller,
    );
    auto closure = queryClosureSummary(manifestDesiredSystemPath(manifest), queryRunner);

    void emit(
        string phase,
        string commandName,
        string[] argv,
        string status,
        int exitCode,
        string errorMessage = "",
        string errorCode = "command_failed",
        string errorDetails = "",
        JSONValue[string] metadata = null,
        bool errorRetryable = false,
    )
    {
        appendDeploymentEvent(eventLogPath, deploymentEventJson(
            context,
            phase,
            manifestTarget(manifest),
            manifestDesiredSystemPath(manifest),
            commandName,
            argv,
            status,
            exitCode,
            closure,
            errorMessage,
            errorCode,
            errorDetails,
            metadata,
            errorRetryable,
        ));
    }

    emit("activate-requested", "mcl-devops deploy-apply", ["mcl-devops", "deploy-apply"], "succeeded", 0,
        "", "command_failed", "", [
            "sequence": JSONValue(cast(long) manifestSequence(manifest)),
            "dryRun": JSONValue(args.dryRun),
        ]);

    if (args.dryRun)
    {
        markDeploymentState(args.stateDir, manifest, "succeeded", "Dry-run verified signed manifest.");
        emit("complete", "mcl-devops deploy-apply --dry-run", ["mcl-devops", "deploy-apply", "--dry-run"], "succeeded", 0);
        return 0;
    }

    auto desired = manifestDesiredSystemPath(manifest);
    auto previousResult = currentGeneration(args, queryRunner);
    auto previous = previousResult.stdout.strip;
    if (
        args.activationMode == DeploymentActivationMode.nixDarwin
        && (!previousResult.succeeded || previous == "")
    )
    {
        emit("switch", "query current generation", [], "failed", previousResult.exitCode,
            "Failed to determine current system generation", "generation_query_failed",
            previousResult.stderr.stderrSummary);
        markDeploymentState(args.stateDir, manifest, "failed",
            "Could not determine the previous system generation.");
        return 1;
    }

    // A newer signed manifest identity can legitimately name the generation
    // that is already selected (for example, an infra-only revision whose m3
    // closure did not change). Authentication and monotonic durable acceptance
    // above still advance the desired-state high-water mark, but no deployment
    // transaction is required. This check must remain before closure restore
    // and every lifecycle hook: those surfaces may stop workloads in
    // preparation for a switch and are not harmless merely because activation
    // would eventually select the same store path.
    if (previousResult.succeeded && previous == desired)
    {
        // Tell the pull agent that this path did not start a new generation
        // transaction even when lifecycle recovery below fails. Retry budget
        // measures restore/switch attempts, not cleanup-only retries.
        if (deps.onAlreadyCurrent !is null)
            deps.onAlreadyCurrent();

        // A host with lifecycle hooks may retain authenticated recovery state
        // after the generation itself became current (for example when its
        // post-switch resource restoration failed). The ordinary pre-switch
        // hook cannot be reused here: on a clean host it may cordon workloads
        // and create exactly the transaction this shortcut avoids. Require a
        // dedicated probe/recovery contract instead, and fail closed when a
        // lifecycle-enabled caller omitted it.
        if (
            args.alreadyCurrentRecoveryHook == ""
            && (args.preSwitchHook != "" || args.postSwitchHook != "")
        )
        {
            markDeploymentState(args.stateDir, manifest, "failed",
                "Already-current lifecycle recovery hook is required.");
            emit("complete", "mcl-devops deploy-apply", ["mcl-devops", "deploy-apply"],
                "failed", 1,
                "Already-current lifecycle recovery hook is required",
                "missing_already_current_recovery_hook", "", [
                    "previousGeneration": JSONValue(previous),
                    "newGeneration": JSONValue(previous),
                    "outcome": JSONValue("already-current-recovery-failed"),
                ], true);
            return 1;
        }

        auto recovery = runLifecycleHook(
            runner, args.alreadyCurrentRecoveryHook, desired, previous);
        if (!recovery.succeeded)
        {
            markDeploymentState(args.stateDir, manifest, "failed",
                "Already-current lifecycle recovery failed.");
            emit("complete", "mcl-devops deploy-apply", ["mcl-devops", "deploy-apply"],
                "failed", recovery.exitCode,
                "Already-current lifecycle recovery failed",
                "already_current_recovery_failed", recovery.stderr.stderrSummary, [
                    "previousGeneration": JSONValue(previous),
                    "newGeneration": JSONValue(previous),
                    "outcome": JSONValue("already-current-recovery-failed"),
                    "lifecycleStage": JSONValue("already-current-recovery"),
                ], true);
            return 1;
        }

        markDeploymentState(args.stateDir, manifest, "succeeded",
            "Desired system generation was already current.");
        emit("complete", "mcl-devops deploy-apply", ["mcl-devops", "deploy-apply"],
            "succeeded", 0, "", "command_failed", "", [
                "previousGeneration": JSONValue(previous),
                "newGeneration": JSONValue(previous),
                "outcome": JSONValue("already-current"),
                "lifecycleRecoveryChecked": JSONValue(
                    args.alreadyCurrentRecoveryHook != ""),
            ]);
        return 0;
    }

    // A retry whose transaction budget is already exhausted may enter this
    // function only to complete exact-current lifecycle recovery. The agent's
    // earlier equality preflight is deliberately not trusted as an authority:
    // another activation can move the profile between that read and this one.
    // Re-check at the last boundary before restore and every ordinary lifecycle
    // or activation surface, and preserve the exhausted budget on mismatch.
    if (deps.requireAlreadyCurrent)
    {
        markDeploymentState(args.stateDir, manifest, "failed",
            "Retry budget exhausted before exact-current recovery.");
        emit("complete", "mcl-devops deploy-apply", ["mcl-devops", "deploy-apply"],
            "failed", 1,
            "Retry budget exhausted before exact-current recovery",
            "retry_budget_exhausted", "", [
                "desiredGeneration": JSONValue(desired),
                "observedGeneration": JSONValue(previous),
                "outcome": JSONValue("retry-budget-exhausted"),
            ]);
        return 1;
    }

    ProcessResult restore;
    string[] restoreArgv;
    if (args.restoreCommand != "")
    {
        restoreArgv = ["sh", "-c", args.restoreCommand];
        restore = shell(runner, args.restoreCommand);
    }
    else
    {
        auto restoreCommand = manifestSubstituters(manifest).length
            ? ["nix", "copy", "--from", manifestSubstituters(manifest)[0], desired]
            : ["nix", "path-info", desired];
        // A signed latest manifest is fresher authority than Nix's per-user
        // negative narinfo cache. Without this override, one transient 404 can
        // poison every bounded deployment retry for the default one-hour TTL.
        if (manifestSubstituters(manifest).length)
            restoreCommand ~= ["--option", "narinfo-cache-negative-ttl", "0"];
        auto keys = manifestTrustedPublicKeys(manifest);
        if (keys.length)
            restoreCommand ~= ["--option", "trusted-public-keys", keys.join(" ")];

        restoreArgv = restoreCommand;
        restore = runner(restoreCommand);
    }
    emit("agent-restore", "nix restore deployment closure", restoreArgv,
        restore.succeeded ? "succeeded" : "failed",
        restore.exitCode,
        restore.succeeded ? "" : "Failed to restore deployment closure",
        "cache_restore_failed",
        restore.succeeded ? "" : restore.stderr.stderrSummary);
    if (!restore.succeeded)
    {
        markDeploymentState(args.stateDir, manifest, "failed", "Closure restore failed.");
        return 1;
    }

    auto preHook = runLifecycleHook(runner, args.preSwitchHook, desired, previous);
    if (args.preSwitchHook != "")
        emit("switch", "deployment readiness hook",
            [args.preSwitchHook, desired, previous],
            preHook.succeeded ? "succeeded"
                : preHook.exitCode == deployApplyDeferredExitCode ? "skipped" : "failed",
            preHook.exitCode,
            preHook.succeeded ? ""
                : preHook.exitCode == deployApplyDeferredExitCode
                    ? "Deployment readiness hook deferred activation"
                    : "Deployment readiness hook failed",
            preHook.succeeded ? "command_failed"
                : preHook.exitCode == deployApplyDeferredExitCode
                    ? "deployment_deferred" : "pre_switch_hook_failed",
            preHook.succeeded ? "" : preHook.stderr.stderrSummary,
            [
                "lifecycleStage": JSONValue("pre-switch"),
                "desiredGeneration": JSONValue(desired),
                "previousGeneration": JSONValue(previous),
            ],
            preHook.exitCode == deployApplyDeferredExitCode);
    if (!preHook.succeeded)
    {
        auto deferred = preHook.exitCode == deployApplyDeferredExitCode;
        markDeploymentState(args.stateDir, manifest, deferred ? "deferred" : "failed",
            deferred
                ? "Readiness hook deferred deployment; retry budget was not consumed."
                : "Readiness hook failed.");
        emit("complete", "mcl-devops deploy-apply", ["mcl-devops", "deploy-apply"],
            deferred ? "skipped" : "failed",
            deferred ? deployApplyDeferredExitCode : 1,
            deferred ? "Deployment readiness conditions are not met."
                : "Deployment readiness hook failed.",
            deferred ? "deployment_deferred" : "pre_switch_hook_failed", "", [
                "lifecycleStage": JSONValue("pre-switch"),
                "outcome": JSONValue(deferred ? "deferred" : "failed"),
            ], deferred);
        return deferred ? deployApplyDeferredExitCode : 1;
    }

    bool switchOk;
    string current;
    string outcome;
    string state;
    string stateMessage;

    if (args.activationMode == DeploymentActivationMode.nixos)
    {
        auto switchCommand = args.switchCommand == ""
            ? desired ~ "/bin/switch-to-configuration switch"
            : args.switchCommand;
        auto switched = detachedSwitch(runner, switchCommand, !args.noDetachSwitch);
        auto currentResult = currentGeneration(args, queryRunner);
        current = currentResult.stdout.strip;
        switchOk = switched.succeeded;
        emit("switch", "switch-to-configuration", ["sh", "-c", switchCommand],
            switched.succeeded ? "succeeded" : "failed",
            switched.exitCode,
            switched.succeeded ? "" : "System switch failed",
            "switch_failed",
            switched.succeeded ? "" : switched.stderr.stderrSummary,
            [
                "previousGeneration": JSONValue(previous),
                "newGeneration": JSONValue(current),
            ]);
    }
    else
    {
        auto profileSet = setDarwinSystemProfile(runner, args.systemProfile, desired);
        auto activated = profileSet.succeeded
            ? activateDarwinGeneration(runner, desired)
            : ProcessResult(profileSet.exitCode, "", profileSet.stderr);
        switchOk = profileSet.succeeded && activated.succeeded;
        current = currentGeneration(args, queryRunner).stdout.strip;
        auto switchArgv = profileSet.succeeded
            ? [desired ~ "/activate"]
            : ["nix-env", "--profile", args.systemProfile, "--set", desired];
        auto switchError = profileSet.succeeded ? activated : profileSet;
        emit("switch", "nix-darwin profile activation", switchArgv,
            switchOk ? "succeeded" : "failed",
            switchError.exitCode,
            switchOk ? "" : "nix-darwin system switch failed",
            "switch_failed",
            switchOk ? "" : switchError.stderr.stderrSummary,
            [
                "previousGeneration": JSONValue(previous),
                "newGeneration": JSONValue(current),
                "systemProfile": JSONValue(args.systemProfile),
            ]);

        if (profileSet.succeeded && !activated.succeeded)
        {
            auto profileRestored = setDarwinSystemProfile(runner, args.systemProfile, previous);
            auto generationRestored = activateDarwinGeneration(runner, previous);
            auto rollbackOk = profileRestored.succeeded && generationRestored.succeeded;
            current = currentGeneration(args, queryRunner).stdout.strip;
            auto rollbackError = !profileRestored.succeeded ? profileRestored : generationRestored;
            emit("rollback", "nix-darwin activation rollback",
                ["nix-env", "--profile", args.systemProfile, "--set", previous,
                    "&&", previous ~ "/activate"],
                rollbackOk ? "succeeded" : "failed",
                rollbackOk ? 0 : rollbackError.exitCode,
                rollbackOk ? "" : "Failed to restore previous nix-darwin generation",
                "rollback_failed",
                rollbackOk ? "" : rollbackError.stderr.stderrSummary,
                [
                    "previousGeneration": JSONValue(previous),
                    "failedGeneration": JSONValue(desired),
                    "systemProfile": JSONValue(args.systemProfile),
                ]);
        }
    }

    bool healthOk = switchOk;
    if (switchOk)
    {
        foreach (check; manifest["healthChecks"].array)
        {
            string[] command;
            if (check["kind"].str == "command")
                command = [
                    "timeout", check["timeoutSeconds"].integer.to!string,
                    "sh", "-c", check["target"].str,
                ];
            else if (check["kind"].str == "systemd")
                command = ["systemctl", "is-active", "--quiet", check["target"].str];
            else
                command = ["false"];

            auto result = runner(command);
            healthOk = healthOk && result.succeeded;
            emit("healthcheck", check["name"].str, command,
                result.succeeded ? "succeeded" : "failed",
                result.exitCode,
                result.succeeded ? "" : "Health check failed",
                "healthcheck_failed",
                result.succeeded ? "" : result.stderr.stderrSummary,
                [
                    "kind": JSONValue(check["kind"].str),
                    "target": JSONValue(check["target"].str),
                ]);
        }
    }

    if (!switchOk)
    {
        outcome = "switch-failed";
        state = "failed";
        stateMessage = "System switch failed.";
    }
    else if (!healthOk)
    {
        outcome = "healthcheck-failed";
        state = "failed";
        stateMessage = "Health check failed.";
        if (automaticRollbackRequested(manifest) && previous != "")
        {
            ProcessResult rollback;
            string[] rollbackArgv;
            if (args.activationMode == DeploymentActivationMode.nixos)
            {
                auto rollbackCommand = args.rollbackCommand == ""
                    ? previous ~ "/bin/switch-to-configuration switch"
                    : args.rollbackCommand;
                rollback = detachedSwitch(runner, rollbackCommand, !args.noDetachSwitch);
                rollbackArgv = ["sh", "-c", rollbackCommand];
            }
            else
            {
                auto profileRestored = setDarwinSystemProfile(runner, args.systemProfile, previous);
                auto generationRestored = activateDarwinGeneration(runner, previous);
                rollback = !profileRestored.succeeded ? profileRestored : generationRestored;
                rollbackArgv = ["nix-env", "--profile", args.systemProfile, "--set", previous,
                    "&&", previous ~ "/activate"];
            }
            emit("rollback", args.activationMode == DeploymentActivationMode.nixos
                    ? "switch-to-configuration rollback"
                    : "nix-darwin health-check rollback",
                rollbackArgv,
                rollback.succeeded ? "succeeded" : "failed",
                rollback.exitCode,
                rollback.succeeded ? "" : "Automatic rollback failed",
                "rollback_failed",
                rollback.succeeded ? "" : rollback.stderr.stderrSummary,
                [
                    "previousGeneration": JSONValue(previous),
                    "failedGeneration": JSONValue(current),
                ]);
            if (rollback.succeeded)
            {
                outcome = "rolled-back";
                state = "rolled-back";
                stateMessage = "Health check failed; rolled back.";
                current = currentGeneration(args, queryRunner).stdout.strip;
            }
            else
            {
                stateMessage = "Health check and rollback failed.";
            }
        }
    }
    else
    {
        outcome = "succeeded";
        state = "succeeded";
        stateMessage = "Deployment converged.";
    }

    auto postHook = runLifecycleHook(runner, args.postSwitchHook, desired, previous, outcome);
    if (args.postSwitchHook != "")
        emit("switch", "deployment cleanup hook",
            [args.postSwitchHook, desired, previous, outcome],
            postHook.succeeded ? "succeeded" : "failed",
            postHook.exitCode,
            postHook.succeeded ? "" : "Deployment cleanup hook failed",
            "post_switch_hook_failed",
            postHook.succeeded ? "" : postHook.stderr.stderrSummary,
            [
                "lifecycleStage": JSONValue("post-switch"),
                "desiredGeneration": JSONValue(desired),
                "previousGeneration": JSONValue(previous),
                "outcome": JSONValue(outcome),
            ]);
    if (!postHook.succeeded && state == "succeeded")
    {
        state = "failed";
        stateMessage = "Post-switch lifecycle hook failed.";
    }

    markDeploymentState(args.stateDir, manifest, state, stateMessage);
    auto succeeded = state == "succeeded";
    emit("complete", "mcl-devops deploy-apply", ["mcl-devops", "deploy-apply"],
        succeeded ? "succeeded" : "failed", succeeded ? 0 : 1,
        succeeded ? "" : "Deployment did not converge",
        succeeded ? "command_failed" : "deployment_failed", "", [
            "previousGeneration": JSONValue(previous),
            "newGeneration": JSONValue(current),
            "outcome": JSONValue(outcome),
        ]);
    return succeeded ? 0 : 1;
}

@("test_deploy_apply_rejects_ssh_original_command")
unittest
{
    import std.exception : assertThrown;

    DeployApplyArgs args;
    args.target = "app-1";
    args.trustedManifestPublicKey = "ssh-ed25519 AAAATEST test";
    args.rejectSshOriginalCommand = true;

    environment["SSH_ORIGINAL_COMMAND"] = "sh";
    scope(exit) environment.remove("SSH_ORIGINAL_COMMAND");
    assertThrown!Exception(deployApplyImpl(args, DeployApplyDependencies()));
}

@("test_deploy_apply_rejects_wrong_manifest_target")
unittest
{
    import std.exception : assertThrown;
    import std.json : JSONOptions;

    auto manifestPath = deleteme ~ ".manifest.json";
    scope(exit)
    {
        if (manifestPath.exists) manifestPath.remove;
    }

    manifestPath.write(
        buildManifest(ManifestBuildRequest(
            deploymentId: "deploy-1",
            target: "app-2",
            gitRevision: "0123456789abcdef0123456789abcdef01234567",
            sequence: 1,
            desiredSystemPath: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system",
        )).toString(JSONOptions.doNotEscapeSlashes)
    );

    DeployApplyArgs args;
    args.manifest = manifestPath;
    args.target = "app-1";
    args.trustedManifestPublicKey = "ssh-ed25519 AAAATEST test";

    assertThrown!Exception(deployApplyImpl(args, DeployApplyDependencies()));
}

@("test_deploy_apply_rejects_post_validation_durable_state_replacement_without_partial_state")
unittest
{
    import std.file : getAttributes, rmdirRecurse;
    import std.json : JSONOptions;
    import mcl.utils.deploy_manifest : ManifestSigningRequest, signManifest;
    import mcl.utils.deploy_state : manifestStatePath, targetLatestPath;

    auto base = uniqueDeployStateTestPath("deploy-apply-post-validation-swap");
    auto keyPath = base ~ ".ed25519";
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub"])
            if (path.exists) path.remove;
        foreach (variant; ["parse-invalid", "forged-high-water"])
        {
            auto stateDir = base ~ "." ~ variant ~ ".state";
            auto eventLog = base ~ "." ~ variant ~ ".events.jsonl";
            auto oldPath = base ~ "." ~ variant ~ ".old.json";
            auto newPath = base ~ "." ~ variant ~ ".new.json";
            if (stateDir.exists) stateDir.rmdirRecurse;
            foreach (path; [eventLog, oldPath, newPath])
                if (path.exists) path.remove;
        }
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

    foreach (variant; ["parse-invalid", "forged-high-water"])
    {
        auto stateDir = base ~ "." ~ variant ~ ".state";
        auto eventLog = base ~ "." ~ variant ~ ".events.jsonl";
        auto oldPath = base ~ "." ~ variant ~ ".old.json";
        auto newPath = base ~ "." ~ variant ~ ".new.json";
        auto oldManifest = signedManifest("deploy-11", 11,
            "11111111111111111111111111111111");
        auto newManifest = signedManifest("deploy-12", 12,
            "22222222222222222222222222222222");
        oldPath.write(oldManifest.toString(JSONOptions.doNotEscapeSlashes));
        newPath.write(newManifest.toString(JSONOptions.doNotEscapeSlashes));

        uint mutationCalls;
        uint queryCalls;
        // Process runners are deliberately inert: this test exercises real
        // parsing, OpenSSH signature verification, locking, and filesystem
        // state while proving no activation surface is reached.
        ProcessResult poisonMutation(string[] command)
        {
            mutationCalls++;
            return ProcessResult(99, "", "unexpected mutation");
        }
        ProcessResult countedQuery(string[] command)
        {
            queryCalls++;
            return ProcessResult(1, "", "closure metadata unavailable");
        }

        DeployApplyArgs args;
        args.manifest = oldPath;
        args.target = "target";
        args.trustedManifestPublicKey = publicKey;
        args.stateDir = stateDir;
        args.eventLog = eventLog;
        args.dryRun = true;

        assert(deployApplyImpl(args, DeployApplyDependencies(
            runProcess: &poisonMutation,
            queryProcess: &countedQuery,
        )) == 0);
        auto authenticTarget = targetLatestPath(stateDir, "target").readText;
        assert((targetLatestPath(stateDir, "target").getAttributes & 511) == 416);
        auto desiredBefore = manifestStatePath(stateDir, "desired", "deploy-11").readText;
        auto currentBefore = manifestStatePath(stateDir, "current", "deploy-11").readText;
        auto convergedBefore = manifestStatePath(stateDir, "converged", "deploy-11").readText;
        auto eventsBefore = eventLog.readText;
        auto queriesBefore = queryCalls;

        string replacement;
        if (variant == "parse-invalid")
            replacement = "{not-json";
        else
        {
            auto forged = authenticTarget.parseJSON;
            forged.object["sequence"] = JSONValue(999);
            replacement = forged.toString(JSONOptions.doNotEscapeSlashes);
        }

        args.manifest = newPath;
        bool seamCalled;
        bool rejected;
        try
        {
            deployApplyImpl(args, DeployApplyDependencies(
                runProcess: &poisonMutation,
                queryProcess: &countedQuery,
                afterDurableValidation: {
                    seamCalled = true;
                    targetLatestPath(stateDir, "target").write(replacement);
                },
            ));
        }
        catch (Exception)
        {
            rejected = true;
        }

        assert(seamCalled);
        assert(rejected);
        assert(targetLatestPath(stateDir, "target").readText == replacement);
        assert(manifestStatePath(stateDir, "desired", "deploy-11").readText == desiredBefore);
        assert(manifestStatePath(stateDir, "current", "deploy-11").readText == currentBefore);
        assert(manifestStatePath(stateDir, "converged", "deploy-11").readText
            == convergedBefore);
        assert(!manifestStatePath(stateDir, "desired", "deploy-12").exists);
        assert(!manifestStatePath(stateDir, "current", "deploy-12").exists);
        assert(!manifestStatePath(stateDir, "converged", "deploy-12").exists);
        assert(!manifestStatePath(stateDir, "superseded", "deploy-12").exists);
        assert(eventLog.readText == eventsBefore);
        assert(queryCalls == queriesBefore);
        assert(mutationCalls == 0);
    }
}

@("test_deploy_apply_stale_writer_fixture_releases_and_joins_during_failure_unwind")
unittest
{
    import core.time : seconds;

    auto workerPaused = new Semaphore(0);
    auto releaseWorker = new Semaphore(0);
    bool workerObservedRelease;
    auto worker = new Thread({
        workerPaused.notify();
        workerObservedRelease = releaseWorker.wait(30.seconds);
    });

    bool controlledFailureObserved;
    try
    {
        auto guard = ReleaseJoinThreadGuard(releaseWorker, worker);
        guard.start();
        assert(workerPaused.wait(30.seconds),
            "Blocked-writer teardown regression worker did not reach its pause handshake.");
        throw new Exception("controlled pre-release fixture failure");
    }
    catch (Exception error)
    {
        controlledFailureObserved = error.msg == "controlled pre-release fixture failure";
    }

    assert(controlledFailureObserved,
        "Blocked-writer teardown regression did not observe its controlled failure.");
    assert(workerObservedRelease,
        "Blocked-writer teardown did not release and join the worker during failure unwind.");
}

@("test_deploy_apply_target_lock_prevents_stale_writer_from_overtaking_newer_state")
unittest
{
    import core.time : seconds;
    import std.file : rmdirRecurse;
    import std.json : JSONOptions;
    import mcl.utils.deploy_manifest : ManifestSigningRequest, signManifest;
    import mcl.utils.deploy_state : manifestStatePath, targetLatestPath;
    import mcl.utils.deployment_events : readDeploymentEvents;

    auto base = uniqueDeployStateTestPath("deploy-apply-concurrent-writers");
    auto keyPath = base ~ ".ed25519";
    auto oldPath = base ~ ".old.json";
    auto newPath = base ~ ".new.json";
    auto stateDir = base ~ ".state";
    auto eventLog = base ~ ".events.jsonl";
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub", oldPath, newPath, eventLog])
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

    auto oldManifest = signedManifest("stable-deployment-id", 11,
        "11111111111111111111111111111111");
    auto newManifest = signedManifest("stable-deployment-id", 12,
        "22222222222222222222222222222222");
    auto oldBytes = oldManifest.toString(JSONOptions.doNotEscapeSlashes);
    auto newBytes = newManifest.toString(JSONOptions.doNotEscapeSlashes);
    oldPath.write(oldBytes);
    newPath.write(newBytes);

    ProcessResult poisonMutation(string[] command)
    {
        return ProcessResult(99, "", "unexpected mutation");
    }
    ProcessResult metadataUnavailable(string[] command)
    {
        return ProcessResult(1, "", "closure metadata unavailable");
    }

    DeployApplyArgs commonArgs(string path)
    {
        DeployApplyArgs args;
        args.manifest = path;
        args.target = "target";
        args.trustedManifestPublicKey = publicKey;
        args.stateDir = stateDir;
        args.eventLog = eventLog;
        args.dryRun = true;
        return args;
    }

    auto oldPaused = new Semaphore(0);
    auto releaseOld = new Semaphore(0);
    int oldResult = -1;
    Exception oldError;
    auto oldThread = new Thread({
        try
        {
            oldResult = deployApplyImpl(
                commonArgs(oldPath),
                DeployApplyDependencies(
                    runProcess: &poisonMutation,
                    queryProcess: &metadataUnavailable,
                    beforeStateLock: {
                        oldPaused.notify();
                        if (!releaseOld.wait(30.seconds))
                            throw new Exception(
                                "Stale-writer test fixture was not released before its safety ceiling.");
                    },
                ),
            );
        }
        catch (Exception e)
        {
            oldError = e;
        }
    });

    auto oldThreadGuard = ReleaseJoinThreadGuard(releaseOld, oldThread);
    oldThreadGuard.start();
    assert(oldPaused.wait(30.seconds),
        "Stale writer did not reach its pre-lock pause handshake.");
    assert(deployApplyImpl(
        commonArgs(newPath),
        DeployApplyDependencies(
            runProcess: &poisonMutation,
            queryProcess: &metadataUnavailable,
        ),
    ) == 0);
    auto targetAfterNew = targetLatestPath(stateDir, "target").readText;
    auto desiredAfterNew = manifestStatePath(
        stateDir, "desired", "stable-deployment-id").readText;
    auto currentAfterNew = manifestStatePath(
        stateDir, "current", "stable-deployment-id").readText;
    auto convergedAfterNew = manifestStatePath(
        stateDir, "converged", "stable-deployment-id").readText;
    auto eventsAfterNew = eventLog.readText;

    oldThreadGuard.releaseAndJoin();
    assert(oldError is null, oldError is null ? "" : oldError.msg);
    assert(oldResult == 0);
    assert(targetLatestPath(stateDir, "target").readText == targetAfterNew);
    assert(targetAfterNew == newBytes);
    assert(manifestDeploymentId(targetAfterNew.parseJSON) == "stable-deployment-id");
    assert(manifestSequence(targetAfterNew.parseJSON) == 12);
    assert(manifestStatePath(stateDir, "desired", "stable-deployment-id").readText
        == desiredAfterNew);
    assert(manifestStatePath(stateDir, "current", "stable-deployment-id").readText
        == currentAfterNew);
    assert(manifestStatePath(stateDir, "converged", "stable-deployment-id").readText
        == convergedAfterNew);
    assert(!manifestStatePath(
        stateDir, "superseded", "stable-deployment-id").exists);
    assert(eventLog.readText == eventsAfterNew);

    auto events = readDeploymentEvents(eventLog);
    assert(events.length == 2);
    assert(events[0]["deploymentId"].str == "stable-deployment-id");
    assert(events[0]["command"]["status"].str == "succeeded");
    assert(events[1]["deploymentId"].str == "stable-deployment-id");
    assert(events[1]["phase"].str == "complete");
}

@("test_deploy_apply_dry_run_does_not_touch_any_activation_surface")
unittest
{
    import std.exception : assertThrown;
    import std.file : dirEntries, rmdirRecurse, SpanMode;
    import std.json : JSONOptions;
    import std.path : buildPath;
    import mcl.utils.deploy_manifest : ManifestHealthCheck, ManifestSigningRequest,
        signManifest;
    import mcl.utils.deploy_state : manifestStatePath, targetLatestPath;
    import mcl.utils.deployment_events : readDeploymentEvents;

    auto base = uniqueDeployStateTestPath("deploy-apply-dry-run-surfaces");
    auto keyPath = base ~ ".ed25519";
    auto manifestPath = base ~ ".manifest.json";
    auto stateDir = base ~ ".state";
    auto nonDryStateDir = base ~ ".non-dry.state";
    auto eventLog = base ~ ".events.jsonl";
    auto nonDryEventLog = base ~ ".non-dry.events.jsonl";
    auto mutationMarker = base ~ ".mutation-ran";
    auto queryMarker = base ~ ".query-ran";
    auto profilePath = base ~ ".system-profile";
    auto preHook = base ~ ".pre-hook";
    auto postHook = base ~ ".post-hook";
    scope(exit)
    {
        foreach (path; [
            base,
            keyPath,
            keyPath ~ ".pub",
            manifestPath,
            eventLog,
            nonDryEventLog,
            mutationMarker,
            queryMarker,
            profilePath,
            preHook,
            postHook,
        ])
            if (path.exists) path.remove;
        foreach (path; [stateDir, nonDryStateDir])
            if (path.exists) path.rmdirRecurse;
    }

    auto keygen = runProcessCapture([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath,
    ]);
    assert(keygen.succeeded, keygen.stderr);
    auto desired = "/nix/store/77777777777777777777777777777777-darwin-system";
    auto manifest = signManifest(buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-darwin-dry-run",
        target: "m3",
        system: "aarch64-darwin",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 77,
        desiredSystemPath: desired,
        healthChecks: [ManifestHealthCheck(
            name: "fatal health surface",
            target: "fatal-health-command",
            timeoutSeconds: 5,
        )],
        rollbackMode: "automatic",
        rollbackMaxAttempts: 1,
        onHealthCheckFailure: "rollback",
    )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    auto signedText = manifest.toString(JSONOptions.doNotEscapeSlashes);
    manifestPath.write(signedText);

    uint mutationCalls;
    uint queryCalls;
    uint closureQueries;
    ProcessResult poisonMutation(string[] command)
    {
        mutationCalls++;
        mutationMarker.write(command.join("\n"));
        return ProcessResult(91, "", "poison mutation surface ran");
    }
    ProcessResult poisonQuery(string[] command)
    {
        if (command == ["nix", "path-info", "--json", "--recursive", desired])
        {
            closureQueries++;
            return ProcessResult(92, "", "closure metadata unavailable");
        }
        queryCalls++;
        queryMarker.write(command.join("\n"));
        return ProcessResult(93, "", "poison generation query surface ran");
    }

    DeployApplyArgs args;
    args.manifest = manifestPath;
    args.target = "m3";
    args.trustedManifestPublicKey = (keyPath ~ ".pub").readText.strip;
    args.stateDir = stateDir;
    args.activationMode = DeploymentActivationMode.nixDarwin;
    args.systemProfile = profilePath;
    args.preSwitchHook = preHook;
    args.postSwitchHook = postHook;
    args.eventLog = eventLog;
    args.dryRun = true;
    args.restoreCommand = "fatal-restore";
    args.switchCommand = "fatal-switch";
    args.rollbackCommand = "fatal-rollback";
    args.generationCommand = "fatal-generation-query";

    assert(deployApplyImpl(args, DeployApplyDependencies(
        runProcess: &poisonMutation,
        queryProcess: &poisonQuery,
    )) == 0);

    // Every command-bearing surface is populated, including both lifecycle
    // hooks, restore, generation lookup, Darwin profile/activation, health,
    // and both rollback representations. Dry-run must reach none of them.
    assert(mutationCalls == 0);
    assert(queryCalls == 0);
    assert(closureQueries == 1);
    assert(!mutationMarker.exists);
    assert(!queryMarker.exists);
    assert(!profilePath.exists);
    assert(!preHook.exists);
    assert(!postHook.exists);

    assert(manifestStatePath(stateDir, "desired", "deploy-darwin-dry-run").readText
        == signedText);
    assert(targetLatestPath(stateDir, "m3").readText == signedText);
    auto current = manifestStatePath(
        stateDir, "current", "deploy-darwin-dry-run").readText.parseJSON;
    assert(current["currentState"].str == "accepted");
    assert(current["sequence"].integer == 77);
    auto converged = manifestStatePath(
        stateDir, "converged", "deploy-darwin-dry-run").readText.parseJSON;
    assert(converged["currentState"].str == "succeeded");
    assert(converged["message"].str == "Dry-run verified signed manifest.");
    assert(!manifestStatePath(stateDir, "failed", "deploy-darwin-dry-run").exists);
    assert(!manifestStatePath(stateDir, "superseded", "deploy-darwin-dry-run").exists);
    auto targetEntries = dirEntries(
        stateDir.buildPath("targets"), SpanMode.shallow).array;
    assert(targetEntries.length == 1);

    auto events = readDeploymentEvents(eventLog);
    assert(events.length == 2);
    assert(events[0]["deploymentId"].str == "deploy-darwin-dry-run");
    assert(events[0]["phase"].str == "activate-requested");
    assert(events[0]["command"]["status"].str == "succeeded");
    assert(events[0]["metadata"]["sequence"].integer == 77);
    assert(events[0]["metadata"]["dryRun"].boolean);
    assert(events[1]["deploymentId"].str == "deploy-darwin-dry-run");
    assert(events[1]["phase"].str == "complete");
    assert(events[1]["command"]["name"].str == "mcl-devops deploy-apply --dry-run");
    assert(events[1]["command"]["status"].str == "succeeded");

    // The otherwise-identical non-dry invocation must fail closed during
    // argument validation because Darwin never accepts generic switch/rollback
    // command overrides. It may not create state, events, or markers.
    args.dryRun = false;
    args.stateDir = nonDryStateDir;
    args.eventLog = nonDryEventLog;
    assertThrown!Exception(deployApplyImpl(args, DeployApplyDependencies(
        runProcess: &poisonMutation,
        queryProcess: &poisonQuery,
    )));
    assert(!nonDryStateDir.exists);
    assert(!nonDryEventLog.exists);
    assert(mutationCalls == 0);
    assert(queryCalls == 0);
    assert(closureQueries == 1);
    assert(!mutationMarker.exists);
    assert(!queryMarker.exists);
}

@("test_deploy_apply_same_id_sequence_high_water_is_signed_exact_and_monotonic")
unittest
{
    import std.file : rmdirRecurse;
    import std.json : JSONOptions;
    import mcl.utils.deploy_manifest : ManifestSigningRequest, signManifest;
    import mcl.utils.deploy_state : manifestStatePath, targetLatestPath;

    auto base = uniqueDeployStateTestPath("deploy-apply-same-id-high-water");
    auto keyPath = base ~ ".ed25519";
    auto manifestPath = base ~ ".manifest.json";
    auto stateDir = base ~ ".state";
    auto eventLog = base ~ ".events.jsonl";
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub", manifestPath, eventLog])
            if (path.exists)
                path.remove;
        if (stateDir.exists)
            stateDir.rmdirRecurse;
    }

    auto keygen = runProcessCapture([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath,
    ]);
    assert(keygen.succeeded, keygen.stderr);
    auto publicKey = (keyPath ~ ".pub").readText.strip;

    string signedBytes(ulong sequence, string revision, string hash)
    {
        auto manifest = signManifest(buildManifest(ManifestBuildRequest(
            deploymentId: "stable-deployment-id",
            target: "target",
            gitRevision: revision,
            sequence: sequence,
            desiredSystemPath: "/nix/store/" ~ hash ~ "-system",
        )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
        return manifest.toString(JSONOptions.doNotEscapeSlashes);
    }

    auto sequence11 = signedBytes(11,
        "1123456789abcdef0123456789abcdef01234567",
        "11111111111111111111111111111111");
    auto sequence12 = signedBytes(12,
        "1223456789abcdef0123456789abcdef01234567",
        "12121212121212121212121212121212");
    auto sequence12Conflict = signedBytes(12,
        "2223456789abcdef0123456789abcdef01234567",
        "abababababababababababababababab");
    auto sequence13 = signedBytes(13,
        "1323456789abcdef0123456789abcdef01234567",
        "13131313131313131313131313131313");

    DeployApplyArgs args;
    args.manifest = manifestPath;
    args.target = "target";
    args.trustedManifestPublicKey = publicKey;
    args.stateDir = stateDir;
    args.eventLog = eventLog;
    args.dryRun = true;
    args.preSwitchHook = base ~ ".must-not-run-pre";
    args.postSwitchHook = base ~ ".must-not-run-post";

    uint activationCalls;
    uint queryCalls;
    ProcessResult fatalActivation(string[] command)
    {
        activationCalls++;
        return ProcessResult(99, "", "unexpected activation");
    }
    ProcessResult queryUnavailable(string[] command)
    {
        queryCalls++;
        return ProcessResult(1, "", "metadata unavailable");
    }
    auto deps = DeployApplyDependencies(
        runProcess: &fatalActivation,
        queryProcess: &queryUnavailable,
    );

    manifestPath.write(sequence12);
    assert(deployApplyImpl(args, deps) == 0);
    assert(targetLatestPath(stateDir, "target").readText == sequence12);
    auto desiredBefore = manifestStatePath(
        stateDir, "desired", "stable-deployment-id").readText;
    auto currentBefore = manifestStatePath(
        stateDir, "current", "stable-deployment-id").readText;
    auto convergedBefore = manifestStatePath(
        stateDir, "converged", "stable-deployment-id").readText;
    auto eventsBefore = eventLog.readText;
    auto queryCallsBefore = queryCalls;

    // Equal sequence and exact signed bytes are an idempotent no-op.
    assert(deployApplyImpl(args, deps) == 0);
    assert(targetLatestPath(stateDir, "target").readText == sequence12);
    assert(manifestStatePath(stateDir, "desired", "stable-deployment-id").readText
        == desiredBefore);
    assert(manifestStatePath(stateDir, "current", "stable-deployment-id").readText
        == currentBefore);
    assert(manifestStatePath(stateDir, "converged", "stable-deployment-id").readText
        == convergedBefore);
    assert(eventLog.readText == eventsBefore);
    assert(queryCalls == queryCallsBefore);

    // A lower sequence is superseded regardless of deployment ID equality.
    manifestPath.write(sequence11);
    assert(deployApplyImpl(args, deps) == 0);
    assert(targetLatestPath(stateDir, "target").readText == sequence12);
    assert(manifestStatePath(stateDir, "desired", "stable-deployment-id").readText
        == desiredBefore);
    assert(manifestStatePath(stateDir, "current", "stable-deployment-id").readText
        == currentBefore);
    assert(manifestStatePath(stateDir, "converged", "stable-deployment-id").readText
        == convergedBefore);
    assert(eventLog.readText == eventsBefore);
    assert(queryCalls == queryCallsBefore);

    // The same sequence with different signed payload bytes is a collision.
    manifestPath.write(sequence12Conflict);
    assert(deployApplyImpl(args, deps) == deployApplyManifestConflictExitCode);
    assert(targetLatestPath(stateDir, "target").readText == sequence12);
    assert(manifestStatePath(stateDir, "desired", "stable-deployment-id").readText
        == desiredBefore);
    assert(manifestStatePath(stateDir, "current", "stable-deployment-id").readText
        == currentBefore);
    assert(manifestStatePath(stateDir, "converged", "stable-deployment-id").readText
        == convergedBefore);
    assert(eventLog.readText == eventsBefore);
    assert(queryCalls == queryCallsBefore);

    // A higher sequence is legitimate even when deploymentId is reused.
    manifestPath.write(sequence13);
    assert(deployApplyImpl(args, deps) == 0);
    assert(targetLatestPath(stateDir, "target").readText == sequence13);
    assert(manifestSequence(targetLatestPath(stateDir, "target").readText.parseJSON) == 13);
    assert(manifestSequence(
        manifestStatePath(stateDir, "current", "stable-deployment-id")
            .readText.parseJSON) == 13);
    assert(manifestStatePath(stateDir, "converged", "stable-deployment-id")
        .readText.parseJSON["sequence"].integer == 13);
    assert(eventLog.readText != eventsBefore);
    assert(queryCalls == queryCallsBefore + 1);
    assert(activationCalls == 0);
}

@("test_deploy_apply_nix_darwin_switches_profile_and_activates")
unittest
{
    import std.algorithm : any, canFind;
    import std.file : rmdirRecurse;
    import std.json : JSONOptions;
    import mcl.utils.deploy_manifest : ManifestSigningRequest, ManifestSubstituter,
        signManifest;
    import mcl.utils.deploy_state : manifestStatePath;

    auto base = uniqueDeployStateTestPath("deploy-apply-darwin-success");
    auto keyPath = base ~ ".ed25519";
    auto manifestPath = base ~ ".manifest.json";
    auto stateDir = base ~ ".state";
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
    auto desired = "/nix/store/22222222222222222222222222222222-darwin-system";
    auto previous = "/nix/store/11111111111111111111111111111111-darwin-system";
    auto manifest = signManifest(buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-darwin-success",
        target: "m3",
        system: "aarch64-darwin",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 1,
        desiredSystemPath: desired,
        substituters: [ManifestSubstituter(
            url: "https://cache.example/deployments",
            trustedPublicKey: "deployments.example:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        )],
    )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    manifestPath.write(manifest.toString(JSONOptions.doNotEscapeSlashes));

    string current = previous;
    string[][] commands;
    ProcessResult fakeRun(string[] command)
    {
        commands ~= command.dup;
        if (command == ["nix-env", "--profile", base ~ ".profile", "--set", desired])
            current = desired;
        return ProcessResult(0, "", "");
    }
    ProcessResult fakeQuery(string[] command)
    {
        if (command == ["/bin/sh", "-c", "current-generation"])
            return ProcessResult(0, current ~ "\n", "");
        return ProcessResult(0, "{}", "");
    }

    DeployApplyArgs args;
    args.manifest = manifestPath;
    args.target = "m3";
    args.trustedManifestPublicKey = (keyPath ~ ".pub").readText.strip;
    args.stateDir = stateDir;
    args.activationMode = DeploymentActivationMode.nixDarwin;
    args.systemProfile = base ~ ".profile";
    args.generationCommand = "current-generation";

    assert(deployApplyImpl(args, DeployApplyDependencies(
        runProcess: &fakeRun,
        queryProcess: &fakeQuery,
    )) == 0);
    assert(current == desired);
    assert(commands.canFind([
        "nix", "copy", "--from", "https://cache.example/deployments", desired,
        "--option", "narinfo-cache-negative-ttl", "0",
        "--option", "trusted-public-keys",
        "deployments.example:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
    ]));
    assert(commands.canFind(["nix-env", "--profile", args.systemProfile, "--set", desired]));
    assert(commands.canFind([desired ~ "/activate"]));
    assert(!commands.any!(command => command.canFind("systemd-run")));
    assert(manifestStatePath(stateDir, "converged", "deploy-darwin-success").exists);
}

@("test_deploy_apply_nix_darwin_restores_previous_profile_on_activation_failure")
unittest
{
    import std.algorithm : canFind;
    import std.file : rmdirRecurse;
    import std.json : JSONOptions;
    import mcl.utils.deploy_manifest : ManifestSigningRequest, signManifest;
    import mcl.utils.deploy_state : manifestStatePath;

    auto base = uniqueDeployStateTestPath("deploy-apply-darwin-rollback");
    auto keyPath = base ~ ".ed25519";
    auto manifestPath = base ~ ".manifest.json";
    auto stateDir = base ~ ".state";
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
    auto desired = "/nix/store/44444444444444444444444444444444-darwin-system";
    auto previous = "/nix/store/33333333333333333333333333333333-darwin-system";
    auto manifest = signManifest(buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-darwin-rollback",
        target: "m3",
        system: "aarch64-darwin",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 1,
        desiredSystemPath: desired,
    )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    manifestPath.write(manifest.toString(JSONOptions.doNotEscapeSlashes));

    string current = previous;
    string[][] commands;
    ProcessResult fakeRun(string[] command)
    {
        commands ~= command.dup;
        if (command.length >= 5 && command[0] == "nix-env")
            current = command[$ - 1];
        if (command == [desired ~ "/activate"])
            return ProcessResult(31, "", "desired activation failed");
        return ProcessResult(0, "", "");
    }
    ProcessResult fakeQuery(string[] command)
    {
        if (command == ["/bin/sh", "-c", "current-generation"])
            return ProcessResult(0, current ~ "\n", "");
        return ProcessResult(0, "{}", "");
    }

    DeployApplyArgs args;
    args.manifest = manifestPath;
    args.target = "m3";
    args.trustedManifestPublicKey = (keyPath ~ ".pub").readText.strip;
    args.stateDir = stateDir;
    args.activationMode = DeploymentActivationMode.nixDarwin;
    args.systemProfile = base ~ ".profile";
    args.generationCommand = "current-generation";
    args.restoreCommand = "restore";

    assert(deployApplyImpl(args, DeployApplyDependencies(
        runProcess: &fakeRun,
        queryProcess: &fakeQuery,
    )) == 1);
    assert(current == previous);
    assert(commands.canFind(["nix-env", "--profile", args.systemProfile, "--set", desired]));
    assert(commands.canFind([desired ~ "/activate"]));
    assert(commands.canFind(["nix-env", "--profile", args.systemProfile, "--set", previous]));
    assert(commands.canFind([previous ~ "/activate"]));
    assert(manifestStatePath(stateDir, "failed", "deploy-darwin-rollback").exists);
}

@("test_deploy_apply_post_switch_restores_resources_on_success_and_failure")
unittest
{
    import std.algorithm : all, canFind, filter;
    import std.array : array;
    import std.file : rmdirRecurse;
    import std.json : JSONOptions;
    import mcl.utils.deploy_manifest : ManifestHealthCheck, ManifestSigningRequest,
        signManifest;
    import mcl.utils.deploy_state : manifestStatePath;
    import mcl.utils.deployment_events : readDeploymentEvents;

    auto base = uniqueDeployStateTestPath("deploy-apply-post-hook");
    auto keyPath = base ~ ".ed25519";
    auto scenarios = [
        "success",
        "profile-failure",
        "activation-failure",
        "health-failure-no-rollback",
        "health-rollback-profile-failure",
        "health-rollback-activation-failure",
    ];
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub"])
            if (path.exists) path.remove;
        foreach (scenario; scenarios)
        {
            foreach (suffix; [".manifest.json", ".events.jsonl"])
                if ((base ~ "." ~ scenario ~ suffix).exists)
                    (base ~ "." ~ scenario ~ suffix).remove;
            auto stateDir = base ~ "." ~ scenario ~ "-state";
            if (stateDir.exists) stateDir.rmdirRecurse;
        }
    }

    auto keygen = runProcessCapture([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath,
    ]);
    assert(keygen.succeeded, keygen.stderr);
    auto desired = "/nix/store/66666666666666666666666666666666-darwin-system;literal";
    auto previous = "/nix/store/55555555555555555555555555555555-darwin-system previous";
    auto publicKey = (keyPath ~ ".pub").readText.strip;

    foreach (scenario; scenarios)
    {
        auto manifestPath = base ~ "." ~ scenario ~ ".manifest.json";
        auto eventLog = base ~ "." ~ scenario ~ ".events.jsonl";
        auto stateDir = base ~ "." ~ scenario ~ "-state";
        auto failProfileSet = scenario == "profile-failure";
        auto failActivation = scenario == "activation-failure";
        auto healthFailure = scenario.startsWith("health-");
        auto failRollbackProfile = scenario == "health-rollback-profile-failure";
        auto failRollbackActivation = scenario == "health-rollback-activation-failure";
        auto automaticRollback = failRollbackProfile || failRollbackActivation;
        ManifestHealthCheck[] healthChecks;
        if (healthFailure)
            healthChecks = [ManifestHealthCheck(
                name: "forced failure",
                target: "health-command",
                timeoutSeconds: 5,
            )];
        auto deploymentId = "deploy-post-hook-" ~ scenario;
        auto manifest = signManifest(buildManifest(ManifestBuildRequest(
            deploymentId: deploymentId,
            target: "m3",
            system: "aarch64-darwin",
            gitRevision: "0123456789abcdef0123456789abcdef01234567",
            sequence: 1,
            desiredSystemPath: desired,
            healthChecks: healthChecks,
            rollbackMode: automaticRollback ? "automatic" : "manual",
            rollbackMaxAttempts: automaticRollback ? 1 : 0,
            onHealthCheckFailure: automaticRollback ? "rollback" : "mark-failed",
        )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
        manifestPath.write(manifest.toString(JSONOptions.doNotEscapeSlashes));

        string current = previous;
        string[][] commands;
        string[][] postCalls;
        ProcessResult fakeRun(string[] command)
        {
            commands ~= command.dup;
            if (command.length >= 5 && command[0] == "nix-env")
            {
                if (command[$ - 1] == desired && failProfileSet)
                    return ProcessResult(41, "", "profile update failed");
                if (command[$ - 1] == previous && failRollbackProfile)
                    return ProcessResult(51, "", "profile restoration failed");
                current = command[$ - 1];
            }
            if (command == [desired ~ "/activate"] && failActivation)
                return ProcessResult(42, "", "activation failed");
            if (command == [previous ~ "/activate"] && failRollbackActivation)
                return ProcessResult(52, "", "previous activation failed");
            if (command == ["timeout", "5", "sh", "-c", "health-command"])
                return ProcessResult(61, "", "health check failed");
            if (command.length > 0 && command[0] == "/hooks/post")
                postCalls ~= command.dup;
            return ProcessResult(0, "", "");
        }
        ProcessResult fakeQuery(string[] command)
        {
            if (command == ["/bin/sh", "-c", "current-generation"])
                return ProcessResult(0, current ~ "\n", "");
            return ProcessResult(0, "{}", "");
        }

        DeployApplyArgs args;
        args.manifest = manifestPath;
        args.target = "m3";
        args.trustedManifestPublicKey = publicKey;
        args.stateDir = stateDir;
        args.activationMode = DeploymentActivationMode.nixDarwin;
        args.systemProfile = base ~ ".profile";
        args.generationCommand = "current-generation";
        args.restoreCommand = "restore";
        args.postSwitchHook = "/hooks/post";
        args.eventLog = eventLog;

        auto expectSuccess = scenario == "success";
        assert(deployApplyImpl(args, DeployApplyDependencies(
            runProcess: &fakeRun,
            queryProcess: &fakeQuery,
        )) == (expectSuccess ? 0 : 1));
        assert(postCalls.length == 1);
        auto expectedOutcome = expectSuccess ? "succeeded"
            : healthFailure ? "healthcheck-failed" : "switch-failed";
        assert(postCalls[0] == [args.postSwitchHook, desired, previous, expectedOutcome]);
        assert(commands[$ - 1] == postCalls[0]);

        auto stateCategory = expectSuccess ? "converged" : "failed";
        auto statePath = manifestStatePath(stateDir, stateCategory, deploymentId);
        assert(statePath.exists);
        assert(statePath.readText.parseJSON["currentState"].str
            == (expectSuccess ? "succeeded" : "failed"));

        auto events = readDeploymentEvents(eventLog);
        assert(events.length > 0);
        assert(events.all!(event => event["target"]["kind"].str == "darwin"));
        auto postEvents = events.filter!(event =>
            "metadata" in event.object
            && "lifecycleStage" in event["metadata"].object
            && event["metadata"]["lifecycleStage"].str == "post-switch").array;
        assert(postEvents.length == 1);
        assert(postEvents[0]["phase"].str == "switch");
        assert(postEvents[0]["command"]["status"].str == "succeeded");
        assert(postEvents[0]["command"]["argv"].array
            .map!(arg => arg.str).array == postCalls[0]);
        assert(postEvents[0]["metadata"]["outcome"].str == expectedOutcome);
        auto completeEvents = events.filter!(event => event["phase"].str == "complete").array;
        assert(completeEvents.length == 1);
        assert(completeEvents[0]["command"]["status"].str
            == (expectSuccess ? "succeeded" : "failed"));

        auto healthEvents = events.filter!(event => event["phase"].str == "healthcheck").array;
        assert(healthEvents.length == (healthFailure ? 1 : 0));
        if (healthFailure)
            assert(healthEvents[0]["command"]["status"].str == "failed");

        auto rollbackEvents = events.filter!(event => event["phase"].str == "rollback").array;
        auto expectsActivationRollback = failActivation;
        auto expectsHealthRollback = automaticRollback;
        assert(rollbackEvents.length == (expectsActivationRollback || expectsHealthRollback ? 1 : 0));
        if (expectsActivationRollback)
            assert(rollbackEvents[0]["command"]["status"].str == "succeeded");
        if (expectsHealthRollback)
        {
            assert(rollbackEvents[0]["command"]["status"].str == "failed");
            assert(rollbackEvents[0]["command"]["exitCode"].integer
                == (failRollbackProfile ? 51 : 52));
            assert(commands.canFind([
                "nix-env", "--profile", args.systemProfile, "--set", previous,
            ]));
            assert(commands.canFind([previous ~ "/activate"]));
        }
        if (scenario == "health-failure-no-rollback")
        {
            assert(!commands.canFind([
                "nix-env", "--profile", args.systemProfile, "--set", previous,
            ]));
            assert(!commands.canFind([previous ~ "/activate"]));
        }
    }
}
