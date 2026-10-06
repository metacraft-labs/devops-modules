module mcl.commands.hosts;

import core.time : Duration, seconds;
import std.algorithm : filter, map;
import std.array : array, assocArray, join;
import std.conv : to;
import std.file : exists, readText;
import std.format : format;
import std.json : JSONValue, parseJSON, JSONType;
import std.range : empty, iota, repeat, zip;
import std.stdio : stdout, writef, writeln, writefln, stderr;
import std.string : split, strip, startsWith, endsWith;
import std.typecons : tuple;

import argparse : Command, Description, SubCommand, Default, PositionalArgument,
    Placeholder, Optional, matchCmd, NamedArgument, Required, Parse, MutuallyExclusive;

import mcl.utils.json : fromJSON, toJSON;
import mcl.utils.log : errorAndExit;
import mcl.utils.process : execute;

// =============================================================================
// Public Types
// =============================================================================

struct HostEntry
{
    string ipv4;
    string description;
    string user;
    ushort port;
    bool sshSuccess;

    string toString() const
    {
        return description.length > 0 ? ipv4 ~ " (" ~ description ~ ")" : ipv4;
    }

    HostEntry withDefaults(string defaultUser, ushort defaultPort) const
    {
        return HostEntry(
            ipv4,
            description,
            user.length > 0 ? user : defaultUser,
            port > 0 ? port : defaultPort,
            sshSuccess,
        );
    }
}

// =============================================================================
// CLI Argument Definitions
// =============================================================================

@(Command("hosts", "host")
    .Description("Manage remote hosts"))
struct HostsArgs
{
    SubCommand!(
        ScanArgs,
        ExecuteArgs,
        NixRunArgs,
        Default!UnknownCommandArgs
    ) cmd;
}

@(Command("scan")
    .Description("Scan a network for hosts with SSH service running"))
struct ScanArgs
{
    @(NamedArgument(["network", "n"])
        .Required()
        .Placeholder("NETWORK-PREFIX")
        .Description("IPv4 network prefix (e.g., 192.168.1)"))
    string network;

    @(NamedArgument(["start", "s"])
        .Placeholder("NUM")
        .Description("Start of host range (default: 1)"))
    ubyte start = 1;

    @(NamedArgument(["end", "e"])
        .Placeholder("NUM")
        .Description("End of host range (default: 254)"))
    ubyte end = 254;

    @(NamedArgument(["port", "p"])
        .Placeholder("PORT")
        .Description("SSH port to scan (default: 22)"))
    ushort port = 22;

    @(NamedArgument(["timeout", "t"])
        .Placeholder("SECONDS")
        .Description("Connection timeout in seconds (default: 5)")
        .Parse((string s) => s.to!ushort.seconds))
    Duration timeout = 5.seconds;

    @(NamedArgument(["parallel", "P"])
        .Placeholder("COUNT")
        .Description("Number of parallel connections (default: 16)"))
    ushort parallel = 16;

    @(NamedArgument(["ssh-user", "u"])
        .Placeholder("USER")
        .Description("SSH user for fetching hostnames (default: root)"))
    string sshUser = "root";

    @(NamedArgument(["save-keys"])
        .Placeholder("FILE")
        .Description("Save SSH public keys to file"))
    string saveKeysFile;

    @(NamedArgument(["output", "o"])
        .Placeholder("FILE")
        .Description("Output file path for results (JSON format)"))
    string outputFile;

    @(NamedArgument(["merge-file", "m"])
        .Placeholder("FILE")
        .Description("Merge with existing hosts file (CSV/JSON). Known hosts keep their description, new hosts get hostname via SSH"))
    string mergeFile;

    @(NamedArgument(["suppress-warnings", "q"])
        .Description("Suppress SSH warnings (e.g., post-quantum key exchange)"))
    bool suppressWarnings = false;
}

@(Command("nix-run")
    .Description("Run a nix flake output on multiple remote hosts"))
struct NixRunArgs
{
    @(MutuallyExclusive.Required)
    {
        @(NamedArgument(["hosts-file", "f"])
            .Placeholder("FILE")
            .Description("Path to JSON or CSV file with hosts"))
        string hostsFile;

        @(NamedArgument(["scan", "s"])
            .Placeholder("NETWORK-ID")
            .Description("Scan this network for hosts instead of using a file"))
        string scanNetwork;
    }

