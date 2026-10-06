module mcl.utils.fetch;
import mcl.utils.test;

import std.json : JSONValue;

JSONValue fetchJson(string url, string authToken = "")
{
    import std.json : parseJSON;
    import std.net.curl : HTTP, get;
    import std.logger : log, LogLevel;

    auto client = HTTP();
    if (authToken != "")
    {
        client.addRequestHeader("Authorization", "Bearer " ~ authToken);
    }

    LogLevel.info.log("GET %s", url);

    auto response = get(url, client);
    return parseJSON(response);
}

@("fetchJson")
unittest
{
    auto json = fetchJson("https://v2.jokeapi.dev/joke/Programming?type=single&idRange=40");
    assert(json["category"].str == "Programming");
    assert(json["type"].str == "single");
    assert(json["joke"].str == "Debugging: Removing the needles from the haystack.");
}
