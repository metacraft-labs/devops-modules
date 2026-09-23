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

    auto pipes = pipeProcess(args, Redirect.stdin | Redirect.stdout | Redirect.stderr);
    pipes.stdin.write(input);
    pipes.stdin.close();
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
