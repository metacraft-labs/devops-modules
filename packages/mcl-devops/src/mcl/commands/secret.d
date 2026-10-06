module mcl.commands.secret;

import std.algorithm : filter, map, each, sort, startsWith;
import std.array : array, join, appender;
import std.json : JSONValue;
import std.digest.sha : sha256Of, toHexString;
import std.file : exists, isDir, dirEntries, SpanMode, mkdirRecurse,
    remove, write, read, deleteme;
import std.format : format;
import std.path : buildPath, baseName, stripExtension, dirName;
import std.process : environment;
import std.logger : infof, tracef, warningf, errorf;
import std.stdio : writeln, writefln, stderr;
import std.regex : ctRegex, matchFirst;
import std.string : replace, split, strip, endsWith;
import std.typecons : Nullable;

import argparse : AllowedValues, Command, Description, NamedArgument, Placeholder,
    Required, SubCommand, Default, matchCmd;

import sparkles.test_utils.tmpfs : TmpFS;

import mcl.utils.json : fromJSON, toJSON;
import mcl.utils.log : errorAndExit;
import mcl.utils.nix : nix;
import mcl.utils.path : rootDir;
import mcl.utils.process : execute, isInPath, spawnProcessInline;
import std.conv : to;

// =============================================================================
// Constants
// =============================================================================

/// Default secrets directory path for VM configurations.
/// Used when the `--vm` flag is specified, pointing to the default VM
/// configuration's secrets folder relative to the repository root.
/// NOTE: This must be kept in sync with the `secretDir` variable in `modules/secrets.nix`.
enum DEFAULT_VM_SECRETS_PATH = "./modules/default-vm-config/secrets/";

// =============================================================================
// CLI Argument Definitions
// =============================================================================

enum ConfigurationType
{
    @AllowedValues("nixos", "nixosConfigurations")
    nixosConfigurations,

    @AllowedValues("nix-darwin", "darwinConfigurations")
    darwinConfigurations,
}

@(Command("secret")
    .Description("Manage age-encrypted secrets for NixOS machines"))
struct SecretArgs
{
    @(NamedArgument(["machine", "m"])
        .Placeholder("NAME")
        .Description("Machine for which to manage secrets"))
    string machine;

    @(NamedArgument(["configuration-type"])
        .Placeholder("TYPE")
        .Description("Type of configurations, either `nixos`/`nixosConfigurations` or `nix-darwin`/`darwinConfigurations`"))
    ConfigurationType configurationType = ConfigurationType.nixosConfigurations;

    @(NamedArgument(["vm"])
        .Description("Use the vmVariant configuration"))
    bool vm;

    @(NamedArgument(["extra-nix-option"])
        .Description("Extra options to pass to nix commands (can be specified multiple times)")
        .Placeholder("OPTION"))
    string[] extraNixOptions;

    @(NamedArgument(["identity", "i"])
        .Placeholder("PATH")
        .Description("Age identity file to use for decryption"))
    string identity;

    SubCommand!(
        SecretEditArgs,
        SecretReEncryptArgs,
        SecretReEncryptAllArgs,
        SecretVerifyArgs,
        SecretListArgs,
        Default!UnknownCommandArgs
    ) cmd;
}

@(Command(" ").Description(" "))
struct UnknownCommandArgs { }

@(Command("edit")
    .Description("Encrypt or edit a single secret for a service"))
struct SecretEditArgs
{
    @(NamedArgument(["service"])
        .Required()
        .Placeholder("NAME")
        .Description("Service for which to manage secrets"))
    string service;

    @(NamedArgument(["secret"])
        .Required()
        .Placeholder("NAME")
        .Description("Secret you want to encrypt"))
    string secret;

    @(NamedArgument(["secrets-folder"])
        .Placeholder("PATH")
        .Description("Specifies the location where secrets are saved"))
    string secretsFolder;
}

@(Command("re-encrypt")
    .Description("Re-encrypt all secrets for a single service"))
