module mcl.commands.ci_matrix;

import std.stdio : writeln, stderr, stdout;
import std.traits : EnumMembers;
import std.string : indexOf, splitLines, strip;
import std.algorithm : map, filter, reduce, chunkBy, find, any, sort, startsWith, endsWith, each, canFind, fold;
import std.file : write, readText, dirEntries, SpanMode, append, exists, mkdirRecurse;
import std.range : array, enumerate, empty, front, indexed, iota, join, chain, split;
import std.exception : ifThrown;
import std.conv : to, text;
import std.json : JSONValue, parseJSON, JSONOptions, JSONType;
import std.regex : matchFirst;
import core.cpuid : threadsPerCPU;
import std.path : buildPath, dirName;
import std.process : pipeProcess, wait, Redirect, kill;
import std.exception : enforce;
import std.format : fmt = format;
import std.logger : tracef, infof, errorf, warningf;

import argparse : Command, Description, NamedArgument, Placeholder, EnvFallback;

import mcl.utils.string : enumToString, enumFromString, StringRepresentation, MaxWidth, writeRecordAsTable;
import mcl.utils.json : toJSON, fromJSON;
import mcl.utils.path : rootDir, resultDir, gcRootsDir, createResultDirs;
import mcl.utils.process : execute;
import mcl.utils.nix : nix;

import mcl.commands.ci: CiArgs;
import mcl.commands.deploy_spec: DeploySpecArgs;

version (OSX)
{
    import core.sys.darwin.mach.kern_return : KERN_SUCCESS;
    import core.sys.darwin.mach.port : mach_port_t;

    private alias vm_size_t = ulong;
    private alias natural_t = uint;
    private alias integer_t = int;
    private alias mach_msg_type_number_t = natural_t;

    private struct vm_statistics64_data_t
    {
        natural_t free_count;
        natural_t active_count;
        natural_t inactive_count;
        natural_t wire_count;
        ulong zero_fill_count;
        ulong reactivations;
        ulong pageins;
        ulong pageouts;
        ulong faults;
        ulong cow_faults;
        ulong lookups;
        ulong hits;
        ulong purges;
        natural_t purgeable_count;
        natural_t speculative_count;
        ulong decompressions;
        ulong compressions;
        ulong swapins;
        ulong swapouts;
        natural_t compressor_page_count;
        natural_t throttled_count;
        natural_t external_page_count;
        natural_t internal_page_count;
        ulong total_uncompressed_pages_in_compressor;
    }

    private enum HOST_VM_INFO64 = 4;
    private enum HOST_VM_INFO64_COUNT = cast(mach_msg_type_number_t)(
        vm_statistics64_data_t.sizeof / integer_t.sizeof);

    private extern (C) mach_port_t mach_host_self() nothrow @nogc;
    private extern (C) int host_statistics64(mach_port_t host, int flavor,
        void* host_info, mach_msg_type_number_t* count) nothrow @nogc;
    private extern (C) int host_page_size(mach_port_t host, vm_size_t* page_size) nothrow @nogc;
}

alias GHRunner = string[];

struct NixSystemToGHRunner
{
    GHRunner[NixSystem] inner;

    this(string json)
    {
        this.inner = json.parseJSON.fromJSON!(typeof(this.inner));
    }

    GHRunner opIndex(NixSystem system) => this.inner[system];
}

enum NixSystem
{
    @StringRepresentation("x86_64-linux") x86_64_linux,

    @StringRepresentation("aarch64-linux") aarch64_linux,

    @StringRepresentation("x86_64-darwin") x86_64_darwin,

    @StringRepresentation("aarch64-darwin") aarch64_darwin,
}

version (linux)
{
    version (X86_64)
        enum currentSystem = NixSystem.x86_64_linux;
    else version (AArch64)
        enum currentSystem = NixSystem.aarch64_linux;
    else
        static assert (0, "Unsupported architecture");
}
else version (OSX)
{
    version (X86_64)
        enum currentSystem = NixSystem.x86_64_darwin;
    else version (AArch64)
        enum currentSystem = NixSystem.aarch64_darwin;
    else
        static assert (0, "Unsupported architecture");
}
else
    static assert (0, "Unsupported OS");

struct Package
{
    string name;
    bool allowedToFail = false;
    string attrPath;
    string[] cachedAt = [];
    GHRunner ghRunner;
    NixSystem system;
    string derivation;
    string output;
    bool deploymentTarget = false;
    string deploymentKind = "";

    string getNarInfoUrl(string binaryCacheHttpEndpoint) const
    {
        import mcl.utils.string : appendUrlPath;

        const storePathDigest = this.output.matchFirst("^/nix/store/(?P<hash>[^-]+)-")["hash"];

        return binaryCacheHttpEndpoint.appendUrlPath(storePathDigest) ~ ".narinfo";
    }
}

version (unittest)
{
    static immutable Package[] testPackageArray = [
        Package("testPackage", false, "testPackagePath", ["https://testPackage.com"], ["ubuntu-latest"], NixSystem.x86_64_linux, "testPackageOutput"),
        Package("testPackage2", true, "testPackagePath2", [], ["macos"], NixSystem.aarch64_darwin, "testPackageOutput2")
    ];
}

struct Matrix
{
    Package[] include;
}

version (unittest)
{
    JSONValue githubOutputValue(string output, string key)
    {
        const prefix = key ~ "=";
        foreach (line; output.splitLines)
            if (line.startsWith(prefix))
                return line[prefix.length .. $].parseJSON;

        assert(0, "Missing GitHub output key: " ~ key);
    }

    string[] matrixPackageNames(JSONValue matrix)
    {
        return matrix["include"].array.map!(pkg => pkg["name"].str).array;
    }
}

bool shouldIncludeInBuildMatrix(in Package pkg)
{
    return pkg.cachedAt.empty || pkg.deploymentTarget;
}

bool isCachedPackageJson(JSONValue pkg)
{
    if (pkg.type != JSONType.object)
        return false;

    if (auto cachedAt = "cachedAt" in pkg)
        return cachedAt.type == JSONType.array && cachedAt.array.length > 0;

    return false;
}

bool isDeploymentTargetPackageJson(JSONValue pkg)
{
    if (pkg.type != JSONType.object)
        return false;

    if (auto deploymentTarget = "deploymentTarget" in pkg)
        return deploymentTarget.type == JSONType.true_;

    return false;
}

bool shouldIncludeInBuildMatrix(JSONValue pkg)
{
    return !isCachedPackageJson(pkg) || isDeploymentTargetPackageJson(pkg);
}

