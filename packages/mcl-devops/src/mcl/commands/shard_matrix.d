module mcl.commands.shard_matrix;

import std.algorithm : map, sort, startsWith, uniq;
import std.array : array;
import std.conv : ConvException, to, parse;
import std.exception : ifThrown;
import std.file : write, readText;
import std.format : fmt = format;
import std.logger : warningf, infof;
import std.stdio : stdout, stderr;
import std.path : buildPath;
import std.range : iota, empty, walkLength;
import std.regex : matchFirst, regex;
import std.string : strip;
import std.typecons : Nullable, nullable;

import argparse : Command, Description, NamedArgument, Placeholder, EnvFallback;

import mcl.utils.json : toJSON;
import mcl.utils.nix : nix;
import mcl.utils.path : createResultDirs, resultDir, rootDir;
import mcl.utils.string : enumToString, writeRecordAsTable;
import mcl.commands.ci_matrix : NixSystem, currentSystem, ci_matrix, CiMatrixArgs, CiMatrixBaseArgs,
    appendGitHubOutput, requestedEvalSystems;

@(Command("shard-matrix", "shard_matrix")
    .Description("Generate a shard matrix for a flake"))
struct ShardMatrixArgs
{
    mixin CiMatrixBaseArgs!();
}

export int shard_matrix(ShardMatrixArgs args)
{
    args.writeRecordAsTable(stderr.lockingTextWriter);

    // A call that builds only some systems (the reusable workflow's
    // `build-systems`, passed as MCL_EVAL_SYSTEMS) evaluates only those. infra
    // splits one flake into a Linux and a Darwin call; when each evaluated
    // every system, every shard was evaluated twice per run.
    const evalSystems = requestedEvalSystems();
    auto evalMatrix = generateEvalMatrix(evalSystems,
        (Nullable!NixSystem system) => generateShardMatrix(".", system));

    // if the matrix is empty, directly run ci-matrix to generate build_matrix
    if (evalMatrix.include.empty)
    {
        infof("No shards found, running ci-matrix directly for build matrix");
        ci_matrix(CiMatrixArgs(
            maxWorkers: args.maxWorkers,
            maxMemory: args.maxMemory,
            isInitial: true,
            cachixCache: args.cachixCache,
            extraCachixCaches: args.extraCachixCaches,
            extraCacheUrls: args.extraCacheUrls,
            atticSubstituter: args.atticSubstituter,
            atticAuthToken: args.atticAuthToken,
            cachixAuthToken: args.cachixAuthToken,
            precalcMatrix: null,
            nixSystemToGHRunner: args.nixSystemToGHRunner,
            githubOutput: args.githubOutput,
        ));
    }
    else
    {
        saveShardMatrix(evalMatrix, args, evalArtifactPattern(evalSystems));
    }

    return 0;
}

struct Shard
{
    string flakeAttrPath;
    string filename;
}

struct ShardMatrix
{
    Shard[] include;
}

/// The eval matrix for `systems`: today's all-systems shards when `systems`
/// is empty, otherwise the per-system shards of each requested system, in
/// order. `generate` is `generateShardMatrix` bound to the flake.
ShardMatrix generateEvalMatrix(
    const(NixSystem)[] systems,
    ShardMatrix delegate(Nullable!NixSystem) generate,
)
{
    import std.array : join;

    // `.array` before `.join`: a lazy `map` would re-run `generate` (a
    // `nix eval` per call) every time `join` looks at an element.
    return systems.empty
        ? generate(Nullable!NixSystem.init)
        : systems
            .map!(system => generate(Nullable!NixSystem(system)).include)
            .array
            .join
            .ShardMatrix;
}

/// The `actions/download-artifact` pattern that matches exactly the shard
/// artifacts of an eval matrix for `systems`. Two calls in one run (infra's
/// `ci` and `ci-darwin`) share the run's artifact namespace, so each must
/// download only its own shards.
string evalArtifactPattern(const(NixSystem)[] systems)
{
    import std.algorithm : joiner;
    import std.conv : text;

    return systems.empty
        ? "matrix-pre-shard-*"
        : systems.length == 1
            ? "matrix-pre-%s-shard-*".fmt(systems[0].enumToString)
            : "matrix-pre-{%s}-shard-*".fmt(systems.map!(s => s.enumToString).joiner(",").text);
}