struct SecretReEncryptArgs
{
    @(NamedArgument(["service"])
        .Required()
        .Placeholder("NAME")
        .Description("Service for which to re-encrypt secrets"))
    string service;

    @(NamedArgument(["secrets-folder"])
        .Placeholder("PATH")
        .Description("Specifies the location where secrets are saved"))
    string secretsFolder;
}

@(Command("re-encrypt-all")
    .Description("Re-encrypt all secrets for all services on a machine"))
struct SecretReEncryptAllArgs
{
    @(NamedArgument(["config-path"])
        .Placeholder("PATH")
        .Description("Override the configPath from NixOS configuration"))
    string configPath;
}

@(Command("verify")
    .Description("Verify a secret decrypts and that declared recipients match the .age header"))
struct SecretVerifyArgs
{
    @(NamedArgument(["service"])
        .Required()
        .Placeholder("NAME")
        .Description("Service to which the secret belongs"))
    string service;

    @(NamedArgument(["secret"])
        .Required()
        .Placeholder("NAME")
        .Description("Secret to verify"))
    string secret;

    @(NamedArgument(["secrets-folder"])
        .Placeholder("PATH")
        .Description("Specifies the location where secrets are saved"))
    string secretsFolder;
}

@(Command("list")
    .Description("List services and their secrets for a machine"))
struct SecretListArgs
{
    @(NamedArgument(["json"])
        .Description("Output as JSON"))
    bool json;

    @(NamedArgument(["include-vms"])
        .Description("Include VM configurations (VMs are hidden by default)"))
    bool includeVMs;
}

// =============================================================================
// Public Entry Point
// =============================================================================

export int secret(SecretArgs args)
{
    return args.cmd.matchCmd!(
        (SecretEditArgs a) => secretEdit(args, a),
        (SecretReEncryptArgs a) => secretReEncrypt(args, a),
        (SecretReEncryptAllArgs a) => secretReEncryptAll(args, a),
        (SecretVerifyArgs a) => secretVerify(args, a),
        (SecretListArgs a) => secretList(args, a),
        (UnknownCommandArgs _) => unknownCommand(),
    );
}

// =============================================================================
// Subcommand Handlers
// =============================================================================

private int secretEdit(SecretArgs common, SecretEditArgs args)
{
    requireMachine(common);
    validateVmFlag(common.vm, common.configurationType);

    auto tmpfs = TmpFS.create("mcl-secret-identity-keys");
    const confAttr = common.configurationType.to!string;
    auto info = resolveServiceInfo(common, confAttr, args.service);

    auto secretsFolder = args.secretsFolder
        ? args.secretsFolder
        : common.vm
            ? DEFAULT_VM_SECRETS_PATH ~ args.service
            : info.configPath.buildPath("secrets", args.service);

    auto secretFile = secretsFolder.buildPath(args.secret ~ ".age");
    editSecret(secretFile, info.recipients, resolveIdentity(common.identity, tmpfs));
    return 0;
}

private int secretReEncrypt(SecretArgs common, SecretReEncryptArgs args)
{
    requireMachine(common);
    validateVmFlag(common.vm, common.configurationType);

    auto tmpfs = TmpFS.create("mcl-secret-identity-keys");
    const confAttr = common.configurationType.to!string;
    auto info = resolveServiceInfo(common, confAttr, args.service);

    auto secretsFolder = args.secretsFolder.length > 0
        ? args.secretsFolder
        : common.vm
            ? DEFAULT_VM_SECRETS_PATH ~ args.service
            : info.configPath.buildPath("secrets", args.service);

    reEncryptFolder(secretsFolder, info.recipients, resolveIdentity(common.identity, tmpfs));
    return 0;
}