@("build matrix includes cached deployment targets")
unittest
{
    auto cachedPackage = Package(
        name: "cached-package",
        cachedAt: ["https://cache.example/cached-package.narinfo"],
    );
    auto cachedDeploymentTarget = Package(
        name: "cached-deployment-target",
        cachedAt: ["https://cache.example/cached-deployment-target.narinfo"],
        deploymentTarget: true,
    );
    auto uncachedPackage = Package(
        name: "uncached-package",
    );

    assert(!cachedPackage.shouldIncludeInBuildMatrix);
    assert(cachedDeploymentTarget.shouldIncludeInBuildMatrix);
    assert(uncachedPackage.shouldIncludeInBuildMatrix);
}

@("ci matrix GitHub build output includes cached deployment targets")
unittest
{
    import std.file : deleteme, exists, readText, remove;

    auto outputPath = deleteme ~ ".ci-matrix-output.env";
    scope(exit)
        if (outputPath.exists)
            outputPath.remove;

    auto packages = [
        Package(
            name: "cached-package",
            cachedAt: ["https://cache.example/cached-package.narinfo"],
        ),
        Package(
            name: "cached-deployment-target",
            cachedAt: ["https://cache.example/cached-deployment-target.narinfo"],
            deploymentTarget: true,
        ),
        Package(
            name: "uncached-package",
        ),
    ];
    auto args = CiMatrixArgs(
        githubOutput: outputPath,
        precalcMatrix: `{"include":[]}`,
    );

    appendGHCIBuildOutput(packages, args.githubOutput);

    const output = outputPath.readText;
    assert(output.githubOutputValue("build_matrix").matrixPackageNames == [
        "cached-deployment-target",
        "uncached-package",
    ]);
    assert(output.githubOutputValue("full_matrix").matrixPackageNames == [
        "cached-package",
        "cached-deployment-target",
        "uncached-package",
    ]);
}

@("ci matrix GitHub output creates missing parent directory")
unittest
{
    import std.file : deleteme, exists, readText, rmdirRecurse;

    auto outputDir = deleteme ~ ".ci-matrix-output";
    auto outputPath = outputDir.buildPath("missing", "output.env");
    scope(exit)
        if (outputDir.exists)
            outputDir.rmdirRecurse;

    auto packages = [
        Package(name: "testPackage"),
        Package(name: "testPackage2"),
    ];

    appendGHCIBuildOutput(packages, outputPath);

    const output = outputPath.readText;
    assert(output.githubOutputValue("build_matrix").matrixPackageNames == [
        "testPackage",
        "testPackage2",
    ]);
    assert(output.githubOutputValue("full_matrix").matrixPackageNames == [
        "testPackage",
        "testPackage2",
    ]);
}

@("merged build matrix includes cached deployment target JSON")
unittest
{
    auto cachedPackage = JSONValue([
        "cachedAt": JSONValue([JSONValue("https://cache.example/cached-package.narinfo")]),
        "deploymentTarget": JSONValue(false),
    ]);
    auto cachedDeploymentTarget = JSONValue([
        "cachedAt": JSONValue([JSONValue("https://cache.example/cached-deployment-target.narinfo")]),
        "deploymentTarget": JSONValue(true),
    ]);
    auto uncachedPackage = JSONValue([
        "cachedAt": JSONValue(cast(JSONValue[]) []),
        "deploymentTarget": JSONValue(false),
    ]);

    assert(!cachedPackage.shouldIncludeInBuildMatrix);
    assert(cachedDeploymentTarget.shouldIncludeInBuildMatrix);
    assert(uncachedPackage.shouldIncludeInBuildMatrix);
}

@("merge ci matrices GitHub build output includes cached deployment targets")
unittest
{
    import std.file : deleteme, exists, mkdirRecurse, readText, rmdirRecurse, write;

    auto testDir = deleteme ~ ".merge-ci-matrices";
    if (testDir.exists)
        testDir.rmdirRecurse;
    scope(exit)
        if (testDir.exists)
            testDir.rmdirRecurse;

    testDir.buildPath("shard-a").mkdirRecurse;
    testDir.buildPath("shard-b").mkdirRecurse;

    testDir.buildPath("shard-a", "matrix-pre.json").write(JSONValue([
        "include": JSONValue([
            JSONValue([
                "name": JSONValue("cached-package"),
                "cachedAt": JSONValue([JSONValue("https://cache.example/cached-package.narinfo")]),
                "deploymentTarget": JSONValue(false),
            ]),
            JSONValue([
                "name": JSONValue("cached-deployment-target"),
                "cachedAt": JSONValue([JSONValue("https://cache.example/cached-deployment-target.narinfo")]),
                "deploymentTarget": JSONValue(true),
            ]),
        ]),
    ]).toString(JSONOptions.doNotEscapeSlashes));
    testDir.buildPath("shard-b", "matrix-pre.json").write(JSONValue([
        "include": JSONValue([
            JSONValue([
                "name": JSONValue("uncached-package"),
                "cachedAt": JSONValue(cast(JSONValue[]) []),
                "deploymentTarget": JSONValue(false),
            ]),
        ]),
    ]).toString(JSONOptions.doNotEscapeSlashes));

    auto outputPath = testDir.buildPath("gh-output.env");
    assert(mergeCiMatrices(MergeMatricesArgs(githubOutput: outputPath), testDir) == 0);

    const output = outputPath.readText;
    assert(output.githubOutputValue("build_matrix").matrixPackageNames == [
        "cached-deployment-target",
        "uncached-package",
    ]);
    assert(output.githubOutputValue("full_matrix").matrixPackageNames == [
        "cached-package",
        "cached-deployment-target",
        "uncached-package",
    ]);
}

struct SummaryTableEntry_x86_64
{
    string linux;
    string darwin;
}

struct SummaryTableEntry_aarch64
{
    string darwin;
}

struct SummaryTableEntry
{
    string name;
    SummaryTableEntry_x86_64 x86_64;
    SummaryTableEntry_aarch64 aarch64;
}

version (unittest)
{
    static immutable SummaryTableEntry[] testSummaryTableEntryArray = [
        SummaryTableEntry("testPackage", SummaryTableEntry_x86_64("✅ cached", "✅ cached"), SummaryTableEntry_aarch64("🚫 not supported")),
        SummaryTableEntry("testPackage2", SummaryTableEntry_x86_64("⏳ building...", "❌ build failed"), SummaryTableEntry_aarch64(
                "⏳ building..."))
    ];
}

