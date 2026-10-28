module mcl.utils.process;

import mcl.utils.test;

import mcl.utils.tui : bold;

import std.process : ProcessPipes, Redirect;
import std.string : split, strip;
import core.sys.posix.unistd : geteuid;
import std.json : JSONValue, parseJSON;

bool isRoot() => geteuid() == 0;

struct ProcessResult
{
    int exitCode;
    string stdout;
    string stderr;

    bool succeeded() const => exitCode == 0;
}

alias ProcessRunner = ProcessResult delegate(string[] args);
alias ProcessInputRunner = ProcessResult delegate(string[] args, string input);

/// Reads a child's stdout and stderr to EOF *concurrently*.
///
/// Draining one pipe completely before touching the other deadlocks as soon as
/// the child writes more than a pipe buffer (64 KiB on Linux) to the pipe that
/// is not being read: the child blocks in write(2) and never closes the pipe we
/// are waiting on. `nix eval` re-locking a flake prints ~100 KiB of
/// "Added input" lines to stderr, which is exactly how `test-mcl` hung for
/// hours instead of finishing in a couple of minutes.
private string[2] readStdoutAndStderr(ProcessPipes pipes)
{
    import core.thread : Thread;
    import std.array : join;
    import std.conv : to;

    string stderrText;
    auto stderrFile = pipes.stderr;
    auto stderrReader = new Thread({
        stderrText = stderrFile.byLine().join("\n").to!string;
    });
    stderrReader.start();
    string stdoutText = pipes.stdout.byLine().join("\n").to!string;
    stderrReader.join();
    return [stdoutText, stderrText];
}

/// Streams a child's stdout line by line to `onLine` while a second thread
/// drains its stderr, and returns the stderr lines once both reach EOF.
///
/// For callers that must process stdout incrementally (`readStdoutAndStderr`
/// buffers it whole). Reading stdout to EOF before touching stderr deadlocks
/// in the same way: `nix-eval-jobs` forwards the `git fetch --progress`
/// output of every eval-time Git fetch to stderr, so a cold fetch of a large
/// repository fills the 64 KiB stderr pipe, git blocks in write(2), the
/// worker holding the fetch lock never finishes, and stdout never reaches
/// EOF. `ci-matrix` hung this way until the job hit its 6 h limit.
string[] forEachStdoutLineDrainingStderr(ProcessPipes pipes, scope void delegate(const(char)[] line) onLine)
{
    import core.thread : Thread;

    string[] stderrLines;
    auto stderrFile = pipes.stderr;
    auto stderrReader = new Thread({
        foreach (line; stderrFile.byLine())
            stderrLines ~= line.idup;
    });
    // Daemon: if `onLine` throws, nothing joins the reader, and it must not
    // keep the process alive.
    stderrReader.isDaemon = true;
    stderrReader.start();
    foreach (line; pipes.stdout.byLine())
        onLine(line);
    stderrReader.join();
    return stderrLines;
}

@("forEachStdoutLineDrainingStderr.drainsLargeStderr")
unittest
{
    import std.process : pipeProcess, wait;

    // ~200 KiB on stderr (well past a 64 KiB pipe buffer) *before* anything
    // reaches stdout; `timeout` turns a regression into a quick failure.
    const script = `i=0; while [ $i -lt 2000 ]; do `
        ~ `echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx >&2; `
        ~ `i=$((i+1)); done; echo one; echo two`;
    auto pipes = pipeProcess(["timeout", "60", "sh", "-c", script], Redirect.stdout | Redirect.stderr);
    string[] seen;
    const errLines = forEachStdoutLineDrainingStderr(pipes, (line) { seen ~= line.idup; });
    assert(wait(pipes.pid) == 0);
    assert(seen == ["one", "two"]);
    assert(errLines.length == 2000);
}