@("generateEvalMatrix restricts to the requested systems")
unittest
{
    Nullable!NixSystem[] asked;
    ShardMatrix fake(Nullable!NixSystem system)
    {
        asked ~= system;
        // Stand-in for the flake: 3 all-systems shards, 2 Linux, 1 Darwin.
        return system.isNull ? splitToShards(3)
            : system.get == NixSystem.x86_64_linux ? splitToShards(2, system)
            : system.get == NixSystem.aarch64_darwin ? splitToShards(1, system)
            : ShardMatrix([]);
    }

    // Nothing requested: exactly today's matrix, one all-systems probe.
    asked = [];
    assert(generateEvalMatrix([], &fake) == splitToShards(3));
    assert(asked.length == 1 && asked[0].isNull);

    // One system: only its shards; the other system is never probed.
    asked = [];
    auto linux = generateEvalMatrix([NixSystem.x86_64_linux], &fake);
    assert(asked == [nullable(NixSystem.x86_64_linux)]);
    assert(linux.include.map!(s => s.flakeAttrPath).array == [
        "mcl.shard-matrix.result.shardsPerSystem.x86_64-linux.shard-0",
        "mcl.shard-matrix.result.shardsPerSystem.x86_64-linux.shard-1",
    ]);
    auto darwin = generateEvalMatrix([NixSystem.aarch64_darwin], &fake);
    assert(darwin.include == [Shard(
        flakeAttrPath: "mcl.shard-matrix.result.shardsPerSystem.aarch64-darwin.shard-0",
        filename: "matrix-pre-aarch64-darwin-shard-0.json",
    )]);

    // A Linux call plus a Darwin call evaluate every shard exactly once
    // between them, and their artifact names never collide.
    auto both = linux.include ~ darwin.include;
    assert(both.length == 3);
    assert(both.map!(s => s.filename).array.sort.uniq.walkLength == 3);

    // Two systems in one call: both, in the requested order.
    assert(generateEvalMatrix([NixSystem.aarch64_darwin, NixSystem.x86_64_linux], &fake).include
        == darwin.include ~ linux.include);

    // A requested system the flake does not build contributes nothing.
    assert(generateEvalMatrix([NixSystem.aarch64_linux], &fake).include == []);
}

@("evalArtifactPattern")
unittest
{
    assert(evalArtifactPattern([]) == "matrix-pre-shard-*");
    assert(evalArtifactPattern([NixSystem.x86_64_linux]) == "matrix-pre-x86_64-linux-shard-*");
    assert(evalArtifactPattern([NixSystem.x86_64_linux, NixSystem.aarch64_darwin])
        == "matrix-pre-{x86_64-linux,aarch64-darwin}-shard-*");
    // The all-systems pattern does not match a per-system artifact, and the
    // Linux pattern does not match the Darwin one (glob `*` is a suffix here).
    assert(!splitToShards(1, nullable(NixSystem.aarch64_darwin)).include[0]
        .filename.startsWith("matrix-pre-x86_64-linux-shard-"));
    assert(!splitToShards(1, nullable(NixSystem.x86_64_linux)).include[0]
        .filename.startsWith("matrix-pre-shard-"));
}

ShardMatrix generateShardMatrix(string flakeRef = ".", Nullable!NixSystem system = Nullable!NixSystem.init)
{
    import std.path : isValidPath, absolutePath, buildNormalizedPath;

    if (flakeRef.isValidPath) {
        flakeRef = flakeRef.absolutePath.buildNormalizedPath;
    }

    // A flake that does not import `modules.flake.shardSplit` declares no
    // `shardCount`, so this eval FAILS for most consumers. That is not an
    // error: it is how "this flake is unsharded" is reported, and the empty
    // result below turns it into `shardCount == 0` and the ci-matrix fallback
    // in `shard_matrix`.
    //
    // `logErrors: false` therefore suppresses the ERR line `execute` would
    // otherwise write for the missing attribute. It was logged at ERR purely
    // because `execute` logs every non-zero exit that way before throwing, and
    // the `.ifThrown` here discards that throw — so the ERR line described a
    // handled condition and read as a fatal one. It has been misdiagnosed as
    // the cause of unrelated job failures more than once; the real outcome is
    // reported by the two log lines below.
    const shardCountOutput = nix.eval(
        // Absolute attribute path (leading `.`): see `getSupportedSystems`.
        "%s#.mcl.shard-matrix.result.%s".fmt(
            flakeRef,
            system.isNull
                ? "shardCount"
                : "shardCountPerSystem.%s".fmt(system.get.enumToString),
        ),
        [], // args
        false, // printCommand
        false, // logErrors — see the comment above
    )
    .ifThrown("");

    // Empty means the probe above failed (no such attribute, or the eval could
    // not run at all) — both are reported as "no shards" by the warning below.
    infof("shardCount: '%s'", shardCountOutput);

    const shardCount = shardCountOutput
        .strip()
        .to!uint
        .ifThrown!ConvException(0);

    if (shardCount == 0)
        warningf(
            "No shards found: '%s' did not yield a shard count, so this flake "
                ~ "is treated as unsharded. Expected when it does not import "
                ~ "`modules.flake.shardSplit`; re-run the eval by hand if you "
                ~ "expected shards here.",
            flakeRef,
        );

    return splitToShards(shardCount, system);
}