mixin template CiMatrixBaseArgs()
{
    import std.conv : to;
    import std.json : parseJSON;
    import std.stdio : writeln, stderr, stdout;

    import argparse : Command, Description, NamedArgument, Placeholder, EnvFallback;

    import mcl.utils.json : fromJSON;
    import mcl.utils.cachix : cachixNixStoreUrl;
    import mcl.commands.ci_matrix : NixSystemToGHRunner;

    @(NamedArgument(["flake-attribute-path"])
        .Placeholder("flake.attr.path")
        .EnvFallback("FLAKE_ATTR_PATH")
    )
    string flakeAttrPath = "checks";

    @(NamedArgument(["max-workers"])
        .Placeholder("count")
    )
    int maxWorkers;

    @(NamedArgument(["max-memory"])
        .Placeholder("mb")
    )
    int maxMemory;

    @(NamedArgument(["is-initial"])
        .Description("Is this the initial run of the CI?")
        .EnvFallback("IS_INITIAL")
    )
    bool isInitial = true;

    @(NamedArgument(["cachix-cache"])
        .Placeholder("cache-name")
        .EnvFallback("CACHIX_CACHE")
    )
    string cachixCache;

    @(NamedArgument(["extra-cachix-caches"])
        .Placeholder("cache-name")
        .EnvFallback("EXTRA_CACHIX_CACHES")
    )
    string[] extraCachixCaches;

    @(NamedArgument(["extra-caches-urls"])
        .Placeholder("cache-url")
        .EnvFallback("EXTRA_CACHE_URLS")
    )
    string[] extraCacheUrls = ["https://cache.nixos.org"];

    string[] binaryCacheUrls() const
    {
        import std.algorithm.iteration : filter, joiner, map;
        import std.range : array, chain;
        import std.string : split;

        const string[] cachixCaches = (
            this.cachixCache.length
                ? [this.cachixCache]
                : []
        )
            .chain(this.extraCachixCaches)
            .filter!(cache => cache.length)
            .array;

        return cachixCaches
            .map!cachixNixStoreUrl
            .chain(this.extraCacheUrls.map!(urls => urls.split).joiner)
            .filter!(url => url.length)
            .array
            .to!(string[]);
    }

    @(NamedArgument(["attic-substituter"])
        .Placeholder("url")
        .EnvFallback("ATTIC_SUBSTITUTER")
    )
    string atticSubstituter;

    @(NamedArgument(["attic-auth-token"])
        .Placeholder("token")
        .EnvFallback("ATTIC_TOKEN")
    )
    string atticAuthToken;

    // Authorization header for the cache-status (narinfo) probe of one cache
    // URL. Each bearer token is scoped to its own host, so a token is never
    // transmitted to an unrelated substituter (e.g. cache.nixos.org):
    //   * the Attic ATTIC_TOKEN is sent only to the configured Attic host
    //     (derived from ATTIC_SUBSTITUTER). Required because the Attic
    //     deployment cache is private — an unauthenticated narinfo GET 401s.
    //   * the legacy Cachix token is sent only to *.cachix.org hosts.
    string[string] cacheStatusAuthHeadersForUrl(string url) const
    {
        import mcl.commands.ci_matrix : cacheUrlHost;
        import std.algorithm.searching : endsWith;

        const host = cacheUrlHost(url);
        if (this.atticAuthToken.length && this.atticSubstituter.length
            && host == cacheUrlHost(this.atticSubstituter))
            return ["Authorization": "Bearer " ~ this.atticAuthToken];
        if (this.cachixAuthToken.length && host.endsWith(".cachix.org"))
            return ["Authorization": "Bearer " ~ this.cachixAuthToken];
        return null;
    }

    @(NamedArgument(["cachix-auth-token"])
        .Placeholder("token")
        .EnvFallback("CACHIX_AUTH_TOKEN")
    )
    string cachixAuthToken;

    @(NamedArgument(["precalc-matrix"])
        .Placeholder("matrix")
        .EnvFallback("PRECALC_MATRIX")
    )
    string precalcMatrix = "";

    @(NamedArgument(["system-to-github-runner-labels"])
        .Placeholder("json")
        .Description("Mapping of Nix Systems to GitHub Runner Labels")
        .EnvFallback("SYSTEM_TO_GITHUB_RUNNER_LABELS")
    )
    string nixSystemToGHRunner;

    @(NamedArgument(["github-output"])
        .Placeholder("output")
        .Description("Output to GitHub Actions")
        .EnvFallback("GITHUB_OUTPUT")
    )
    string githubOutput;
}

@(Command("ci-matrix", "ci_matrix")
    .Description("Print a table of the cache status of each package"))
struct CiMatrixArgs
{
    mixin CiMatrixBaseArgs!();
}

@("ci matrix cache URLs do not require Cachix")
unittest
{
    auto args = CiMatrixArgs(
        cachixCache: "",
        extraCachixCaches: ["", "team-cache"],
        extraCacheUrls: ["https://attic.example/cache https://mirror.example/cache", ""],
        cachixAuthToken: "",
    );

    assert(args.binaryCacheUrls == [
        "https://team-cache.cachix.org",
        "https://attic.example/cache",
        "https://mirror.example/cache",
    ]);
    // No tokens configured -> no auth header for any URL.
    assert(args.cacheStatusAuthHeadersForUrl("https://team-cache.cachix.org") is null);
    assert(args.cacheStatusAuthHeadersForUrl("https://attic.example/cache") is null);
}

@("ci matrix cache status authorization is optional and host-scoped")
unittest
{
    auto args = CiMatrixArgs(
        cachixCache: "primary-cache",
        extraCachixCaches: [],
        extraCacheUrls: ["https://cache.nixos.org"],
        cachixAuthToken: "secret",
    );

    assert(args.binaryCacheUrls == [
        "https://primary-cache.cachix.org",
        "https://cache.nixos.org",
    ]);
    // Legacy Cachix token is sent only to *.cachix.org hosts.
    assert(args.cacheStatusAuthHeadersForUrl("https://primary-cache.cachix.org")["Authorization"] == "Bearer secret");
    assert(args.cacheStatusAuthHeadersForUrl("https://cache.nixos.org") is null);
}

@("ci matrix cache status sends ATTIC_TOKEN only to the Attic host")
unittest
{
    auto args = CiMatrixArgs(
        cachixCache: "",
        extraCachixCaches: [],
        extraCacheUrls: [
            "https://cache.nixos.org https://cache.metacraft-labs.com/metacraft-private-infrastructure"
        ],
        cachixAuthToken: "",
        atticSubstituter: "https://cache.metacraft-labs.com/metacraft-private-infrastructure",
        atticAuthToken: "attic-secret",
    );

    // The private Attic cache gets the bearer token (otherwise its narinfo
    // GET 401s); cache.nixos.org must NOT receive the Attic token.
    assert(args.cacheStatusAuthHeadersForUrl(
        "https://cache.metacraft-labs.com/metacraft-private-infrastructure"
    )["Authorization"] == "Bearer attic-secret");
    assert(args.cacheStatusAuthHeadersForUrl("https://cache.nixos.org") is null);
}

@(Command("print-table", "print_table")
    .Description("Print a table of the cache status of each package"))
struct PrintTableArgs
{
    mixin CiMatrixBaseArgs!();
}

export int ci_matrix(CiMatrixArgs args)
{
    auto packages = args.flakeAttrPath.startsWith("mcl.shard-matrix.result.shards")
        ? nixEvalJobs(args.flakeAttrPath, args)
        : nixEvalForAllSystems(args);

    printTableForCacheStatus(packages, args);

    return 0;
}