    @(NamedArgument(["flake"])
        .Required()
        .Placeholder("REF")
        .Description("Flake reference (e.g., github:owner/repo#output, .#package)"))
    string flakeRef;

    @(PositionalArgument(0)
        .Optional()
        .Placeholder("ARGS")
        .Description("Arguments to pass to the flake output"))
    string[] flakeArgs;

    @(NamedArgument(["output", "o"])
        .Placeholder("FILE")
        .Description("Output zip file path"))
    string outputFile;

    @(NamedArgument(["file-extension", "e"])
        .Placeholder("EXT")
        .Description("File extension for output files (default: txt)"))
    string fileExtension = "txt";

    @(NamedArgument(["port", "p"])
        .Placeholder("PORT")
        .Description("SSH port (default: 22)"))
    ushort port = 22;

    @(NamedArgument(["ssh-user", "u"])
        .Placeholder("USER")
        .Description("SSH user (default: root)"))
    string sshUser = "root";

    @(MutuallyExclusive())
    {
        @(NamedArgument(["parallel", "P"])
            .Placeholder("COUNT")
            .Description("Number of parallel connections (default: 1)"))
        ushort parallel = 1;

        @(NamedArgument(["sudo"])
            .Description("Run command with sudo (requires TTY)"))
        bool sudo = false;
    }

    @(NamedArgument(["timeout", "t"])
        .Placeholder("SECONDS")
        .Description("SSH connection timeout in seconds (default: 120)")
        .Parse((string s) => s.to!ushort.seconds))
    Duration timeout = 120.seconds;

    @(NamedArgument(["suppress-warnings", "q"])
        .Description("Suppress SSH warnings (e.g., post-quantum key exchange)"))
    bool suppressWarnings = false;

    @(NamedArgument(["json-output", "j"])
        .Description("Treat command output as JSON and embed it in the output file"))
    bool jsonOutput = false;
}

@(Command("execute")
    .Description("Execute a command on multiple hosts"))
struct ExecuteArgs
{
    @(NamedArgument(["command", "c"])
        .Required()
        .Placeholder("COMMAND")
        .Description("Command to execute on each host"))
    string command;

    @(MutuallyExclusive.Required)
    {
        @(NamedArgument(["hosts-file", "f"])
            .Placeholder("FILE")
            .Description("Path to JSON or CSV file with hosts (columns: ipv4, description)"))
        string hostsFile;

        @(NamedArgument(["scan", "s"])
            .Placeholder("NETWORK-ID")
            .Description("Scan this network for hosts instead of using a file"))
        string scanNetwork;
    }

    @(NamedArgument(["port", "p"])
        .Placeholder("PORT")
        .Description("SSH port (default: 22)"))
    ushort port = 22;

    @(NamedArgument(["ssh-user", "u"])
        .Placeholder("USER")
        .Description("SSH user (default: root)"))
    string sshUser = "root";

    @(MutuallyExclusive())
    {
        @(NamedArgument(["parallel", "P"])
            .Placeholder("COUNT")
            .Description("Number of parallel connections (default: 1)"))
        ushort parallel = 1;

        @(NamedArgument(["sudo"])
            .Description("Run command with sudo (requires TTY)"))
        bool sudo = false;
    }

    @(NamedArgument(["timeout", "t"])
        .Placeholder("SECONDS")
        .Description("SSH connection timeout in seconds (default: 30)")
        .Parse((string s) => s.to!ushort.seconds))
    Duration timeout = 30.seconds;

    @(NamedArgument(["continue-on-error"])
        .Description("Continue executing on other hosts if one fails"))
    bool continueOnError = false;

    @(NamedArgument(["output-dir", "o"])
        .Placeholder("DIR")
        .Description("Save output of each host to a separate file in this directory"))
    string outputDir;

    @(NamedArgument(["output-zip", "z"])
        .Placeholder("FILE")
        .Description("Save output of each host to a zip archive"))
    string outputZip;

    @(NamedArgument(["file-extension", "e"])
        .Placeholder("EXT")
        .Description("File extension for output files (default: txt, requires --output-dir or --output-zip)"))
    string fileExtension = "txt";

    @(NamedArgument(["suppress-warnings", "q"])
        .Description("Suppress SSH warnings (e.g., post-quantum key exchange)"))
    bool suppressWarnings = false;

