module mcl.utils.nix;
import mcl.utils.test;

import std.algorithm : filter, endsWith;
import std.array : array;
import std.conv : to;
import std.exception : enforce;
import std.format : fmt = format;
import std.string : lineSplitter, strip, replace;
import std.json : parseJSON, JSONValue;
import std.stdio : writeln;

import mcl.utils.process : execute;

string queryStorePath(string storePath, string[] referenceSuffixes, string storeUrl)
{
    string lastMatch = storePath;

    foreach (suffix; referenceSuffixes)
        lastMatch = findMatchingNixReferences(lastMatch, suffix, storeUrl);

    return lastMatch;
}

string findMatchingNixReferences(string nixStorePath, string suffix, string storeUrl)
{
    auto matches = nixQueryReferences(nixStorePath, storeUrl)
        .filter!(path => path.endsWith(suffix))
        .array;

    enforce(matches.length > 0,
        "No store paths with suffix: '%s'".fmt(suffix));
    enforce(matches.length == 1,
        "Multiple store paths with suffix: '%s'".fmt(suffix));

    return matches[0];
}

string[] nixQueryReferences(string nixStorePath, string storeUrl)
{
    return [
        "nix-store", "--store", storeUrl, "--query", "--references", nixStorePath
    ]
        .execute
        .lineSplitter
        .array
        .to!(string[]);
}

auto nix() => NixCommand();

struct NixCommand
{
    static immutable supportedCommands = [
        "build", "copy", "derivation", "doctor", "eval", "fmt", "help", "key",
        "nar", "print-dev-env", "realisation", "repl",
        "search", "show-config", "upgrade-nix", "bundle", "daemon", "develop",
        "edit", "flake", "hash", "help-stores", "log",
        "path-info", "profile", "registry", "run", "shell", "store", "why-depends"
    ];

    template opDispatch(string commandName)
    {
        T opDispatch(T = string)(string path, string[] args = [], bool printCommand = false)
        {
            import std.algorithm : canFind;

            static assert(
                is(T == string) || is(T == JSONValue),
                "NixCommand only supports string or JSONValue template args, not `" ~ T.stringof ~ "`."
            );

            static assert(
                supportedCommands.canFind(commandName),
                "`" ~ commandName ~ "` is not a valid Nix command."
            );


            static if (is(T == JSONValue))
                args = ["--json"] ~ args;

            auto command = [
                "nix", "--experimental-features", "nix-command flakes",
                commandName,
            ] ~ args ~ path;

            // In the unit-test binary every Nix call is time-bounded, so a
            // stuck evaluation or fetch fails the test instead of occupying a
            // CI runner until the job-level timeout.
            version (unittest)
                command = ["timeout", "--kill-after=30s", "10m"] ~ command;

            auto output = command.execute(printCommand: printCommand, throwOnError: true).strip();

            static if (is(T == JSONValue))
                return parseJSON(output);
            else
                return output;
        }
    }
}

struct Literal {
    string value;
    alias value this;
    ref Literal opAssign(string value) { this.value = value; return this; }
    this(string value) { this.value = value; }
}

Literal mkDefault(T)(T value) {
import std.traits : isNumeric, isSomeString;
import std.json : JSONValue, JSONOptions;
    string ret = "lib.mkDefault ";
    static if (is(T == Literal))
        ret ~= value;
    else static if (is(T == bool) || isSomeString!T || isNumeric!T)
        ret ~=JSONValue(value).toString(JSONOptions.doNotEscapeSlashes);
    else
        static assert(false, "Unsupported type: `" ~ T.stringof ~ "`");
    return Literal(ret);
}