export int print_table(PrintTableArgs args)
{
    getPrecalcMatrix(args)
        .checkCacheStatus(args)
        .printTableForCacheStatus(args);

    return 0;
}

string flakeAttr(string prefix, NixSystem system, string[] attrs...)
{
    return [prefix, system.enumToString].chain(attrs).join(".");
}

Package[] checkCacheStatus(T)(Package[] packages, auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    import std.array : appender;
    import std.parallelism : parallel;
    import mcl.utils.tui : supportsOscLinks;

    string formatCachedAtLink(size_t index, string url, bool useOscLinks)
    {
        return useOscLinks
            ? i"\033]8;;$(url)\033\\<$(index)>\033]8;;\033\\".text
            : url;
    }

    struct Output {
        string ok;
        string runner;
        @MaxWidth(3) string at;
        @MaxWidth(50) string attr;
        @MaxWidth(80) string output;
    }

    const useOscLinks = supportsOscLinks();
    foreach (ref pkg; packages.parallel) {
        // Skip cache check if already has cached URLs
        if (pkg.cachedAt.empty)
        {
            pkg.cachedAt ~= args.binaryCacheUrls
                .filter!(url => pkg.isCached(url, args.cacheStatusAuthHeadersForUrl(url)))
                .map!(url => pkg.getNarInfoUrl(url))
                .array;
        }

        Output(
            ok: !pkg.cachedAt.empty ? "✅" : "❌",
            runner: pkg.ghRunner.join(", "),
            at: pkg.cachedAt
                .enumerate
                .map!(t => formatCachedAtLink(t.index, t.value, useOscLinks))
                .join(", "),
            attr: pkg.attrPath,
            output: pkg.output,
        ).writeRecordAsTable(stderr.lockingTextWriter);
    }

    return packages;
}

static immutable string[] uselessWarnings =
    ["allowed-users", "trusted-users", "bash-prompt-prefix"].map!(
        setting => "warning: unknown setting '" ~ setting ~ "'").array ~
    [
        "warning: ignoring untrusted flake configuration setting 'extra-substituters'.",
        "warning: ignoring untrusted flake configuration setting 'extra-trusted-public-keys'.",
        "Pass '--accept-flake-config' to trust it",
        "SQLite database",
        "trace: warning: The legacy table is outdated and should not be used. We recommend using the gpt type instead.",
        "Please note that certain features, such as the test framework, may not function properly with the legacy table type.",
        "If you encounter errors similar to:",
        "error: The option `disko.devices.disk.disk1.content.partitions",
        "this is likely due to the use of the legacy table type.",
        "warning: system.stateVersion is not set, defaulting to",
        "warning: Runner registration tokens have been deprecated and disabled by default in GitLab >= 17.0.",
        "Consider migrating to runner authentication tokens by setting `services.gitlab-runner.services.codetracer.authenticationTokenConfigFile`.",
        "https://docs.gitlab.com/17.0/ee/ci/runners/new_creation_workflow.html",
        "for a migration you can follow the guide at https://github.com/nix-community/disko/blob/master/docs/table-to-gpt.md"
    ];

Package packageFromNixEvalJobsJson(
    JSONValue json,
    string flakeAttrPath,
    NixSystemToGHRunner nixSystemToRunnerLabels,
    const(string)[] deploymentTargetNames = [],
)
{
    auto sys = json["system"].fromJSON!NixSystem;
    const attr = json["attr"].str;

    // WARN: The `isCached` property coming from `nix-eval-jobs` is
    //       insufficient as it just says if the package is cached
    //       "somewhere" (including in the local store)
    return Package(
        name: attr,
        allowedToFail: false,
        attrPath: flakeAttrPath ~ "." ~ attr,
        cachedAt: [],
        system: sys,
        ghRunner: nixSystemToRunnerLabels[sys],
        derivation: json["drvPath"].str,
        output: json["outputs"]["out"].str,
        deploymentTarget: isDeployableServerMachineAttr(flakeAttrPath, attr, deploymentTargetNames),
        deploymentKind: deploymentKindFor(flakeAttrPath, attr, deploymentTargetNames),
    );
}

enum deployableServerMachinesAttrPath = "legacyPackages.x86_64-linux.serverMachines";

bool isShardMatrixAttrPath(string flakeAttrPath)
{
    return flakeAttrPath.startsWith("mcl.shard-matrix.result.shards");
}

string shardMatrixMachineName(string attr)
{
    import std.string : split;

    auto parts = attr.split("/");
    return parts.length >= 3 && parts[0] == "machine"
        ? parts[1]
        : "";
}

bool isDeployableServerMachineAttr(
    string flakeAttrPath,
    string attr,
    const(string)[] deploymentTargetNames = [],
)
{
    if (flakeAttrPath == deployableServerMachinesAttrPath
        || flakeAttrPath.startsWith(deployableServerMachinesAttrPath ~ "."))
        return true;

    if (!flakeAttrPath.isShardMatrixAttrPath)
        return false;

    if (attr == "serverMachines" || attr.startsWith("serverMachines/"))
        return true;

    return attr.shardMatrixMachineName != ""
        && deploymentTargetNames.canFind(attr.shardMatrixMachineName);
}

string deploymentKindFor(string flakeAttrPath, string attr, const(string)[] deploymentTargetNames = [])
{
    return isDeployableServerMachineAttr(flakeAttrPath, attr, deploymentTargetNames) ? "server" : "";
}

@("packageFromNixEvalJobsJson")
unittest
{
    {
        auto testJSON = `{
            "attr": "home/bean-desktop",
            "attrPath": [ "home/bean-desktop" ],
            "cacheStatus": "notBuilt",
            "drvPath": "/nix/store/jp7qgm9mgikksypzljrbhmxa31xmmq1x-home-manager-generation.drv",
            "inputDrvs": {
                "/nix/store/0hkqmn0z40yx89kd5wgfjxzqckvjkiw3-home-manager-files.drv": [ "out" ],
                "/nix/store/0khqc4m8jrv5gkg2jwf5xz46bkmz2qxl-dconf-keys.json.drv": [ "out" ],
                "/nix/store/5rydfkrpd5vdpz4qxsypivxwy9y6z8gl-bash-5.2p26.drv": [ "out" ],
                "/nix/store/7vgw0fqilqwa9l26arqpym1l4iisgff1-stdenv-linux.drv": [ "out" ],
                "/nix/store/96ji6f4cijfc23jz98x45xm1dvzz5hq8-activation-script.drv": [ "out" ],
                "/nix/store/m60vlf9j0g8y82avg5x90nbg554wshva-home-manager-path.drv": [ "out" ]
            },
            "isCached": false,
            "name": "home-manager-generation",
            "outputs": {
                "out": "/nix/store/30qrziyj0vbg6n43bbh08ql0xbnsy76d-home-manager-generation"
            },
            "system": "x86_64-linux"
        }`.parseJSON;

        auto testPackage = testJSON.packageFromNixEvalJobsJson(
            "legacyPackages.x86_64-linux.mcl.matrix.shards.0",
            // TODO: uncomment when `NixSystemToGHRunner` stops being a `string`
            // [NixSystem.x86_64_linux: ["self-hosted"]],
            NixSystemToGHRunner("{ \"x86_64-linux\": [\"self-hosted\"] }"),
        );
        assert(testPackage == Package(
            name: "home/bean-desktop",
            allowedToFail: false,
            attrPath: "legacyPackages.x86_64-linux.mcl.matrix.shards.0.home/bean-desktop",
            system: NixSystem.x86_64_linux,
            ghRunner: ["self-hosted"],
            derivation: "/nix/store/jp7qgm9mgikksypzljrbhmxa31xmmq1x-home-manager-generation.drv",
            output: "/nix/store/30qrziyj0vbg6n43bbh08ql0xbnsy76d-home-manager-generation",
        ));

        assert(
            testPackage.getNarInfoUrl("https://binary-cache.internal") ==
            "https://binary-cache.internal/30qrziyj0vbg6n43bbh08ql0xbnsy76d.narinfo"
        );
    }
}