    @(NamedArgument(["json-output", "j"])
        .Description("Treat command output as JSON and embed it in the output file"))
    bool jsonOutput = false;
}

@(Command(" ").Description(" "))
struct UnknownCommandArgs { }

// =============================================================================
// Main Entry Point
// =============================================================================

/// Main entry point for the hosts command (also aliased as 'host')
export int hosts(HostsArgs args)
{
    return args.cmd.matchCmd!(
        (ScanArgs a) => scan(a),
        (ExecuteArgs a) => executeOnHosts(a),
        (NixRunArgs a) => nixRun(a),
        (UnknownCommandArgs a) => unknownCommand(a)
    );
}

// =============================================================================
// Command Handlers
// =============================================================================

/// Scan a network for hosts with SSH service running
int scan(ScanArgs args)
{
    import std.parallelism : defaultPoolThreads;

    if (args.start > args.end)
    {
        errorAndExit(format!"Invalid range: start (%s) must be <= end (%s)"(args.start, args.end));
        return 1;
    }

    defaultPoolThreads = args.parallel;

    // Load merge file if provided (for merging with existing hosts)
    HostEntry[string] mergeHosts;
    if (args.mergeFile.length > 0)
    {
        writefln("=== Loading merge file: %s ===\n", args.mergeFile);
        auto existingHosts = loadHostsFromFile(args.mergeFile);
        mergeHosts = existingHosts.map!(h => tuple(h.ipv4, h)).assocArray;
        writefln("Loaded %d host(s) from merge file.\n", existingHosts.length);
    }

    writefln("=== Pass 1: Port scanning %s.[%s-%s] on port %s (parallel: %s) ===\n",
        args.network, args.start, args.end, args.port, args.parallel);

    // Pass 1: Parallel port scan to find hosts with SSH
    auto hosts = scanNetworkRange(
        networkPrefix: args.network,
        start: args.start,
        end: args.end,
        port: args.port,
        timeout: args.timeout,
    );

    if (hosts.empty)
    {
        writeln("\nNo hosts with SSH service found.");
        return 0;
    }

    writefln("\n=== Found %d host(s) with SSH service ===\n", hosts.length);

    // Apply CLI defaults to hosts
    hosts = hosts.map!(h => h.withDefaults(args.sshUser, args.port)).array;

    // Pass 2: Fetch hostnames via SSH for all hosts (to verify SSH connectivity)
    writefln("=== Pass 2: Fetching hostnames via SSH (parallel: %s) ===\n", args.parallel);
    hosts = fetchHostnamesParallel(hosts, SshOptions(
        command: "hostname",
        timeout: args.timeout,
        suppressWarnings: args.suppressWarnings,
        acceptNewKeys: false,
    ));

    // Apply merge file descriptions (prefer merge file description over hostname)
    if (args.mergeFile.length > 0)
    {
        hosts = hosts.map!((host) {
            if (auto merged = host.ipv4 in mergeHosts)
                return HostEntry(
                    host.ipv4,
                    merged.description.length > 0 ? merged.description : host.description,
                    merged.user.length > 0 ? merged.user : host.user,
                    merged.port > 0 ? merged.port : host.port,
                    host.sshSuccess,
                );
            return host;
        }).array;
    }

    // Pass 3: Parallel SSH key collection (if requested)
    if (args.saveKeysFile.length > 0)
    {
        writefln("\n=== Pass 3: Saving SSH keys to %s (parallel: %s) ===\n", args.saveKeysFile, args.parallel);
        saveHostKeysParallel(hosts, filename: args.saveKeysFile);
    }

    writeln("\n=== Results ===\n");
    foreach (host; hosts)
    {
        writefln("  %s", host);
    }

    if (args.outputFile.length > 0)
    {
        import std.file : write;
        import std.json : JSONOptions;

        auto json = hosts.toJSON;
        write(args.outputFile, json.toPrettyString(JSONOptions.doNotEscapeSlashes));
        writefln("\nResults saved to: %s", args.outputFile);
    }

    return 0;
}