private int secretReEncryptAll(SecretArgs common, SecretReEncryptAllArgs args)
{
    requireMachine(common);
    validateVmFlag(common.vm, common.configurationType);

    auto tmpfs = TmpFS.create("mcl-secret-identity-keys");
    const confAttr = common.configurationType.to!string;
    auto allInfo = resolveAllServicesInfo(common, confAttr);
    auto machineFolder = args.configPath.length > 0
        ? args.configPath
        : allInfo.configPath;
    auto identityArgs = resolveIdentity(common.identity, tmpfs);

    foreach (service, recipients; allInfo.serviceRecipients)
    {
        writeln("Re-encrypting secrets for service ", service);
        auto secretsFolder = common.vm
            ? DEFAULT_VM_SECRETS_PATH ~ service
            : machineFolder.buildPath("secrets", service);

        reEncryptFolder(secretsFolder, recipients, identityArgs);
    }

    return 0;
}

private int secretVerify(SecretArgs common, SecretVerifyArgs args)
{
    requireMachine(common);
    validateVmFlag(common.vm, common.configurationType);

    auto tmpfs = TmpFS.create("mcl-secret-identity-keys");
    const confAttr = common.configurationType.to!string;
    auto info = resolveServiceInfo(common, confAttr, args.service);

    auto secretsFolder = args.secretsFolder.length > 0
        ? args.secretsFolder
        : common.vm
            ? DEFAULT_VM_SECRETS_PATH ~ args.service
            : info.configPath.buildPath("secrets", args.service);

    auto secretFile = secretsFolder.buildPath(args.secret ~ ".age");
    return verifySecret(secretFile, info.recipients, resolveIdentity(common.identity, tmpfs), args.service);
}

private int secretList(SecretArgs common, SecretListArgs args)
{
    const confAttr = common.configurationType.to!string;

    if (common.machine.length > 0)
    {
        auto info = resolveListInfo(common, confAttr);

        if (args.json)
            writeln(info.toJSON.toPrettyString);
        else
        {
            foreach (svc; info.services.keys.dup.sort.array)
            {
                writeln(svc ~ ":");
                foreach (secret; info.services[svc].dup.sort.array)
                    writeln("  - " ~ secret);
            }
        }
    }
    else
    {
        auto info = resolveAllMachinesListInfo(common, args, confAttr);

        if (args.json)
            writeln(info.machines.toJSON.toPrettyString);
        else
        {
            foreach (machine; info.machines.keys.dup.sort.array)
            {
                writeln(machine ~ ":");
                auto ms = info.machines[machine];
                if (!ms.error.isNull)
                    writeln("  ERROR (see stderr for details)");
                else
                    foreach (svc; ms.services.keys.dup.sort.array)
                    {
                        writeln("  " ~ svc ~ ":");
                        foreach (secret; ms.services[svc].dup.sort.array)
                            writeln("    - " ~ secret);
                    }
            }
        }
    }

    return 0;
}

private int unknownCommand()
{
    errorAndExit("Unknown command. Use --help for a list of available commands.");
    assert(0);
}

// =============================================================================
// Age Operations
// =============================================================================

