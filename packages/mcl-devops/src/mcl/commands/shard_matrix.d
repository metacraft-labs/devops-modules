module mcl.commands.shard_matrix;

import std.algorithm : map;
import std.array : array;
import std.conv : ConvException, to, parse;
import std.exception : ifThrown;
import std.file : write, readText;
import std.format : fmt = format;
import std.logger : warningf, infof;
import std.stdio : stdout, stderr;
import std.path : buildPath;
import std.range : iota, empty;
import std.regex : matchFirst, regex;
import std.string : strip;
import std.typecons : Nullable, nullable;

import argparse : Command, Description, NamedArgument, Placeholder, EnvFallback;

import mcl.utils.json : toJSON;
import mcl.utils.nix : nix;
import mcl.utils.path : createResultDirs, resultDir, rootDir;
import mcl.utils.string : enumToString, writeRecordAsTable;
import mcl.commands.ci_matrix : NixSystem, currentSystem, ci_matrix, CiMatrixArgs, CiMatrixBaseArgs,
    appendGitHubOutput;

@(Command("shard-matrix", "shard_matrix")
    .Description("Generate a shard matrix for a flake"))
struct ShardMatrixArgs
{
    mixin CiMatrixBaseArgs!();
}

export int shard_matrix(ShardMatrixArgs args)
{
    args.writeRecordAsTable(stderr.lockingTextWriter);

    auto evalMatrix = generateShardMatrix();

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
        saveShardMatrix(evalMatrix, args);
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

ShardMatrix generateShardMatrix(string flakeRef = ".", Nullable!NixSystem system = Nullable!NixSystem.init)
{
    import std.path : isValidPath, absolutePath, buildNormalizedPath;

    if (flakeRef.isValidPath) {
        flakeRef = flakeRef.absolutePath.buildNormalizedPath;
    }

    const shardCountOutput = nix.eval(
        // Absolute attribute path (leading `.`): see `getSupportedSystems`.
        "%s#.mcl.shard-matrix.result.%s".fmt(
            flakeRef,
            system.isNull
                ? "shardCount"
                : "shardCountPerSystem.%s".fmt(system.get.enumToString),
        )
    )
    .ifThrown("");

    infof("shardCount: '%s'", shardCountOutput);

    const shardCount = shardCountOutput
        .strip()
        .to!uint
        .ifThrown!ConvException(0);

    if (shardCount == 0)
        warningf("No shards found");

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
        assert(shards.include[0] == Shard(flakeAttrPath: "mcl.shard-matrix.result.shardsPerSystem.x86_64_linux.shard-00", filename: "matrix-pre-shard-00.json"));
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
    auto flakeRef = rootDir.buildPath("packages/mcl-devops/src/src/mcl/utils/test/nix/shard-matrix-no-shards");

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
            flakeAttrPath: "mcl.shard-matrix.result.%s.shard-%0*s".fmt(
                system.isNull
                    ? "shards"
                    : "shardsPerSystem.%s".fmt(system.get),
                padWidth,
                i,
            ),
            filename: "matrix-pre-shard-%0*s.json".fmt(padWidth, i)
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

void saveShardMatrix(ShardMatrix evalMatrix, ShardMatrixArgs args)
{
    import std.json : JSONValue;

    const evalMatrixJson = evalMatrix.toJSON();
    const evalMatrixString = evalMatrixJson.toString();
    infof("Eval matrix: %s", evalMatrixJson.toPrettyString);

    const evalMatrixLine = "eval_matrix=" ~ evalMatrixString ~ "\n";
    const buildMatrixLine = "build_matrix={\"include\":[]}\n";

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
