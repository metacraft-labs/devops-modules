module mcl.utils.log;

void errorAndExit(string message) {
    import core.stdc.stdlib: exit;
    import std.stdio : stderr;

    stderr.writeln(message);
    exit(1);
}

T prompt(T)(string message, T[] options = [], string input = "unfilled")
{
    import std.stdio : write, writeln, readln;
    import std.string : strip;
    import std.algorithm : canFind, map;
    import std.conv : to;
    import std.traits : EnumMembers;

    static if (is(T == enum))
    {
        options = [EnumMembers!T];
    }

    write(message);
    if (options.length)
    {
        write(" [");
        foreach (i, option; options)
        {
            write(option);
            if (options.length > 0 && i < options.length - 1)
                write(", ");
        }
        write("]");
    }
    write(": ");
    if (input == "unfilled")
    {
        input = readln().strip();
    }
    if (options.length && !options.canFind(input.to!T))
    {
        writeln("Invalid input.");
        return prompt!T(message, options);
    }
    static if (is(T == string))
    {
        return input;
    }
    else static if (is(T == bool))
    {
        switch (input)
        {
        case "y", "yes", "true", "normal":
            return true;
        case "n", "no", "false", "root":
            return false;
        default:
            writeln("Invalid input.");
            return prompt!T(message, options);
        }
    }
    else static if (is(T == U[], U))
    {
        T ret;
        while (true)
        {
            if (input == "")
            {
                return ret;
            }
            auto value = prompt!U("", options[0], input);
            ret ~= value;
        }
    }
    else
    {
        return input.to!T;
    }
}