private void editSecret(string secretFile, string[] recipients, string[] identityArgs)
{
    tracef("editSecret: secretFile=%s, recipients=%s, identityArgs=%s",
        secretFile, recipients, identityArgs);

    if (recipients.length == 0)
        errorAndExit("No recipients found for encryption.");

    auto cleartextFile = deleteme;
    scope (exit)
    {
        if (cleartextFile.exists)
            remove(cleartextFile);
    }

    // Decrypt existing file if present
    if (secretFile.exists)
    {
        infof("Decrypting existing secret: %s", secretFile);
        auto decryptCmd = ["age", "--decrypt"] ~ identityArgs ~ ["-o", cleartextFile, "--", secretFile];
        spawnProcessInline(decryptCmd);
    }
    else
    {
        infof("Secret file does not exist yet, creating new: %s", secretFile);
    }

    // Open editor
    auto editor = environment.get("EDITOR", "vim");
    infof("Opening editor: %s %s", editor, cleartextFile);
    spawnProcessInline([editor, cleartextFile]);

    if (!cleartextFile.exists)
    {
        writeln("No file saved, skipping encryption.");
        return;
    }

    auto cleartextData = read(cleartextFile);
    tracef("Cleartext data size: %s bytes", cleartextData.length);

    // Ensure output directory exists
    auto outputDir = secretFile.dirName;
    if (!outputDir.exists)
    {
        infof("Creating output directory: %s", outputDir);
        mkdirRecurse(outputDir);
    }

    // Encrypt with all recipients via stdin to avoid cleartext in process list (ps)
    import std.process : pipeProcess, wait, Redirect;
    auto encryptCmd = ["age", "--encrypt", "--armor"]
        ~ recipientArgs(recipients)
        ~ ["-o", secretFile]
        ~ ["-"];  // Read from stdin
    infof("Encrypting to %s with %s recipient(s)", secretFile, recipients.length);
    tracef("Encrypt command: %-(%s %)", encryptCmd);
    auto pipes = pipeProcess(encryptCmd, Redirect.stdin | Redirect.stdout | Redirect.stderr);
    // NOTE: stdout/stderr are only drained after this write completes, so this
    // can deadlock if `age` emits armored output filling the OS pipe buffer
    // (16 pages by default on Linux) before all of stdin is consumed. Safe in
    // practice because secrets are small; a large secret would require draining
    // concurrently (e.g. writing stdin on a separate thread).
    pipes.stdin.rawWrite(cleartextData);
    pipes.stdin.close();

    auto stdoutOutput = pipes.stdout.byLine().join("\n").to!string;
    auto stderrOutput = pipes.stderr.byLine().join("\n").to!string;
    pipes.stdout.close();
    pipes.stderr.close();
    auto status = wait(pipes.pid);

    if (status != 0)
    {
        errorf("Encryption failed (exit code %s)\nstdout: %s\nstderr: %s",
            status, stdoutOutput, stderrOutput);
        errorAndExit("Encryption failed (exit code " ~ status.to!string ~ "): " ~ stderrOutput);
    }

    tracef("Encryption stdout: %s", stdoutOutput);
    tracef("Encryption stderr: %s", stderrOutput);
    infof("Successfully encrypted secret to %s", secretFile);
}

private void reEncryptFolder(string secretsFolder, string[] recipients, string[] identityArgs)
{
    tracef("reEncryptFolder: secretsFolder=%s, recipients=%s, identityArgs=%s",
        secretsFolder, recipients, identityArgs);

    if (!secretsFolder.exists)
        errorAndExit("Secrets folder does not exist: " ~ secretsFolder);

    if (recipients.length == 0)
        errorAndExit("No recipients found for encryption.");

    auto ageFiles = dirEntries(secretsFolder, "*.age", SpanMode.shallow)
        .map!(e => e.name)
        .array;

    if (ageFiles.length == 0)
    {
        writeln("No .age files found in ", secretsFolder);
        return;
    }

    infof("Re-encrypting %s file(s) in %s", ageFiles.length, secretsFolder);

    foreach (ageFile; ageFiles)
    {
        auto secretName = ageFile.baseName.stripExtension;
        writeln("  Re-encrypting ", secretName);

        auto cleartextFile = deleteme;
        scope (exit)
        {
            if (cleartextFile.exists)
                remove(cleartextFile);
        }

        // Decrypt
        infof("Decrypting %s", ageFile);
        auto decryptCmd = ["age", "--decrypt"] ~ identityArgs ~ ["-o", cleartextFile, "--", ageFile];
        spawnProcessInline(decryptCmd);

        // Re-encrypt via stdin to avoid cleartext in process list (ps)
        import std.process : pipeProcess, wait, Redirect;
        auto cleartextData = read(cleartextFile);
        auto encryptCmd = ["age", "--encrypt", "--armor"]
            ~ recipientArgs(recipients)
            ~ ["-o", ageFile]
            ~ ["-"];  // Read from stdin
        tracef("Re-encrypt command: %-(%s %)", encryptCmd);
        auto pipes = pipeProcess(encryptCmd, Redirect.stdin | Redirect.stdout | Redirect.stderr);
        // NOTE: stdout/stderr are only drained after this write completes, so
        // this can deadlock if `age` emits armored output filling the OS pipe
        // buffer (16 pages by default on Linux) before all of stdin is consumed.
        // Safe in practice because secrets are small; a large secret would
        // require draining concurrently (e.g. writing stdin on a separate thread).
        pipes.stdin.rawWrite(cleartextData);
        pipes.stdin.close();

        auto stdoutOutput = pipes.stdout.byLine().join("\n").to!string;
        auto stderrOutput = pipes.stderr.byLine().join("\n").to!string;
        pipes.stdout.close();
        pipes.stderr.close();
        auto status = wait(pipes.pid);

        if (status != 0)
        {
            errorf("Re-encryption of %s failed (exit code %s)\nstdout: %s\nstderr: %s",
                ageFile, status, stdoutOutput, stderrOutput);
            errorAndExit("Re-encryption failed (exit code " ~ status.to!string ~ "): " ~ stderrOutput);
        }

        tracef("Re-encryption stdout: %s", stdoutOutput);
        tracef("Re-encryption stderr: %s", stderrOutput);
    }

    infof("Successfully re-encrypted %s file(s)", ageFiles.length);
}