T execute(T = string)(string args, bool printCommand = true, bool returnErr = false, Redirect redirect = Redirect.all) if (is(T == string) || is(T == ProcessPipes) || is(T == JSONValue))
{
    return execute!T(args.strip.split(" "), printCommand, returnErr, redirect);
}
T execute(T = string)(string[] args, bool printCommand = true, bool returnErr = false, Redirect redirect = Redirect.all, bool throwOnError = false, bool logErrors = true) if (is(T == string) || is(T == ProcessPipes) || is(T == JSONValue))
{
    import std.exception : enforce;
    import std.format : format;
    import std.process : pipeShell, wait, escapeShellCommand;
    import std.logger : tracef, errorf, infof;
    import std.array : join;
    import std.algorithm : map, canFind;
    import std.conv : to;

    auto cmd = args.map!(x => x.canFind("*") ? x : x.escapeShellCommand()).join(" ");

    if (printCommand)
        infof("\n$ `%s`", cmd.bold);
    else
        tracef("\n$ `%s`", cmd.bold);
    auto res = pipeShell(cmd, redirect);
    static if (is(T == ProcessPipes))
    {
        return res;
    }
    else
    {
        // Nothing is ever written to the child's stdin here; close it so a
        // child that reads stdin (e.g. git asking for credentials) sees EOF
        // instead of waiting forever on a pipe nobody will write to.
        if (redirect & Redirect.stdin)
            res.stdin.close();

        const outputs = readStdoutAndStderr(res);
        string stdout = outputs[0];
        string stderr = outputs[1];
        string output = stdout;

        int status = wait(res.pid);

        if (status != 0)
        {
            if (logErrors)
                errorf("Command failed:
                ---
                $ `%s`
                stdout: `%s`
                stderr: `%s`
                ---", cmd.bold, stdout.bold, stderr.bold);
            if (throwOnError)
                enforce(0, "Process failed.");
        }
        else
        {
            tracef("
            ---
            $ `%s`
            stdout: `%s`
            stderr: `%s`
            ---", cmd.bold, stdout.bold, stderr.bold);
        }


        if (returnErr)
        {
            output = stderr;
        }

        static if (is(T == string)) {
            return output.strip;
        }
        else
        {
            return parseJSON(output.strip);
        }
    }
}

@("execute")
unittest
{
    import std.exception : assertThrown;

    assert(execute(["echo", "hello"]) == "hello");
    assert(execute(["true"]) == "");
    // assertThrown(execute(["false"]), "Command `false` failed with status 1");
}

// Regression tests for the `test-mcl` hang. Each child is wrapped in
// `timeout` so that a regression fails in seconds rather than hanging the job.
@("execute.drainsLargeStderr")
unittest
{
    // ~200 KiB on stderr (well past a 64 KiB pipe buffer) *before* anything
    // reaches stdout. Built-ins only, so a single process holds both pipes.
    const script = `i=0; while [ $i -lt 2000 ]; do `
        ~ `echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx >&2; `
        ~ `i=$((i+1)); done; echo done`;
    assert(execute(["timeout", "60", "sh", "-c", script], false) == "done");
    assert(runProcessCapture(["timeout", "60", "sh", "-c", script]).stdout == "done");
}

@("execute.closesStdin")
unittest
{
    // `cat` reads stdin until EOF; it must get EOF, not wait for input forever.
    // If it waits, `timeout` kills it with status 124 and `throwOnError` fails
    // the test.
    assert(execute(["timeout", "60", "cat"], printCommand: false, throwOnError: true) == "");
}

ProcessResult runProcessCapture(string[] args, bool echoOutput = false)
{
    import std.array : join;
    import std.algorithm : map, canFind;
    import std.conv : to;
    import std.process : pipeProcess, wait, escapeShellCommand;
    import std.logger : tracef;
    import std.stdio : stdout, stderr;

    const bold = "\033[1m";
    const normal = "\033[0m";
    auto cmd = args.map!(x => x.canFind("*") ? x : x.escapeShellCommand()).join(" ");

    tracef("$ %s%s%s", bold, cmd, normal);

    auto pipes = pipeProcess(args, Redirect.stdout | Redirect.stderr);
    const outputs = readStdoutAndStderr(pipes);
    string stdoutText = outputs[0];
    string stderrText = outputs[1];
    int status = wait(pipes.pid);

    if (echoOutput && stdoutText != "")
        stdout.writeln(stdoutText);
    if (echoOutput && stderrText != "")
        stderr.writeln(stderrText);

    return ProcessResult(status, stdoutText, stderrText);
}

ProcessResult runProcessInlineCapture(string[] args)
{
    return runProcessCapture(args, true);
}

ProcessResult runProcessWithInputCapture(string[] args, string input, bool echoOutput = false)
{
    import std.array : join;
    import std.algorithm : map, canFind;
    import std.conv : to;
    import std.process : pipeProcess, wait, escapeShellCommand;
    import std.logger : tracef;
    import std.stdio : stdout, stderr;
    import std.process : Redirect;

    const bold = "\033[1m";
    const normal = "\033[0m";
    auto cmd = args.map!(x => x.canFind("*") ? x : x.escapeShellCommand()).join(" ");

    tracef("$ %s%s%s", bold, cmd, normal);

    import core.sys.posix.poll : pollfd, poll, nfds_t,
        POLLIN, POLLOUT, POLLHUP, POLLERR, POLLNVAL;
    import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
    import core.sys.posix.unistd : read, write;
    import core.sys.posix.signal : sigset_t, sigemptyset, sigaddset,
        sigpending, sigismember, sigwait, pthread_sigmask,
        SIGPIPE, SIG_BLOCK, SIG_SETMASK, SIGKILL, kill;
    import core.stdc.errno : errno, EINTR, EPIPE, EAGAIN, EWOULDBLOCK, EBADF;
    import std.exception : errnoEnforce, ErrnoException, enforce;
    import std.array : Appender;
    import std.stdio : File;

    Appender!string[2] captured;
    auto pipes = pipeProcess(args, Redirect.stdin | Redirect.stdout | Redirect.stderr);
    File[3] channels;
    pollfd[3] watched = [pollfd(-1, 0, 0), pollfd(-1, 0, 0), pollfd(-1, 0, 0)];
    sigset_t pipeSignal, previousMask, pending;
    bool maskSaved, priorPending, priorBlocked, sawEpipe, cleaned;
    Throwable failure;
    int status;

    void remember(Throwable error)
    {
        if (failure is null)
            failure = error;
    }
    void closeChannel(size_t index)
    {
        scope(exit) watched[index].fd = -1;
        channels[index].close();
    }
    void cleanup(bool stopChild)
    {
        // Only this operation owns the unreaped child PID. No callbacks or
        // worker threads can outlive cleanup or signal a subsequently reused PID.
        if (stopChild)
            kill(pipes.pid.processID, SIGKILL);
        foreach (index; 0 .. channels.length)
            try { closeChannel(index); } catch (Throwable error) { remember(error); }
        try { status = wait(pipes.pid); } catch (Throwable error) { remember(error); }

        if (maskSaved)
        {
            try
            {
                // Preserve a caller's prior pending signal and an already
                // blocked caller's signal policy. Otherwise consume only the
                // write-generated EPIPE signal before restoring the old mask.
                // sigwait is available on Linux/macOS; sigtimedwait is not
                // available in the selected Darwin bindings. On Linux a
                // write-generated SIGPIPE is thread-directed, so it cannot be
                // stolen by another thread. Darwin raises it process-wide,
                // which is why the stdin descriptor carries F_SETNOSIGPIPE
                // there and no signal is generated at all. Arbitrary
                // concurrent process-directed SIGPIPE provenance is not
                // distinguishable and is not promised here.
                if (sawEpipe && !priorPending && !priorBlocked)
                {
                    errnoEnforce(sigpending(&pending) == 0, "reading pending stdin signals");
                    if (sigismember(&pending, SIGPIPE) == 1)
                    {
                        int received;
                        int error;
                        do { error = sigwait(&pipeSignal, &received); } while (error == EINTR);
                        if (error != 0)
                            throw new ErrnoException("consuming stdin SIGPIPE", error);
                        enforce(received == SIGPIPE, "Unexpected stdin signal");
                    }
                }
            }
            catch (Throwable error) { remember(error); }
            // Restore even after an I/O, close, wait or signal-consumption error.
            const error = pthread_sigmask(SIG_SETMASK, &previousMask, null);
            if (error != 0)
                try { throw new ErrnoException("restoring stdin signal mask", error); }
                catch (Throwable problem) { remember(problem); }
            maskSaved = false;
        }
        cleaned = true;
    }
    // Register child ownership before setting descriptor flags, changing the
    // signal mask, or allocating capture buffers. Cleanup preserves the first
    // failure while independently closing all channels and reaping the child.
    scope(exit) if (!cleaned) cleanup(true);
    try
    {
        channels = [pipes.stdin, pipes.stdout, pipes.stderr];
        errnoEnforce(sigemptyset(&pipeSignal) == 0, "initializing stdin signal mask");
        errnoEnforce(sigaddset(&pipeSignal, SIGPIPE) == 0, "selecting stdin SIGPIPE");
        const maskError = pthread_sigmask(SIG_BLOCK, &pipeSignal, &previousMask);
        if (maskError != 0)
            throw new ErrnoException("blocking stdin SIGPIPE", maskError);
        maskSaved = true;
        errnoEnforce(sigpending(&pending) == 0, "reading prior pending stdin signals");
        priorPending = sigismember(&pending, SIGPIPE) == 1;
        priorBlocked = sigismember(&previousMask, SIGPIPE) == 1;

        foreach (index; 0 .. channels.length)
        {
            const fd = channels[index].fileno();
            const flags = fcntl(fd, F_GETFL);
            errnoEnforce(flags >= 0, "reading capture descriptor flags");
            errnoEnforce(fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
                "setting nonblocking capture descriptor");
            watched[index] = pollfd(fd, cast(short)(index == 0 ? POLLOUT : POLLIN), 0);
        }
        version (OSX)
        {
            // XNU delivers a write-generated SIGPIPE to the whole process, not
            // to the writing thread, so blocking it here does not stop another
            // thread (e.g. a parallel unittest worker) from taking the default
            // action. Suppress generation on this descriptor; write() still
            // returns EPIPE. F_SETNOSIGPIPE is <sys/fcntl.h> value 73.
            enum F_SETNOSIGPIPE = 73;
            errnoEnforce(fcntl(channels[0].fileno(), F_SETNOSIGPIPE, 1) == 0,
                "suppressing stdin SIGPIPE");
        }
        size_t offset;
        if (input.length == 0)
            closeChannel(0); // Deliver EOF even when no input was supplied.
        char[64 * 1024] buffer;
        while (watched[0].fd >= 0 || watched[1].fd >= 0 || watched[2].fd >= 0)
        {
            const ready = poll(watched.ptr, cast(nfds_t)watched.length, -1);
            if (ready < 0 && errno == EINTR)
                continue;
            errnoEnforce(ready >= 0, "polling child capture descriptors");
            foreach (index; 0 .. watched.length)
            {
                const events = watched[index].revents;
                if (watched[index].fd < 0 || events == 0)
                    continue;
                if (events & POLLNVAL)
                    throw new ErrnoException("invalid child capture descriptor", EBADF);
                if (index == 0 && (events & (POLLOUT | POLLHUP | POLLERR)))
                {
                    import std.algorithm : min;
                    // Raw writes leave no buffered stdio flush at close. Bound
                    // each transfer and keep partial-write/EINTR/EAGAIN handling.
                    const count = write(watched[0].fd, input.ptr + offset,
                        min(input.length - offset, buffer.length));
                    if (count > 0)
                    {
                        offset += cast(size_t)count;
                        if (offset == input.length)
                            closeChannel(0);
                    }
                    else if (count < 0 && errno == EPIPE)
                    {
                        sawEpipe = true;
                        closeChannel(0); // Keep draining the child's actual result.
                    }
                    else if (count < 0 && errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)
                        throw new ErrnoException("writing child stdin", errno);
                    else
                        enforce(count != 0, "Writing child stdin made no progress");
                }
                else if (index > 0 && (events & (POLLIN | POLLHUP | POLLERR)))
                {
                    const count = read(watched[index].fd, buffer.ptr, buffer.length);
                    if (count > 0)
                        captured[index - 1].put(buffer[0 .. cast(size_t)count]);
                    else if (count == 0)
                        closeChannel(index); // HUP may still have buffered bytes.
                    else if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK)
                        throw new ErrnoException("reading child output", errno);
                }
            }
        }
    }
    catch (Throwable error) { remember(error); }
    cleanup(failure !is null);
    if (failure !is null)
        throw failure;
    string stdoutText = captured[0].data;
    string stderrText = captured[1].data;
    // Preserve byLine().join("\n") exactly on POSIX: remove one final LF,
    // retain interior empty lines, CR bytes and output without a final LF.
    if (stdoutText.length && stdoutText[$ - 1] == '\n')
        stdoutText = stdoutText[0 .. $ - 1];
    if (stderrText.length && stderrText[$ - 1] == '\n')
        stderrText = stderrText[0 .. $ - 1];

    if (echoOutput && stdoutText != "")
        stdout.writeln(stdoutText);
    if (echoOutput && stderrText != "")
        stderr.writeln(stderrText);

    return ProcessResult(status, stdoutText, stderrText);
}

bool isInPath(string name)
{
    import std.algorithm : splitter;
    import std.file : exists, isFile;
    import std.path : buildPath;
    import std.process : environment;
    import std.string : toStringz;
    import core.sys.posix.unistd : access, X_OK;

    auto pathVar = environment.get("PATH", "");
    foreach (dir; pathVar.splitter(':'))
    {
        auto candidate = dir.buildPath(name);
        // isFile guards against a searchable directory of the same name;
        // access(X_OK) ensures the file is actually executable.
        if (candidate.exists && candidate.isFile
            && access(candidate.toStringz, X_OK) == 0)
            return true;
    }
    return false;
}

@("isInPath finds executables on PATH")
unittest
{
    // "ls" should always be available on NixOS / any Linux
    assert(isInPath("ls"));
    assert(!isInPath("nonexistent-binary-abc123"));
}

void spawnProcessInline(string[] args)
{
    import std.logger : tracef;
    import std.exception : enforce;
    import std.process : spawnProcess, wait;

    const bold = "\033[1m";
    const normal = "\033[0m";


    tracef("$ %s%-(%s %)%s", bold, args, normal);

    auto pid = spawnProcess(args);
    enforce(wait(pid) == 0, "Process failed.");
}

@("runProcessWithInputCapture.earlyChildExit")
unittest
{
    import std.array : replicate;
    import std.conv : to;
    import core.sys.posix.signal : sigaction_t, sigaction, sigset_t,
        pthread_sigmask, sigismember, SIG_BLOCK, SIGPIPE;

    sigaction_t actionBefore, actionAfter;
    sigset_t maskBefore, maskAfter;
    assert(sigaction(SIGPIPE, null, &actionBefore) == 0);
    assert(pthread_sigmask(SIG_BLOCK, null, &maskBefore) == 0);
    const input = "x".replicate(1024 * 1024);
    const positive = runProcessWithInputCapture(["timeout", "60", "wc", "-c"], input);
    assert(positive.exitCode == 0);
    assert(positive.stdout.strip == input.length.to!string);
    assert(positive.stderr == "");

    const rejected = runProcessWithInputCapture([
        "timeout", "60", "sh", "-c", "printf rejected >&2; exit 23",
    ], input);
    assert(rejected.exitCode == 23);
    assert(rejected.stdout == "");
    assert(rejected.stderr == "rejected");
    assert(sigaction(SIGPIPE, null, &actionAfter) == 0);
    assert(pthread_sigmask(SIG_BLOCK, null, &maskAfter) == 0);
    assert(actionBefore.sa_handler == actionAfter.sa_handler);
    assert(actionBefore.sa_flags == actionAfter.sa_flags);
    assert(sigismember(&maskBefore, SIGPIPE) == sigismember(&maskAfter, SIGPIPE));
}

@("runProcessWithInputCapture.drainsOutputWhileWriting")
unittest
{
    import std.array : replicate;
    import std.conv : to;
    import std.string : splitLines;

    const line = "x".replicate(100);
    const script = "i=0; while [ $i -lt 2000 ]; do echo " ~ line
        ~ " >&2; i=$((i+1)); done; wc -c";
    const input = "y".replicate(1024 * 1024);
    const result = runProcessWithInputCapture(["timeout", "60", "sh", "-c", script], input);
    assert(result.exitCode == 0);
    assert(result.stdout.strip == input.length.to!string);
    const lines = result.stderr.splitLines;
    assert(lines.length == 2000);
    foreach (actual; lines)
        assert(actual == line);
}

@("runProcessWithInputCapture.preservesCallerPendingSigpipe")
unittest
{
    import std.array : replicate;
    import core.sys.posix.signal : sigset_t, sigemptyset, sigaddset,
        sigpending, sigismember, sigwait, pthread_sigmask, pthread_kill,
        SIGPIPE, SIG_BLOCK, SIG_SETMASK;
    import core.sys.posix.pthread : pthread_self;

    sigset_t blocked, previous, pending;
    assert(sigemptyset(&blocked) == 0);
    assert(sigaddset(&blocked, SIGPIPE) == 0);
    assert(pthread_sigmask(SIG_BLOCK, &blocked, &previous) == 0);
    bool queuedHere;
    scope(exit)
    {
        assert(sigpending(&pending) == 0);
        // Consume only this test's own signal before restoring its old mask.
        // A pre-existing pending caller signal must remain pending.
        if (queuedHere && sigismember(&pending, SIGPIPE) == 1)
        {
            int received;
            assert(sigwait(&blocked, &received) == 0 && received == SIGPIPE);
        }
        assert(pthread_sigmask(SIG_SETMASK, &previous, null) == 0);
    }
    assert(sigpending(&pending) == 0);
    if (sigismember(&pending, SIGPIPE) == 0)
    {
        assert(pthread_kill(pthread_self(), SIGPIPE) == 0);
        queuedHere = true;
    }
    assert(sigpending(&pending) == 0);
    assert(sigismember(&pending, SIGPIPE) == 1,
        "Pending-signal control must be active; inherited SIGPIPE ignore is not a passing control");
    const result = runProcessWithInputCapture([
        "timeout", "60", "sh", "-c", "printf pending-rejected >&2; exit 23",
    ], "x".replicate(1024 * 1024));
    assert(result.exitCode == 23 && result.stderr == "pending-rejected");
    assert(sigpending(&pending) == 0);
    assert(sigismember(&pending, SIGPIPE) == 1);
}

@("runProcessWithInputCapture.preservesOutputLinesAndEof")
unittest
{
    const result = runProcessWithInputCapture([
        "timeout", "60", "sh", "-c",
        `test "$(wc -c)" = 0 || exit 99; printf 'first\n\nlast\r\n\n'; printf 'err\r\n' >&2; exit 7`,
    ], "");
    assert(result.exitCode == 7);
    assert(result.stdout == "first\n\nlast\r\n");
    assert(result.stderr == "err\r");
}