@("deployment target metadata is limited to serverMachines")
unittest
{
    const deploymentTargetNames = [
        "bare-metal-001",
        "gpu-node-001",
        "gpu-node-002",
        "gpu-node-003",
        "app-node-002",
        "app-node-003",
        "example-site-server",
    ];

    assert(isDeployableServerMachineAttr(
        "legacyPackages.x86_64-linux.serverMachines",
        "app-server-01"
    ));
    assert(isDeployableServerMachineAttr(
        "mcl.shard-matrix.result.shards.shard-42",
        "serverMachines/app-server-01/x86_64-linux",
        deploymentTargetNames,
    ));
    assert(isDeployableServerMachineAttr(
        "mcl.shard-matrix.result.shards.shard-42",
        "machine/gpu-node-001/x86_64-linux",
        deploymentTargetNames,
    ));
    assert(isDeployableServerMachineAttr(
        "mcl.shard-matrix.result.shards.shard-42",
        "machine/example-site-server/x86_64-linux",
        deploymentTargetNames,
    ));
    assert(isDeployableServerMachineAttr(
        "mcl.shard-matrix.result.shards.shard-42",
        "machine/app-node-002/x86_64-linux",
        deploymentTargetNames,
    ));
    assert(isDeployableServerMachineAttr(
        "mcl.shard-matrix.result.shards.shard-42",
        "machine/bare-metal-001/x86_64-linux",
        deploymentTargetNames,
    ));
    assert(!isDeployableServerMachineAttr(
        "mcl.shard-matrix.result.shards.shard-42",
        "machine/elitsa-dimitrova-001/x86_64-linux",
        deploymentTargetNames,
    ));
    assert(!isDeployableServerMachineAttr(
        "mcl.shard-matrix.result.shards.shard-42",
        "machine/usb-drive/x86_64-linux",
        deploymentTargetNames,
    ));
    assert(!isDeployableServerMachineAttr(
        "legacyPackages.x86_64-linux.checks",
        "machine/gpu-node-001/x86_64-linux",
        deploymentTargetNames,
    ));

    auto server = `{
        "attr": "machine/gpu-node-001/x86_64-linux",
        "drvPath": "/nix/store/server.drv",
        "outputs": { "out": "/nix/store/11111111111111111111111111111111-server" },
        "system": "x86_64-linux"
    }`.parseJSON.packageFromNixEvalJobsJson(
        "mcl.shard-matrix.result.shards.shard-42",
        NixSystemToGHRunner(`{ "x86_64-linux": ["self-hosted"] }`),
        deploymentTargetNames,
    );
    assert(server.deploymentTarget);
    assert(server.deploymentKind == "server");

    auto workstation = `{
        "attr": "machine/elitsa-dimitrova-001/x86_64-linux",
        "drvPath": "/nix/store/workstation.drv",
        "outputs": { "out": "/nix/store/22222222222222222222222222222222-workstation" },
        "system": "x86_64-linux"
    }`.parseJSON.packageFromNixEvalJobsJson(
        "mcl.shard-matrix.result.shards.shard-42",
        NixSystemToGHRunner(`{ "x86_64-linux": ["self-hosted"] }`),
        deploymentTargetNames,
    );
    assert(!workstation.deploymentTarget);
    assert(workstation.deploymentKind == "");

    auto installMedia = `{
        "attr": "machine/usb-drive/x86_64-linux",
        "drvPath": "/nix/store/install-media.drv",
        "outputs": { "out": "/nix/store/33333333333333333333333333333333-install-media" },
        "system": "x86_64-linux"
    }`.parseJSON.packageFromNixEvalJobsJson(
        "mcl.shard-matrix.result.shards.shard-42",
        NixSystemToGHRunner(`{ "x86_64-linux": ["self-hosted"] }`),
        deploymentTargetNames,
    );
    assert(!installMedia.deploymentTarget);
    assert(installMedia.deploymentKind == "");

    Package[] matrixPackages = [server, workstation, installMedia];
    auto matrix = JSONValue([
        "include": JSONValue(matrixPackages.map!toJSON.array),
    ]);
    assert(matrix["include"][0]["deploymentTarget"].boolean);
    assert(matrix["include"][0]["deploymentKind"].str == "server");
    assert(!matrix["include"][1]["deploymentTarget"].boolean);
    assert(matrix["include"][1]["deploymentKind"].str == "");
    assert(!matrix["include"][2]["deploymentTarget"].boolean);
    assert(matrix["include"][2]["deploymentKind"].str == "");
}

Package[] nixEvalJobs(T)(string flakeAttrPath, auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    Package[] result = [];

    bool hasError = false;

    int maxMemoryMB = getAvailableMemoryMB(args);
    int maxWorkers = getNixEvalWorkerCount(args);

    const nixArgs = [
        "nix-eval-jobs", "--quiet", "--option", "warn-dirty", "false",
        "--check-cache-status", "--gc-roots-dir", gcRootsDir, "--workers",
        maxWorkers.to!string, "--max-memory-size", maxMemoryMB.to!string,
        "--flake", rootDir ~ "#" ~ flakeAttrPath
    ];
    const deploymentTargetNames = flakeAttrPath.isShardMatrixAttrPath
        ? getDeployableServerMachineNames()
        : [];

    const commandString = nixArgs.join(" ");

    tracef("%-(%s %)", nixArgs);

    auto pipes = pipeProcess(nixArgs, Redirect.stdout | Redirect.stderr);

    void logWarning(const char[] msg)
    {
        warningf("Command `%s` stderr:\n---\n%s\n---", commandString, msg);
    }

    void logError(const char[] msg)
    {
        errorf("Command `%s` failed with error:\n---\n%s\n---", commandString, msg);
    }

    const errorsReported = pipes.stdout.byLine.fold!((errorsReported, line) {
        auto json = parseJSON(line);

        if (auto err = "error" in json)
        {
            logError((*err).str);
            return true;
        }

        Package pkg = json.packageFromNixEvalJobsJson(
            flakeAttrPath,
            NixSystemToGHRunner(args.nixSystemToGHRunner),
            deploymentTargetNames,
        );

        pkg = checkCacheStatus([pkg], args)[0];

        result ~= pkg;

        return errorsReported;
    })(false);

    const stderrLogs = pipes.stderr.byLine
        .filter!(line => !uselessWarnings.any!(w => line.canFind(w)))
        .join("\n");

    if (stderrLogs.strip != "")
        logWarning(stderrLogs);

    int status = wait(pipes.pid);

    enforce(status == 0 && !errorsReported, "Command `%s` failed with status %s".fmt(commandString, status));

    return result;
}