private int verifySecret(string secretFile, string[] recipients, string[] identityArgs, string service)
{
    import std.process : pipeProcess, wait, Redirect;
    import std.path : absolutePath;

    if (!secretFile.exists)
        errorAndExit("Secret file does not exist: " ~ secretFile);

    // Decrypt to memory: never write plaintext to disk, never print it.
    auto decryptCmd = ["age", "--decrypt"] ~ identityArgs ~ ["--", secretFile];
    auto pipes = pipeProcess(decryptCmd, Redirect.stdout | Redirect.stderr);

    auto buf = appender!(ubyte[])();
    foreach (chunk; pipes.stdout.byChunk(4096))
        buf.put(chunk);

    auto stderrBuf = appender!(ubyte[])();
    foreach (chunk; pipes.stderr.byChunk(4096))
        stderrBuf.put(chunk);

    auto status = wait(pipes.pid);
    if (status != 0)
    {
        import std.conv : to;
        auto stderrText = (cast(char[]) stderrBuf.data).idup;
        stderr.writeln("DECRYPT FAILED — none of the tried identities matched a recipient (or wrong passphrase).");
        if (identityArgs.length > 0)
        {
            stderr.writeln("Tried identities:");
            for (size_t i = 1; i < identityArgs.length; i += 2)
                stderr.writeln("  ", identityArgs[i]);
        }
        if (stderrText.strip.length > 0)
            stderr.writeln("age stderr: ", stderrText.strip);
        return 1;
    }

    auto plaintext = buf.data;
    if (plaintext.length == 0)
    {
        stderr.writeln("DECRYPT FAILED — empty plaintext");
        return 1;
    }

    auto digest = sha256Of(plaintext);
    auto sha = toHexString(digest).idup;

    writeln("OK");
    writeln("  file:           ", secretFile.absolutePath);
    writefln("  plaintext_size: %d bytes", plaintext.length);
    writeln("  plaintext_sha:  ", sha);
    writeln();

    // Section 2: declared recipients from the Nix module.
    writefln("Declared recipients (from mcl.secrets.services.%s.recipients, %d):",
        service, recipients.length);
    foreach (pubkey; recipients)
    {
        auto fields = pubkey.strip.split;
        string type = fields.length >= 1 ? fields[0] : "<unknown>";
        string comment;
        if (fields.length >= 3)
        {
            comment = fields[2 .. $].join(" ");
        }
        else if (fields.length >= 2)
        {
            // No comment — synthesise a short fingerprint from the key material.
            auto material = fields[1];
            auto fp = material.length > 12 ? material[0 .. 12] : material;
            comment = "<no-comment fp:" ~ fp ~ "...>";
        }
        else
        {
            comment = "<malformed pubkey>";
        }
        writefln("  %-14s %s", type, comment);
    }
    writeln();

    // Section 3: actual encrypted stanzas in the .age header.
    auto headerBytes = cast(string) read(secretFile);
    auto stanzaTypes = parseAgeRecipientStanzas(headerBytes);
    writefln("Encrypted recipient stanzas in .age (%d):", stanzaTypes.length);
    string[] sortedTypes = stanzaTypes.dup;
    sortedTypes.sort();
    int[string] typeCounts;
    foreach (t; sortedTypes)
        typeCounts[t] = (t in typeCounts) ? typeCounts[t] + 1 : 1;
    // Print each unique type once with its count, preserving sorted order.
    bool[string] printed;
    foreach (t; sortedTypes)
    {
        if (t in printed) continue;
        printed[t] = true;
        writefln("  %-14s x%d", t, typeCounts[t]);
    }

    // Section 4: consistency check.
    if (recipients.length != stanzaTypes.length)
    {
        writeln();
        writefln("WARNING: stanza count (%d) != declared recipient count (%d).",
            stanzaTypes.length, recipients.length);
        writeln("  This usually means `mcl-devops secret re-encrypt` wasn't run after editing");
        writeln("  the recipients list for service `", service, "`.");
        writeln("  Fix: mcl-devops secret re-encrypt --machine <machine> --service ", service);
    }

    return 0;
}