/// Execute a command on multiple hosts
int executeOnHosts(ExecuteArgs args)
{
    import std.parallelism : defaultPoolThreads;

    defaultPoolThreads = args.parallel;

    HostEntry[] hosts;

    if (args.scanNetwork.length > 0)
    {
        writefln("Scanning network %s.[1-254] for hosts...", args.scanNetwork);
        hosts = scanNetworkRange(
            networkPrefix: args.scanNetwork,
            start: 1,
            end: 254,
            port: args.port,
            timeout: args.timeout,
        );

        if (hosts.empty)
        {
            errorAndExit("No hosts found on the network.");
            return 1;
        }

        writefln("Found %d host(s).\n", hosts.length);
    }
    else
    {
        hosts = loadHostsFromFile(args.hostsFile);

        if (hosts.empty)
        {
            errorAndExit("No hosts found in the file.");
            return 1;
        }

        writefln("Loaded %d host(s) from file.\n", hosts.length);
    }

    // Apply CLI defaults to hosts
    hosts = hosts.map!(h => h.withDefaults(args.sshUser, args.port)).array;

    bool useParallel = args.parallel > 1;

    return executeCommandOnHosts(
        hosts,
        SshOptions(
            command: args.command,
            timeout: args.timeout,
            suppressWarnings: args.suppressWarnings,
            acceptNewKeys: true,
        ),
        continueOnError: args.continueOnError,
        useParallel: useParallel,
        outputDir: args.outputDir,
        outputZip: args.outputZip,
        fileExtension: args.fileExtension,
        useSudo: args.sudo,
        jsonOutput: args.jsonOutput,
    );
}

/// Run a nix flake output on multiple remote hosts
int nixRun(NixRunArgs args)
{
    import std.process : escapeShellCommand;

    // Build the nix run command (escape for remote shell execution)
    // Wrap in 'bash -l -c' to ensure login scripts are sourced (for PATH setup)
    // Use double quotes for outer wrapper since inner command uses single quotes
    auto innerCommand = escapeShellCommand(
        ["nix",
        "--extra-experimental-features", "flakes nix-command",
        "run", "--accept-flake-config", "--refresh",
        args.flakeRef,
        "--"] ~ args.flakeArgs
    );
    auto nixCommand = `bash -l -c "` ~ innerCommand ~ `"`;

    return executeOnHosts(ExecuteArgs(
        command: nixCommand,
        hostsFile: args.hostsFile,
        scanNetwork: args.scanNetwork,
        port: args.port,
        sshUser: args.sshUser,
        parallel: args.parallel,
        timeout: args.timeout,
        continueOnError: true,
        outputZip: args.outputFile,
        fileExtension: args.fileExtension,
        suppressWarnings: args.suppressWarnings,
        sudo: args.sudo,
        jsonOutput: args.jsonOutput,
    ));
}

int unknownCommand(UnknownCommandArgs)
{
    errorAndExit("Unknown command. Use --help for a list of available commands.");
    return 1;
}

// =============================================================================
// Implementation Details - File Loading
// =============================================================================

/// Load hosts from a JSON or CSV file
private HostEntry[] loadHostsFromFile(string filePath)
{
    import std.csv : csvReader;

    if (!exists(filePath))
    {
        errorAndExit("File not found: " ~ filePath);
        return [];
    }

    string content = readText(filePath).strip();

    if (content.length == 0)
    {
        errorAndExit("File is empty: " ~ filePath);
        return [];
    }

    // Detect file format based on extension or content
    if (filePath.endsWith(".json") || content.startsWith("["))
    {
        return parseJSON(content).fromJSON!(HostEntry[]);
    }
    else
    {
        return csvReader!HostEntry(content, null).array;
    }
}

// =============================================================================
// Implementation Details - Network Scanning
// =============================================================================

private struct SshProbeResult
{
    string ip;
    bool success;
}

/// Scan a network range for SSH hosts using pure D sockets (parallelized)
private HostEntry[] scanNetworkRange(string networkPrefix, ubyte start, ubyte end,
    ushort port, Duration timeout)
{
    import std.parallelism : parallel;

    // Generate list of IPs to scan
    auto ips = iota(start, end + 1)
        .map!(i => format!"%s.%d"(networkPrefix, i));

    writefln("Probing %d hosts...", ips.length);
    auto results = new SshProbeResult[](ips.length);
    shared size_t completed = 0;

    foreach (idx, ip; parallel(ips, 1))
    {
        results[idx] = probeSshPort(ip, port, timeout);
        updateProgress(completed, ips.length, "hosts checked");
    }

    writeln();

    // Collect successful results (description is empty, will be filled by hostname fetch)
    return results
        .filter!(r => r.success)
        .map!(r => HostEntry(r.ip, ""))
        .array;
}

