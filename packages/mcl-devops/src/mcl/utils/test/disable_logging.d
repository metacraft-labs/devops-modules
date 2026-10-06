module mcl.utils.test.disable_logging;

version (unittest)
{
    shared static this()
    {
        import std.logger : sharedLog, LogLevel, NullLogger;

        if ("DEBUG" !in imported!"std.process".environment) {
            sharedLog = cast(shared NullLogger) new NullLogger(LogLevel.all);
        }
    }
}