/// Parse the age header of a file and return the list of recipient stanza
/// types (the first token after `-> `). The header runs from the first line
/// (`age-encryption.org/v1`) until the first line beginning with `---`
/// (the HMAC marker). Each stanza begins with `-> <type> <args...>`.
private string[] parseAgeRecipientStanzas(string fileContents)
{
    string[] types;
    foreach (line; fileContents.split("\n"))
    {
        if (line.startsWith("---"))
            break;
        if (line.startsWith("-> "))
        {
            auto rest = line[3 .. $];
            auto fields = rest.split;
            if (fields.length > 0)
                types ~= fields[0];
        }
    }
    return types;
}

// =============================================================================
// Recipient Resolution
// =============================================================================

private string[] recipientArgs(string[] recipients)
{
    return recipients
        .map!(r => ["-r", r])
        .join
        .array;
}

private string[] resolveIdentity(string identityPath, ref TmpFS tmpfs)
{
    if (identityPath.length > 0)
    {
        if (!identityPath.exists)
            warningf("Specified identity file does not exist: %s", identityPath);
        return ["-i", identityPath];
    }

    string[] identityArgs;

    // Try age-plugin-yubikey: query for hardware-backed identities
    identityArgs = resolveYubikeyIdentities(tmpfs);
    if (identityArgs.length > 0)
        return identityArgs;

    // Fall back to well-known SSH key paths
    auto home = environment.get("HOME", "");
    if (home.length > 0)
    {
        auto ed25519 = home.buildPath(".ssh", "id_ed25519");
        auto rsa = home.buildPath(".ssh", "id_rsa");

        if (ed25519.exists)
        {
            infof("Using auto-discovered identity: %s", ed25519);
            identityArgs ~= ["-i", ed25519];
        }
        if (rsa.exists)
        {
            infof("Using auto-discovered identity: %s", rsa);
            identityArgs ~= ["-i", rsa];
        }
    }
    return identityArgs;
}

private enum yubikeyIdentityPattern = ctRegex!(`^AGE-PLUGIN-YUBIKEY-[0-9A-Z]+$`);

private string[] resolveYubikeyIdentities(ref TmpFS tmpfs)
{
    // Check if age-plugin-yubikey is available on PATH before executing
    if (!isInPath("age-plugin-yubikey"))
    {
        infof("age-plugin-yubikey not found in PATH, skipping YubiKey identity resolution");
        return [];
    }

    string[] identityArgs;

    try
    {
        auto output = execute(["age-plugin-yubikey", "-i"], printCommand: false);
        auto identities = output
            .split("\n")
            .map!strip
            .filter!(l => !l.matchFirst(yubikeyIdentityPattern).empty)
            .array;

        foreach (identity; identities)
        {
            auto tmpPath = tmpfs.writeFile(identity);
            infof("Using YubiKey identity: %s", identity);
            identityArgs ~= ["-i", tmpPath];
        }
    }
    catch (Exception e)
    {
        infof("age-plugin-yubikey execution failed: %s", e.msg);
    }

    return identityArgs;
}