string[] getDeployableServerMachineNames(string flakeRef = rootDir)
{
    return nix.eval!JSONValue(flakeRef ~ "#" ~ deployableServerMachinesAttrPath, [
            "--apply",
            "builtins.attrNames",
        ])
        .ifThrown(parseJSON("[]"))
        .fromJSON!(string[]);
}

NixSystem[] getSupportedSystems(string flakeRef = ".")
{
    import std.path : isValidPath, absolutePath, buildNormalizedPath;

    if (flakeRef.isValidPath) {
        flakeRef = flakeRef.absolutePath.buildNormalizedPath;
    }

    // The leading `.` makes the attribute path absolute. Without it `nix eval`
    // first tries `packages.<system>.mcl...`, and in a flake whose
    // `packages.<system>.mcl` throws (this repo's rename tombstone) that throw
    // is fatal instead of falling through to the top-level `mcl.shard-matrix`
    // output. The eval then "fails", we fall back to every system, and the
    // runner lookup for a system the caller never mapped dies with a
    // RangeError.
    return nix.eval!JSONValue(flakeRef ~ `#.mcl.shard-matrix.systemsToBuild`)
        .ifThrown(nix.eval!JSONValue(flakeRef ~ `#legacyPackages`, [
            "--apply",
            `builtins.attrNames`
        ]))
        .ifThrown(JSONValue([ currentSystem.enumToString ]))
        .fromJSON!(NixSystem[]);
}

Package[] nixEvalForAllSystems(T)(auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    const systems = getSupportedSystems();

    infof("Evaluating flake for: %s", systems);

    return systems.map!(system =>
            flakeAttr(args.flakeAttrPath, system)
                .nixEvalJobs(args)
        )
        .reduce!((a, b) => a ~ b)
        .array
        .sort!((a, b) => a.name < b.name)
        .array;
}

int getNixEvalWorkerCount(T)(auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    return args.maxWorkers == 0 ? (threadsPerCPU() < 8 ? threadsPerCPU() : 8) : args.maxWorkers;
}

@("getNixEvalWorkerCount")
unittest
{
    CiMatrixArgs args;
    args.maxWorkers = 0;
    assert(getNixEvalWorkerCount(args) == (threadsPerCPU() < 8 ? threadsPerCPU() : 8));

    args.maxWorkers = 4;
    assert(getNixEvalWorkerCount(args) == 4);
}

int getAvailableMemoryMB(T)(auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    if (args.maxMemory != 0)
        return args.maxMemory;

    version (linux)
    {
        int free = "/proc/meminfo".readText
            .splitLines
            .find!(a => a.indexOf("MemFree") != -1)
            .front
            .split[1].to!int;
        int cached = "/proc/meminfo".readText
            .splitLines
            .find!(a => a.indexOf("Cached") != -1 && a.indexOf("SwapCached") == -1)
            .front
            .split[1].to!int;
        int buffers = "/proc/meminfo".readText
            .splitLines
            .find!(a => a.indexOf("Buffers") != -1)
            .front
            .split[1].to!int;
        int shmem = "/proc/meminfo".readText
            .splitLines
            .find!(a => a.indexOf("Shmem:") != -1)
            .front
            .split[1].to!int;
        return (free + cached + buffers - shmem) / 1024;
    }
    else version (OSX)
    {
        vm_statistics64_data_t vmStats;
        mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
        vm_size_t pageSize;

        auto host = mach_host_self();

        if (host_page_size(host, &pageSize) != KERN_SUCCESS)
            throw new Exception("Failed to get page size");

        if (host_statistics64(host, HOST_VM_INFO64, &vmStats, &count) != KERN_SUCCESS)
            throw new Exception("Failed to get VM statistics");

        // Available memory: free + inactive + speculative (pages that can be reclaimed)
        ulong availablePages = vmStats.free_count + vmStats.inactive_count + vmStats.purgeable_count + vmStats.speculative_count;
        ulong availableBytes = availablePages * pageSize;
        return cast(int)(availableBytes / (1024 * 1024));
    }
    else
    {
        static assert(false, "getAvailableMemoryMB not implemented for this platform");
    }
}

@("getAvailableMemoryMB")
unittest
{
    CiMatrixArgs args;
    args.maxMemory = 0;
    assert(getAvailableMemoryMB(args) > 0);

    args.maxMemory = 1024;
    assert(getAvailableMemoryMB(args) == 1024);
}

void saveCachixDeploySpec(Package[] packages)
{
    // TODO: check if we really need to filter out the cached packages
    auto agents = packages
        .filter!(pkg => pkg.cachedAt.empty)
        .map!(pkg => JSONValue([
            "package": pkg.name,
            "out": pkg.output,
        ]))
        .array;
    auto resPath = resultDir.buildPath("cachix-deploy-spec.json");
    resPath.write(JSONValue(agents).toString(JSONOptions.doNotEscapeSlashes));
}

@("saveCachixDeploySpec")
unittest
{
    import std.file : rmdirRecurse;

    createResultDirs();
    saveCachixDeploySpec(cast(Package[]) testPackageArray);
    JSONValue deploySpec = parseJSON(resultDir.buildPath("cachix-deploy-spec.json").readText);
    assert(testPackageArray[1].name == deploySpec[0]["package"].str);
    assert(testPackageArray[1].output == deploySpec[0]["out"].str);
}

void saveGHCIMatrix(T)(Package[] packages, auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    auto matrix = JSONValue([
        "include": JSONValue(packages.map!toJSON.array)
    ]);
    string resPath = rootDir.buildPath(args.isInitial ? "matrix-pre.json" : "matrix-post.json");
    resPath.write(JSONValue(matrix).toString(JSONOptions.doNotEscapeSlashes));
}