/// Probe a single host for SSH service using pure D sockets
private SshProbeResult probeSshPort(string ip, ushort port, Duration timeout)
{
    import std.socket : TcpSocket, InternetAddress, SocketOption, SocketOptionLevel;

    SshProbeResult result;
    result.ip = ip;
    result.success = false;

    TcpSocket socket;
    try
    {
        socket = new TcpSocket();
        scope(exit) {
            if (socket !is null)
                socket.close();
        }

        // Set socket timeout
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.SNDTIMEO, timeout);
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, timeout);

        // Attempt connection
        auto addr = new InternetAddress(ip, port);
        socket.connect(addr);

        // Try to read SSH banner (SSH servers send version string on connect)
        char[256] buffer;
        auto received = socket.receive(buffer[]);

        if (received > 0)
        {
            // Verify it's actually SSH (banner starts with "SSH-")
            result.success = buffer[0 .. received].startsWith("SSH-");
        }
    }
    catch (Exception e)
    {
        // Connection failed or timed out
    }

    return result;
}

// =============================================================================
// Implementation Details - SSH Operations
// =============================================================================

/// Build complete SSH command arguments including the remote command
private string[] buildSshArgs(HostEntry host, SshOptions opts)
{
    return [
        "ssh",
        "-o", "ConnectTimeout=" ~ opts.timeout.total!"seconds".to!string,
    ] ~ (opts.acceptNewKeys
        ? ["-o", "StrictHostKeyChecking=accept-new"]
        : ["-o", "UserKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=no"]
    ) ~ (opts.suppressWarnings
        ? ["-o", "LogLevel=ERROR"]
        : []
    ) ~ (opts.allocateTty
        ? ["-t"]  // Allocate TTY for interactive input (e.g., sudo password)
        : ["-o", "BatchMode=yes"]  // Non-interactive mode
    ) ~ [
        "-p", host.port.to!string,
        host.user ~ "@" ~ host.ipv4,
        opts.command,
    ];
}

/// Fetch hostnames for a list of hosts (parallel)
private HostEntry[] fetchHostnamesParallel(HostEntry[] hosts, SshOptions opts)
{
    import std.parallelism : parallel;
    auto results = new SshCommandResult[](hosts.length);
    shared size_t completed = 0;

    foreach (idx, host; parallel(hosts))
    {
        results[idx] = executeSshCommand(host, opts, suppressOutput: true);
        updateProgress(completed, hosts.length, "hostnames fetched");
    }

    writeln();

    // Build result with hostnames as description and SSH success status
    return zip(hosts, results)
        .map!(pair => HostEntry(pair[0].ipv4, pair[1].success ? pair[1].output : "", pair[0].user, pair[0].port, pair[1].success))
        .array;
}

/// Save SSH public keys to a file (parallel)
private void saveHostKeysParallel(HostEntry[] hosts, string filename)
{
    import std.file : append;
    import std.parallelism : parallel;

    // Collect keys in parallel
    auto allKeys = new string[](hosts.length);
    shared size_t completed = 0;

    foreach (idx, host; parallel(hosts))
    {
        try
        {
            allKeys[idx] = execute(["ssh-keyscan", "-p", host.port.to!string, "-4", host.ipv4], printCommand: false, logErrors: false);
        }
        catch (Exception e)
        {
            allKeys[idx] = "";
        }

        updateProgress(completed, hosts.length, "keys collected");
    }

    writeln();

    // Write all non-empty keys to file
    foreach (keys; allKeys.filter!(k => k.length > 0))
    {
        append(filename, keys ~ "\n");
    }
}