// =============================================================================
// Helpers
// =============================================================================

private void requireMachine(SecretArgs common)
{
    if (common.machine.length == 0)
        errorAndExit("--machine is required for this subcommand.");
}

private void validateVmFlag(bool vm, ConfigurationType configurationType)
{
    if (vm && configurationType != ConfigurationType.nixosConfigurations)
        errorAndExit("Cannot use `vm` with `configuration-type` " ~ configurationType.to!string);
}

// JSON parsing structs for mcl.secrets
private struct SecretFileInfo
{
    string file;
    string group;
    string mode;
    string name;
    string owner;
    string path;
    bool symlink;
}

private struct MachineServiceConfig
{
    string encryptedSecretDir;
    string[] extraKeys;
    string[] recipients;
    SecretFileInfo[string] secrets;
}

private struct MachineSecretsConfig
{
    string[] extraKeys;
    MachineServiceConfig[string] services;
}

// Output structures for the all-machines list operation.
// One machine's listing: services (service name -> secret names) plus an
// optional evaluation error (set when the machine's config failed to evaluate).
private struct MachineSecretList
{
    string[][string] services;
    Nullable!string error;
}

private struct AllMachinesListInfo
{
    MachineSecretList[string] machines;
}

private struct ServiceInfo
{
    string configPath;
    string[] recipients;
}

/// Resolves configPath and recipients for a single service in one nix eval.
private ServiceInfo resolveServiceInfo(SecretArgs common, string confAttr, string service)
{
    auto configBase = common.vm
        ? rootDir ~ "#nixosConfigurations." ~ common.machine
            ~ "-vm.config.virtualisation.vmVariant"
        : rootDir ~ "#" ~ confAttr ~ "." ~ common.machine ~ ".config";

    return nix().eval!JSONValue(configBase, common.extraNixOptions ~ [
        "--apply", "c: { configPath = c.mcl.host-info.configPath; "
            ~ "recipients = c.mcl.secrets.services." ~ service ~ ".recipients; }"
    ]).fromJSON!ServiceInfo;
}

private struct AllServicesInfo
{
    string configPath;
    string[][string] serviceRecipients;
}

/// Resolves configPath and recipients for all services in one nix eval.
private AllServicesInfo resolveAllServicesInfo(SecretArgs common, string confAttr)
{
    auto configBase = common.vm
        ? rootDir ~ "#nixosConfigurations." ~ common.machine
            ~ "-vm.config.virtualisation.vmVariant"
        : rootDir ~ "#" ~ confAttr ~ "." ~ common.machine ~ ".config";

    return nix().eval!JSONValue(configBase, common.extraNixOptions ~ [
        "--apply", "c: { configPath = c.mcl.host-info.configPath; "
            ~ "serviceRecipients = builtins.mapAttrs (_: s: s.recipients) c.mcl.secrets.services; }"
    ]).fromJSON!AllServicesInfo;
}

/// Resolves the secret listing for a single machine from mcl.secrets.
/// A single-machine query has no partial-failure path (a broken config aborts
/// the eval), so `error` is always null — the field exists to keep the output
/// shape identical to the all-machines listing.
private MachineSecretList resolveListInfo(SecretArgs common, string confAttr)
{
    auto configBase = common.vm
        ? rootDir ~ "#nixosConfigurations." ~ common.machine
            ~ "-vm.config.virtualisation.vmVariant.mcl.secrets"
        : rootDir ~ "#" ~ confAttr ~ "." ~ common.machine ~ ".config.mcl.secrets";

    auto secretsConfig = nix()
        .eval!JSONValue(configBase, common.extraNixOptions)
        .fromJSON!MachineSecretsConfig;

    string[][string] services;
    foreach (name, svc; secretsConfig.services)
        services[name] = svc.secrets.keys.dup.sort.array;

    return MachineSecretList(services: services);
}