@("generateShardMatrix.ok")
unittest
{
    version (none)
    {
        // See: https://github.com/metacraft-labs/devops-modules/blob/b70f5bf556a0afc25d45ff5abd9d4eeae58d2647/flake.nix
        auto flakeRef = "github:metacraft-labs/devops-modules?rev=b70f5bf556a0afc25d45ff5abd9d4eeae58d2647";
    }
    else
    {
        import mcl.utils.path : rootDir;
        auto flakeRef = rootDir.buildPath("packages/mcl-devops/src/mcl/utils/test/nix/shard-matrix-ok");
    }

    {
        auto shards = generateShardMatrix(flakeRef);
        assert(shards.include.length == 21);
    }

    {
        auto shards = generateShardMatrix(flakeRef, nullable(NixSystem.x86_64_linux));
        assert(shards.include.length == 11);
        assert(shards.include[0] == Shard(flakeAttrPath: "mcl.shard-matrix.result.shardsPerSystem.x86_64-linux.shard-00", filename: "matrix-pre-x86_64-linux-shard-00.json"));
    }

    {
        // `aarch64_linux` is not in `flake.mcl.shard-matrix.systemsToBuild`,
        // so no shards should be generated
        auto shards = generateShardMatrix(flakeRef, nullable(NixSystem.aarch64_linux));
        assert(shards.include == []);
    }
}

@("generateShardMatrix.fail")
unittest
{
    import mcl.utils.path : rootDir;
    import std.file : exists, isFile;

    auto flakeRef = rootDir.buildPath("packages/mcl-devops/src/mcl/utils/test/nix/shard-matrix-no-shards");
    assert(flakeRef.buildPath("flake.nix").exists && flakeRef.buildPath("flake.nix").isFile,
        "Missing declared no-shards flake fixture: " ~ flakeRef);

    auto shards = generateShardMatrix(flakeRef);
    assert(shards.include == []);
}

ShardMatrix splitToShards(int shardCount, Nullable!NixSystem system = Nullable!NixSystem.init)
{
    import core.internal.string : numDigits;
    const padWidth = shardCount.numDigits;
    return shardCount
        .iota
        .map!(i => Shard(
            // The per-system key is the Nix system string (`x86_64-linux`),
            // which is how `shard-split` names `shardsPerSystem`; the D enum
            // member name (`x86_64_linux`) is no attribute of the flake.
            flakeAttrPath: "mcl.shard-matrix.result.%s.shard-%0*s".fmt(
                system.isNull
                    ? "shards"
                    : "shardsPerSystem.%s".fmt(system.get.enumToString),
                padWidth,
                i,
            ),
            // Per-system shards carry the system in the artifact name, so two
            // calls of one run (one per system) never upload the same name.
            filename: system.isNull
                ? "matrix-pre-shard-%0*s.json".fmt(padWidth, i)
                : "matrix-pre-%s-shard-%0*s.json".fmt(system.get.enumToString, padWidth, i)
        ))
        .array
        .ShardMatrix;
}

@("splitToShards")
unittest
{
    auto shards = splitToShards(3);
    assert(shards.include.length == 3);
    assert(shards.include[0] == Shard(flakeAttrPath: "mcl.shard-matrix.result.shards.shard-0", filename: "matrix-pre-shard-0.json"));
    assert(shards.include[1] == Shard(flakeAttrPath: "mcl.shard-matrix.result.shards.shard-1", filename: "matrix-pre-shard-1.json"));
    assert(shards.include[2] == Shard(flakeAttrPath: "mcl.shard-matrix.result.shards.shard-2", filename: "matrix-pre-shard-2.json"));
}

void saveShardMatrix(ShardMatrix evalMatrix, ShardMatrixArgs args, string artifactPattern)
{
    import std.json : JSONValue;

    const evalMatrixJson = evalMatrix.toJSON();
    const evalMatrixString = evalMatrixJson.toString();
    infof("Eval matrix: %s", evalMatrixJson.toPrettyString);

    const evalMatrixLine = "eval_matrix=" ~ evalMatrixString ~ "\n";
    const buildMatrixLine = "build_matrix={\"include\":[]}\n"
        ~ "eval_artifact_pattern=" ~ artifactPattern ~ "\n";

    if (args.githubOutput != "")
    {
        args.githubOutput.appendGitHubOutput(evalMatrixLine ~ buildMatrixLine);
    }
    else
    {
        createResultDirs();
        resultDir.buildPath("gh-output.env").appendGitHubOutput(evalMatrixLine ~ buildMatrixLine);
    }
    rootDir.buildPath("shardMatrix.json").write(evalMatrixString);
}
