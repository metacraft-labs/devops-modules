module mcl.utils.path;

import std.process : execute;
import std.string : strip;
import std.file : mkdirRecurse, rmdir, exists;
import std.path : buildNormalizedPath, absolutePath;

immutable string rootDir, resultDir, gcRootsDir;

shared static this()
{
    rootDir = getTopLevel();
    resultDir = rootDir.buildNormalizedPath(".result");
    gcRootsDir = resultDir.buildNormalizedPath("gc-roots");
}

string getTopLevel()
{
    import std.process : environment;
    import mcl.utils.user_info : isNixbld;

    if (isNixbld)
        return environment["NIX_BUILD_TOP"];

    auto res = execute(["git", "rev-parse", "--show-toplevel"]);
    if (res.status != 0)
        return ".".absolutePath.buildNormalizedPath;

    return res.output.strip;
}

@("rootDir")
unittest
{
    assert(rootDir == getTopLevel());
}

@("resultDir")
unittest
{
    assert(resultDir == rootDir.buildNormalizedPath(".result"));
}

@("gcRootsDir")
unittest
{
    assert(gcRootsDir == resultDir.buildNormalizedPath("gc-roots"));
}

void createResultDirs()
{
    mkdirRecurse(gcRootsDir);
}

@("createResultDirs")
unittest
{
    createResultDirs();
    assert(gcRootsDir.exists);

    // rmdir(gcRootsDir());
    // rmdir(resultDir());
    // assert(!gcRootsDir.exists);
}
