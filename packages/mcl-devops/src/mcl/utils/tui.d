module mcl.utils.tui;

string bold(const char[] s) => cast(string)("\033[1m" ~ s ~ "\033[0m");

bool supportsOscLinks()
{
    import std.process : environment;
    import core.sys.posix.unistd : isatty;
    import core.stdc.stdio : fileno, stderr;

    return !("CI" in environment) && isatty(fileno(stderr)) != 0;
}