/// Execute a command on a list of hosts via SSH
private int executeCommandOnHosts(HostEntry[] hosts, SshOptions opts, bool continueOnError, bool useParallel, string outputDir, string outputZip, string fileExtension, bool useSudo = false, bool jsonOutput = false)
{
    import std.parallelism : parallel;
    import std.zip : ZipArchive, ArchiveMember;

    // In parallel mode with stop-on-error, fall back to sequential to ensure proper stopping
    if (useParallel && !continueOnError)
    {
        stderr.writeln("Note: --continue-on-error=false requires sequential execution. Using --parallel=1.");
        useParallel = false;
    }

    // Create output directory if specified
    if (outputDir.length > 0 && !exists(outputDir))
    {
        import std.file : mkdirRecurse;
        mkdirRecurse(outputDir);
    }

    int failureCount = 0;
    int successCount = 0;

    writefln("Executing command on %d host(s)...\n", hosts.length);
    writefln("Command: %s%s\n", useSudo ? "sudo " : "", opts.command);
    writeln("─".repeat(60).join);

    SshCommandResult[] failures;
    SshCommandResult[] successes;

    if (useParallel)
    {
        // Parallel execution with progress indicator
        auto results = new SshCommandResult[](hosts.length);
        shared size_t completed = 0;

        foreach (idx, host; parallel(hosts))
        {
            results[idx] = executeSshCommand(host, opts, suppressOutput: true);
            updateProgress(completed, hosts.length, "hosts completed");
        }

        writeln();

        // Collect results
        foreach (result; results)
        {
            if (result.success)
            {
                successCount++;
                successes ~= result;
                if (outputDir.length > 0)
                    saveHostOutput(outputDir, result.host, result.output, fileExtension, jsonOutput);
            }
            else
                failures ~= result;
        }
        failureCount = cast(int) failures.length;
    }
    else
    {
        // Sequential execution
        foreach (host; hosts)
        {
            // If sudo is enabled, use stdin for password prompt and hide local echo
            auto hostOpts = opts;
            if (useSudo)
            {
                hostOpts.command = "sudo -S " ~ opts.command;
                hostOpts.allocateTty = false;
                hostOpts.disableLocalEcho = true;
            }

            auto result = executeSshCommand(host, hostOpts, suppressOutput: false);

            if (result.success)
            {
                successCount++;
                successes ~= result;
                if (outputDir.length > 0)
                    saveHostOutput(outputDir, result.host, result.output, fileExtension, jsonOutput);
            }
            else
            {
                failureCount++;
                failures ~= result;
                if (!continueOnError)
                {
                    writeln("\nStopping due to error. Use --continue-on-error to continue.");
                    return 1;
                }
            }
        }
    }

    writeln("─".repeat(60).join);
    writefln("\nSummary: %d succeeded, %d failed out of %d total", successCount, failureCount, hosts.length);

    // Print failed hosts with error output
    if (failures.length > 0)
    {
        import std.process : escapeShellCommand;

        writeln("\nFailed hosts:\n");
        foreach (failure; failures)
        {
            writefln("[%s]", failure.host);
            writefln("  $ %s", escapeShellCommand(failure.sshArgs));
            auto failureText = failure.errorOutput.length > 0
                ? failure.errorOutput
                : failure.output;
            if (failureText.length > 0)
            {
                // Indent each line of the error output
                foreach (line; failureText.split("\n"))
                {
                    writefln("  %s", line);
                }
            }
            writeln();
        }
    }

    // Create zip archive if requested
    if (outputZip.length > 0 && successes.length > 0)
    {
        import std.file : write;

        auto archive = new ZipArchive();
        foreach (result; successes)
        {
            auto filename = result.host.description.length > 0
                ? result.host.description ~ "." ~ fileExtension
                : result.host.ipv4 ~ "." ~ fileExtension;

            auto member = new ArchiveMember();
            member.name = filename;
            auto content = fileExtension == "json"
                ? formatHostOutput(result.host, result.output, jsonOutput)
                : result.output;
            member.expandedData = cast(ubyte[]) content.dup;
            archive.addMember(member);
        }
        write(outputZip, archive.build());
        writefln("\nResults saved to: %s (%d files)", outputZip, successes.length);
    }
    else if (outputDir.length > 0)
        writefln("Output saved to: %s/", outputDir);

    return failureCount > 0 ? 1 : 0;
}

/// Save command output for a host to a file
private void saveHostOutput(string outputDir, HostEntry host, string output, string fileExtension, bool jsonOutput)
{
    import std.file : write;
    import std.path : buildPath;

    auto filename = host.description.length > 0
        ? host.ipv4 ~ "_" ~ host.description ~ "." ~ fileExtension
        : host.ipv4 ~ "." ~ fileExtension;

    auto content = fileExtension == "json"
        ? formatHostOutput(host, output, jsonOutput)
        : output;

    write(buildPath(outputDir, filename), content);
}