string toNix(T)(in T value, string[] inputs = [], bool topLevel = true, int depth = -1) {
import std.traits : isNumeric, isAssociativeArray, isSomeString, isArray, ForeachType, hasUDA;
import std.json : JSONValue,JSONOptions;
import std.string : join;
import std.array : replicate;
import std.algorithm : map, startsWith, all;
import std.ascii : isUpper;

    depth++;
    string res;

    if (inputs.length)
        res ~= "{" ~ inputs.map!(a =>  a == "dots" ? "..." : a ).join(", ") ~ "}: ";

    static if (is(T == Literal))
        res ~= value;
    else static if (is(T == bool) || isSomeString!T || isNumeric!T)
        res ~=JSONValue(value).toString(JSONOptions.doNotEscapeSlashes);
    else static if (is(T == struct))
    {
        string[] result;
        string tempResult;
        static foreach (idx, field; T.tupleof)
        {
            tempResult = "\t".replicate(depth+1);
            static if (is(typeof(field) == Literal)) {
                static if (__traits(identifier, field).startsWith("_literal"))
                    tempResult ~= value.tupleof[idx];
                else
                    tempResult ~= __traits(identifier, field) ~ " = " ~ value.tupleof[idx] ~ ";";
            }
            else static if (isArray!(typeof(field)) && is(ForeachType!(typeof(field)) == Literal) && __traits(identifier, field).startsWith("_literal"))
                res ~= value.tupleof[idx].map!(a => a.toNix([], false, 0)).join("\n");
            else static if (is(typeof(field) == struct) && field.tupleof.length == 1 && !__traits(identifier, field.tupleof[0]).all!(isUpper)) {
                tempResult ~= __traits(identifier, field) ~ "." ~ value.tupleof[idx].toNix([], false, -2) ~ ";";
            }
            else static if (isAssociativeArray!(typeof(field))) {
                if (value.tupleof[idx].array.length == 1) {
                    tempResult ~= __traits(identifier, field) ~ "." ~ value.tupleof[idx].toNix([], false, -2) ~ ";";
                }
                else {
                    tempResult ~= __traits(identifier, field) ~ " = " ~ value.tupleof[idx].toNix([], false, depth) ~ ";";
                }
            }
            else {
                tempResult ~= __traits(identifier, field) ~  " = " ~ value.tupleof[idx].toNix([], false, depth) ~ ";";
            }
            result ~= tempResult;
        }
        static if (T.tupleof.length != 1)
            res ~= ("{\n" ~ result.join("\n") ~"\n" ~ "\t".replicate(depth) ~ "}" ~ (topLevel ? "" : ";") );
        else
            res ~= result[0];
    }
    else static if (isAssociativeArray!T) {
        string[] result;
        string tempResult;
        foreach (key, val; value)
        {
            tempResult = "\t".replicate(depth+1) ~ key.to!string;
            static if (is(typeof(val) == struct) && val.tupleof.length == 1) {
                tempResult ~= "." ~ val.toNix([], false, -2) ~ ";";
            }
            else static if (isAssociativeArray!(typeof(val))) {
                if (value.tupleof[idx].array.length == 1) {
                    tempResult ~= "." ~ val.toNix([], false, -2) ~ ";";
                }
                else {
                    tempResult ~= " = " ~ val.toNix([], false, depth) ~ ";";
                }
            }
            else {
                tempResult ~= " = " ~ val.toNix([], false, depth) ~ ";";
            }
            result ~= tempResult;
        }
        if (value.length != 1)
            res ~= ("{\n" ~ result.join("\n") ~ "\n" ~ "\t".replicate(depth) ~ "}" ~ (topLevel ? "" : ";"));
        else
            res ~= result[0];

    }
    else static if (is(T == U[], U))
    {
        string[] result;
        if (value.length > 1) {
            result ~= "[";
            foreach (elem; value){
                result ~= "\t".replicate(depth+1) ~ elem.toNix([], false, depth);
            }
            result ~= "\t".replicate(depth) ~ "];";
            res ~= result.join("\n");
        }
        else if (value.length == 1) {
            res ~= "[" ~ value[0].toNix([], false, depth) ~ "]";

        }
        else {
            res ~= "[]";
        }
    }
    else
    {
        static assert(false, "Unsupported type: `" ~ T.stringof ~ "`");
    }

    return res.replace(";;", ";");
}

@("toNix")
unittest
{
    struct TestStruct
    {
        int a;
        string b;
        bool c;
    }
    assert(toNix(TestStruct(1, "hello", true)) == "{\n\ta = 1;\n\tb = \"hello\";\n\tc = true;\n}");
    assert(toNix(true) == "true");
    assert(toNix("hello") == "\"hello\"");
    assert(toNix(1) == "1");

    struct TestStruct2
    {
        int a;
        TestStruct b;
    }
    assert(toNix(TestStruct2(1, TestStruct(2, "hello", false))) == "{\n\ta = 1;\n\tb = {\n\t\ta = 2;\n\t\tb = \"hello\";\n\t\tc = false;\n\t};\n}");
}

@("nix.run")
unittest
{
    import std.stdio : writeln;
    import std.range : front;

    import std.path : absolutePath, dirName;

    auto p = __FILE__.absolutePath.dirName;

    string output = nix().run(p ~ "/test/test.nix", [ "--file"]);
    assert(output == "Hello World", "Expected 'Hello World', got: " ~ output);
}

@("nix.build!JSONValue")
unittest
{
    import std.stdio : writeln;
    import std.range : front;

    import std.path : absolutePath, dirName;
    import std.json : JSONType;

    auto p = __FILE__.absolutePath.dirName;

    JSONValue output = nix().build!JSONValue(p ~ "/test/test.nix", ["--file"]);
    assert(output.type == JSONType.array, "Expected an array, got: " ~ output.type.to!string);
    output = output.array.front;
    assert(execute([output["outputs"]["out"].str ~ "/bin/helloWorld"]).strip == "Hello World");
}

@("nix.eval!JSONValue")
unittest
{
    import std.json : parseJSON;
    import std.file : getcwd, readText;
    import std.path : buildPath, setExtension, dirName;

    auto inputFile = __FILE_FULL_PATH__.dirName.buildPath("test/eval.nix");
    auto expectedOutputFile = inputFile.setExtension("json");

    auto output = nix().eval!JSONValue(inputFile, ["--file"]);
    assert(output == expectedOutputFile.readText.parseJSON);
}