@("saveGHCIMatrix")
unittest
{
    import std.file : rmdirRecurse;

    createResultDirs();
    CiMatrixArgs args;
    args.isInitial = false;
    saveGHCIMatrix(cast(Package[]) testPackageArray, args);
    JSONValue matrix = rootDir
        .buildPath(args.isInitial ? "matrix-pre.json" : "matrix-post.json")
        .readText
        .parseJSON;
    assert(testPackageArray[0].name == matrix["include"][0]["name"].str);
}

void saveGHCIComment(SummaryTableEntry[] tableSummaryJSON)
{
    import std.path : buildNormalizedPath, absolutePath;

    string comment = "Thanks for your Pull Request!";
    comment ~= "\n\nBelow you will find a summary of the cachix status of each package, for each supported platform.";
    comment ~= "\n\n| package | `x86_64-linux` | `x86_64-darwin` | `aarch64-darwin` |";
    comment ~= "\n| ------- | -------------- | --------------- | ---------------- |";
    comment ~= tableSummaryJSON.map!(
        pkg => "\n| " ~ pkg.name ~ " | " ~ pkg.x86_64.linux ~ " | " ~ pkg.x86_64.darwin ~ " | " ~ pkg.aarch64.darwin ~ " |")
        .join("");

    auto outputPath = rootDir.buildNormalizedPath("comment.md");
    write(outputPath, comment);
    infof("Wrote GitHub comment file to '%s'", outputPath);
}

@("saveGHCIComment")
unittest
{
    import std.file : rmdirRecurse;

    createResultDirs();
    saveGHCIComment(cast(SummaryTableEntry[]) testSummaryTableEntryArray);
    string comment = rootDir.buildPath("comment.md").readText;
    foreach (pkg; testSummaryTableEntryArray)
    {
        assert(comment.indexOf(pkg.name) != -1);
        assert(comment.indexOf(pkg.x86_64.linux) != -1);
        assert(comment.indexOf(pkg.x86_64.darwin) != -1);
        assert(comment.indexOf(pkg.aarch64.darwin) != -1);
    }
}

string getStatus(JSONValue pkg, string key, bool isInitial)
{
    auto pkgName = ("name" in pkg) ? pkg["name"].str : "unknown";

    if (key in pkg)
    {
        if (auto pkgOnSys = "cachedAt" in pkg[key])
        {
            if (auto cachedAt = (*pkgOnSys).array)
            {
                if (!cachedAt.empty)
                {
                    auto status = fmt!"✅ Cached at %-(%s%||%)"(
                        cachedAt
                            .enumerate()
                            .map!(t => "[<%s>](%s)".fmt(t.index, t.value.str))
                    );
                    return status;
                }
            }
        }

        if (isInitial)
            return "⏳ building...";

        return "❌ build failed";
    }
    else
    {
        return "🚫 not supported";
    }
}

SummaryTableEntry[] convertNixEvalToTableSummary(
    const Package[] packages,
    bool isInitial
)
{
    SummaryTableEntry[] tableSummary = packages
        .chunkBy!((a, b) => a.name == b.name)
        .map!((group) {
            JSONValue pkg;
            string name = group.array.front.name;
            pkg["name"] = JSONValue(name);
            foreach (item; group)
            {
                pkg[item.system.enumToString] = item.toJSON();
            }
            SummaryTableEntry entry = {
                name, {
                    getStatus(pkg, "x86_64-linux", isInitial),
                    getStatus(pkg, "x86_64-darwin", isInitial)
                }, {
                    getStatus(pkg, "aarch64-darwin", isInitial)
                }
            };
            return entry;
        })
        .array
        .sort!((a, b) => a.name < b.name)
        .release;
    return tableSummary;
}

@("convertNixEvalToTableSummary/getStatus")
unittest
{
    auto tableSummary = convertNixEvalToTableSummary(
        testPackageArray,
        isInitial: false
    );
    assert(tableSummary[0].name == testPackageArray[0].name);
    assert(tableSummary[0].x86_64.linux == "✅ Cached at [<0>](https://testPackage.com)");
    assert(tableSummary[0].x86_64.darwin == "🚫 not supported");
    assert(tableSummary[0].aarch64.darwin == "🚫 not supported");
    assert(tableSummary[1].name == testPackageArray[1].name);
    assert(tableSummary[1].x86_64.linux == "🚫 not supported");
    assert(tableSummary[1].x86_64.darwin == "🚫 not supported");
    assert(tableSummary[1].aarch64.darwin == "❌ build failed");

    tableSummary = convertNixEvalToTableSummary(
        testPackageArray,
        isInitial: true
    );
    assert(tableSummary[0].name == testPackageArray[0].name);
    assert(tableSummary[0].x86_64.linux == "✅ Cached at [<0>](https://testPackage.com)");
    assert(tableSummary[0].x86_64.darwin == "🚫 not supported");
    assert(tableSummary[0].aarch64.darwin == "🚫 not supported");
    assert(tableSummary[1].name == testPackageArray[1].name);
    assert(tableSummary[1].x86_64.linux == "🚫 not supported");
    assert(tableSummary[1].x86_64.darwin == "🚫 not supported");
    assert(tableSummary[1].aarch64.darwin == "⏳ building...");

}

void printTableForCacheStatus(T)(Package[] packages, auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    createResultDirs();

    if (args.precalcMatrix == "")
    {
        saveGHCIMatrix(packages, args);
    }
    saveCachixDeploySpec(packages);
    saveGHCIComment(convertNixEvalToTableSummary(packages, args.isInitial));

    const outputPath = args.githubOutput
        ? args.githubOutput
        : resultDir.buildPath("gh-output.env");

    appendGHCIBuildOutput(packages, outputPath);
}

void appendGHCIBuildOutput(Package[] packages, string outputPath)
{
    const buildMatrixLine = "build_matrix=" ~ JSONValue([
        "include": JSONValue(packages.filter!shouldIncludeInBuildMatrix.map!toJSON.array)
    ]).toString(JSONOptions.doNotEscapeSlashes) ~ "\n";

    const fullMatrixLine = "full_matrix=" ~ JSONValue([
        "include": JSONValue(packages.map!toJSON.array)
    ]).toString(JSONOptions.doNotEscapeSlashes) ~ "\n";

    appendGitHubOutput(outputPath, buildMatrixLine ~ fullMatrixLine);
}

void appendGitHubOutput(string outputPath, string content)
{
    const outputDir = outputPath.dirName;
    if (outputDir != "" && outputDir != "." && !outputDir.exists)
        outputDir.mkdirRecurse;
    if (!outputPath.exists)
        outputPath.write("");
    outputPath.append(content);
}

// Extract the host[:port] from a cache URL ("https://host/path" -> "host").
// Used to scope cache-status auth headers to the matching host only.
string cacheUrlHost(string url)
{
    string s = url;
    foreach (scheme; ["https://", "http://"])
    {
        if (s.startsWith(scheme))
        {
            s = s[scheme.length .. $];
            break;
        }
    }
    const slash = s.indexOf('/');
    return slash >= 0 ? s[0 .. slash] : s;
}