/// Resolves list info for all machines using a single --apply bulk eval.
/// Per-machine errors are caught inside the Nix expression via builtins.tryEval,
/// so broken machines produce an error marker instead of aborting the whole eval.
/// Filters out VMs (machines ending in "-vm") unless --include-vms is specified.
private AllMachinesListInfo resolveAllMachinesListInfo(
    SecretArgs common,
    SecretListArgs listArgs,
    string confAttr
)
{
    auto flakeAttr = rootDir ~ "#" ~ confAttr;

    // Each machine yields { services; error } — a shape that maps directly onto
    // MachineSecretList. builtins.tryEval catches a broken machine's config so
    // one failure can't abort the whole-fleet eval.
    auto json = nix().eval!JSONValue(flakeAttr, common.extraNixOptions ~ [
        "--apply",
        `cfgs: builtins.mapAttrs (_: m:`
            ~ ` let`
            ~ `   services = builtins.mapAttrs (_: s: builtins.attrNames s.secrets)`
            ~ `              m.config.mcl.secrets.services;`
            ~ `   eval = builtins.tryEval (builtins.deepSeq services services);`
            ~ ` in`
            ~ `   if eval.success`
            ~ `   then { services = eval.value; error = null; }`
            ~ `   else { services = {}; error = "evaluation failed"; }`
            ~ ` ) cfgs`
    ]);

    auto result = AllMachinesListInfo(json.fromJSON!(MachineSecretList[string]));

    // Drop VMs (unless requested) and surface per-machine eval errors on stderr.
    foreach (machine; result.machines.keys)
    {
        if (machine.endsWith("-vm") && !listArgs.includeVMs)
            result.machines.remove(machine);
        else if (!result.machines[machine].error.isNull)
            errorf("Failed to evaluate machine '%s': %s",
                machine, result.machines[machine].error.get);
    }

    return result;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

@("ConfigurationType.to!string maps nixosConfigurations")
unittest
{
    import std.conv : to;
    assert(ConfigurationType.nixosConfigurations.to!string == "nixosConfigurations");
}

@("ConfigurationType.to!string maps darwinConfigurations")
unittest
{
    import std.conv : to;
    assert(ConfigurationType.darwinConfigurations.to!string == "darwinConfigurations");
}

@("recipientArgs builds correct args")
unittest
{
    assert(recipientArgs(["key1", "key2"]) == ["-r", "key1", "-r", "key2"]);
}

@("recipientArgs handles single key")
unittest
{
    assert(recipientArgs(["key1"]) == ["-r", "key1"]);
}

@("parseAgeRecipientStanzas extracts stanza types from header")
unittest
{
    import std.conv : to;
    auto header =
        "age-encryption.org/v1\n" ~
        "-> ssh-rsa abcDEF\n" ~
        "AAAAAwerAB+payload+more\n" ~
        "-> ssh-ed25519 xyz123\n" ~
        "payload-line\n" ~
        "-> X25519 someBase64\n" ~
        "payload\n" ~
        "--- HMAC-base64-here\n" ~
        "-> not-a-recipient\n" ~  // after the marker, must be ignored
        "binary-ciphertext-bytes...";

    auto types = parseAgeRecipientStanzas(header);
    assert(types.length == 3, "expected 3 stanzas, got " ~ types.length.to!string);
    assert(types[0] == "ssh-rsa");
    assert(types[1] == "ssh-ed25519");
    assert(types[2] == "X25519");
}

@("parseAgeRecipientStanzas returns empty on empty file")
unittest
{
    assert(parseAgeRecipientStanzas("") == []);
}

@("parseAgeRecipientStanzas ignores lines after --- marker")
unittest
{
    auto header =
        "age-encryption.org/v1\n" ~
        "-> ssh-rsa key1\n" ~
        "--- hmac\n" ~
        "-> ssh-rsa key2\n";
    auto types = parseAgeRecipientStanzas(header);
    assert(types == ["ssh-rsa"]);
}