/// Format host output as JSON
private string formatHostOutput(HostEntry host, string output, bool jsonOutput)
{
    import std.json : JSONOptions;

    auto json = JSONValue([
        "ipv4": JSONValue(host.ipv4),
        "description": JSONValue(host.description),
        "output": jsonOutput ? parseJSON(output) : JSONValue(output),
    ]);

    return json.toPrettyString(JSONOptions.doNotEscapeSlashes);
}

private struct SshOptions
{
    string command;
    Duration timeout;
    bool suppressWarnings;  // suppress SSH warnings (LogLevel=ERROR)
    bool acceptNewKeys;     // use StrictHostKeyChecking=accept-new (safer for commands)
    bool allocateTty;       // allocate pseudo-TTY (-t flag) for interactive input
    bool disableLocalEcho;  // disable local echo for sudo password input over stdin
}

private struct SshCommandResult
{
    bool success;
    string output;
    string errorOutput;
    HostEntry host;
    string[] sshArgs;
}

/// Execute a single SSH command on a host
private SshCommandResult executeSshCommand(HostEntry host, SshOptions opts, bool suppressOutput = false, bool stripOutput = true)
{
    import std.process : pipeProcess, wait, Redirect;
    import core.thread : Thread;
    import core.sys.posix.termios : tcgetattr, tcsetattr, termios, ECHO, TCSANOW;
    import core.sys.posix.unistd : isatty, STDIN_FILENO;

    if (!suppressOutput)
        writefln("\n[%s]", host);

    auto args = buildSshArgs(host, opts);

    try
    {
        termios original;
        bool restoreEcho = false;
        if (opts.disableLocalEcho && isatty(STDIN_FILENO) != 0 && tcgetattr(STDIN_FILENO, &original) == 0)
        {
            auto updated = original;
            updated.c_lflag &= ~ECHO;
            if (tcsetattr(STDIN_FILENO, TCSANOW, &updated) == 0)
                restoreEcho = true;
        }
        scope(exit)
        {
            if (restoreEcho)
                tcsetattr(STDIN_FILENO, TCSANOW, &original);
        }

        // Use pipeProcess with stdout/stderr redirected to pipes, but stdin inherited
        // from parent so user can interact (e.g., for sudo password prompts).
        // Read in chunks (not lines) to handle prompts without trailing newlines.
        auto redirect = Redirect.stdout | Redirect.stderr;
        auto pipes = pipeProcess(args, redirect);

        // Read stdout/stderr in parallel, streaming stderr separately and capturing stdout only.
        ubyte[] stdoutBytes;
        ubyte[] stderrBytes;

        auto stdoutThread = new Thread({
            foreach (chunk; pipes.stdout.byChunk(1))
            {
                stdoutBytes ~= chunk;
                if (!suppressOutput)
                {
                    stdout.rawWrite(chunk);
                    stdout.flush();
                }
            }
        });

        auto stderrThread = new Thread({
            foreach (chunk; pipes.stderr.byChunk(1))
            {
                stderrBytes ~= chunk;
                if (!suppressOutput)
                {
                    stderr.rawWrite(chunk);
                    stderr.flush();
                }
            }
        });

        stdoutThread.start();
        stderrThread.start();

        auto status = wait(pipes.pid);
        stdoutThread.join();
        stderrThread.join();

        auto output = stripOutput
            ? (cast(string) stdoutBytes).strip()
            : cast(string) stdoutBytes;
        auto errorOutput = cast(string) stderrBytes;

        if (!suppressOutput)
            writeln();  // Ensure newline after output

        if (status != 0)
        {
            if (!suppressOutput)
                writefln("  [FAILED]");
            return SshCommandResult(false, output, errorOutput, host, args);
        }

        if (!suppressOutput)
            writeln("  [OK]");
        return SshCommandResult(true, output, errorOutput, host, args);
    }
    catch (Exception e)
    {
        if (!suppressOutput)
            writefln("  [FAILED]");
        return SshCommandResult(false, "", e.msg, host, args);
    }
}

// =============================================================================
// Implementation Details - Helpers
// =============================================================================

/// Thread-safe progress update helper
private void updateProgress(ref shared size_t completed, size_t total, string action)
{
    import core.atomic : atomicOp;

    auto current = atomicOp!"+="(completed, 1);
    synchronized
    {
        writef("\rProgress: %d/%d %s", current, total, action);
        stdout.flush();
    }
}