@("ci_matrix.cacheUrlHost")
unittest
{
    assert(cacheUrlHost("https://cache.metacraft-labs.com/metacraft-private-infrastructure") == "cache.metacraft-labs.com");
    assert(cacheUrlHost("https://cache.nixos.org") == "cache.nixos.org");
    assert(cacheUrlHost("http://127.0.0.1:8080/x") == "127.0.0.1:8080");
}

bool isCached(in Package pkg, string binaryCacheHttpEndpoint, in string[string] httpHeaders = null)
{
    import std.algorithm : canFind;
    import std.string : lineSplitter;
    import std.net.curl : CurlException, HTTP, httpGet = get, HTTPStatusException;
    import core.time : dur;

    auto http = HTTP();
    // Without these timeouts a single slow / unresponsive cache server
    // blocks the entire `ci-matrix` cache-status sweep indefinitely.
    // ``checkCacheStatus`` iterates packages in parallel and calls
    // ``isCached`` per (package, cache URL), so one stuck narinfo GET
    // can hang the whole shard-matrix step until GitHub Actions kills
    // the job at its 6 h hard ceiling (observed on PRs against
    // ``nix-blockchain-development`` and on the same repo's main
    // branch CI -- ``Generate Shard Matrix`` consistently times out
    // at 6 h with orphan ``nix-eval-jobs`` and ``.mcl-devops-wrapped``
    // processes still running).  Cap each request at 10 s to connect
    // and 30 s of total transfer time so a single misbehaving
    // narinfo lookup degrades gracefully instead of taking down the
    // whole pipeline.
    http.connectTimeout = dur!"seconds"(10);
    http.dataTimeout = dur!"seconds"(30);
    foreach (name, value; httpHeaders)
        http.addRequestHeader(name, value);

    try
    {
        return pkg.getNarInfoUrl(binaryCacheHttpEndpoint)
            .httpGet(http)
            .lineSplitter
            .canFind("StorePath: " ~ pkg.output);
    }
    catch (HTTPStatusException e)
    {
        if (cacheProbeHttpStatusIsMiss(e.status))
            return false;
        else
            throw e;
    }
    catch (CurlException)
    {
        return false;
    }
}

bool cacheProbeHttpStatusIsMiss(long status) pure nothrow @safe
{
    // Cache lookup is an optimisation: if a cache rejects, rate-limits, or
    // otherwise cannot answer a narinfo request, the safe result is "not
    // proven cached" so CI builds the output.  An HTTP cache failure must not
    // abort matrix generation and skip the build entirely.
    return status >= 400 && status < 600;
}

@("cache probe HTTP failures are cache misses")
unittest
{
    foreach (status; [401L, 403L, 404L, 429L, 500L, 503L])
        assert(cacheProbeHttpStatusIsMiss(status));

    assert(!cacheProbeHttpStatusIsMiss(200));
    assert(!cacheProbeHttpStatusIsMiss(302));
}

@("isCached")
unittest
{
    const nixosCacheEndpoint = "https://cache.nixos.org/";
    const storePathHash = "mdb034kf7sq6g03ric56jxr4a7043l41";
    const storePath = "/nix/store/" ~ storePathHash ~ "-hello-2.12.1";

    auto testPackage = Package(
        output: storePath,
    );

    assert(testPackage.isCached(
        binaryCacheHttpEndpoint: nixosCacheEndpoint,
        httpHeaders: string[string].init,
    ));

    testPackage.output ~= "non-existant";
    assert(!testPackage.isCached(
        binaryCacheHttpEndpoint: nixosCacheEndpoint,
        httpHeaders: string[string].init,
    ));

    assert(!testPackage.isCached(
        binaryCacheHttpEndpoint: "http://127.0.0.1:1",
        httpHeaders: string[string].init,
    ));
}

Package[] getPrecalcMatrix(T)(auto ref T args)
    if (is(T == PrintTableArgs) || is(T == DeploySpecArgs))
{
    auto precalcMatrixStr = args.precalcMatrix == "" ? `{"include": []}` : args.precalcMatrix;
    return parseJSON(precalcMatrixStr)["include"].array.map!(fromJSON!Package).array;
}

@(Command("merge-ci-matrices", "merge_ci_matrices")
    .Description("Merge downloaded matrix-pre.json artifacts and emit GitHub outputs"))
struct MergeMatricesArgs
{
    @(NamedArgument(["github-output"])
        .Placeholder("output")
        .Description("Output to GitHub Actions")
        .EnvFallback("GITHUB_OUTPUT")
    )
    string githubOutput;
}

export int merge_ci_matrices(MergeMatricesArgs args)
{
    return mergeCiMatrices(args);
}

int mergeCiMatrices(MergeMatricesArgs args, string searchRoot = ".")
{
    import std.algorithm : sort;
    import std.file : isFile;

    auto matrixFiles = dirEntries(searchRoot, "matrix-pre.json", SpanMode.depth)
        .filter!(entry => entry.isFile)
        .array
        .sort!((a, b) => a.name < b.name);

    if (matrixFiles.length == 0)
    {
        stderr.writeln("No matrix-pre.json artifacts found");
        return 1;
    }

    JSONValue[] filteredInclude;
    JSONValue[] fullInclude;

    foreach (entry; matrixFiles)
    {
        infof("Found matrix file: %s", entry.name);
        auto json = entry.name.readText.parseJSON;

        if (json.type != JSONType.object || !("include" in json) || json["include"].type != JSONType.array)
        {
            warningf("Skipping file with unexpected shape: %s", entry.name);
            continue;
        }

        foreach (pkg; json["include"].array)
        {
            fullInclude ~= pkg;
            if (pkg.type == JSONType.object && pkg.shouldIncludeInBuildMatrix)
                filteredInclude ~= pkg;
        }
    }

    auto matrix = JSONValue([
        "include": JSONValue(filteredInclude)
    ]);

    auto fullMatrix = JSONValue([
        "include": JSONValue(fullInclude)
    ]);

    const matrixStr = matrix.toString(JSONOptions.doNotEscapeSlashes);
    const fullMatrixStr = fullMatrix.toString(JSONOptions.doNotEscapeSlashes);

    auto outputPath = args.githubOutput;
    if (outputPath == "")
    {
        createResultDirs();
        outputPath = resultDir.buildPath("gh-output.env");
    }

    outputPath.append("build_matrix=" ~ matrixStr ~ "\n");
    outputPath.append("full_matrix=" ~ fullMatrixStr ~ "\n");

    writeln("---");
    writeln("Matrix:");
    writeln(matrixStr);
    writeln("---\n");

    writeln("---");
    writeln("Full Matrix:");
    writeln(fullMatrixStr);
    writeln("---");

    return 0;
}
