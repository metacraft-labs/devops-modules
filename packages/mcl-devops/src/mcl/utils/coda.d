module mcl.utils.coda;

struct RowValues
{
    CodaCell[] cells;
}

struct CodaCell
{
    string column;
    string value;
}

struct InsertRowRequest
{
    CodeTable table;
    RowValues[] rows;
}

struct CodeTable
{
    string documentId;
    string tableId;
}

import std.net.curl : HTTP, httpGet = get, httpPost = post, httpDelete = del, httpPatch = patch, httpPut = put, HTTPStatusException;
import std.json : JSONValue, parseJSON, JSONOptions;
import std.format : format;
import std.datetime : SysTime;
import std.traits : isArray;
import mcl.utils.json : toJSON, fromJSON;
import std.process : environment;
import std.stdio : writeln, writefln;
import std.algorithm : map, filter;
import std.exception : assertThrown;
import std.sumtype : SumType;
import std.array : join;
import core.thread;

struct CodaApiClient
{
    string apiToken;
    string baseEndpoint = "https://coda.io/apis/v1";

    struct Document
    {
        string browserLink;
        SysTime createdAt;
        struct DocSize
        {
            bool overApiSizeLimit;
            int pageCount;
            int tableAndViewCount;
            int totalRowCount;
        }

        DocSize docSize;
        struct Folder
        {
            string browserLink;
            string id;
            string name;
            string type;
        }

        Folder folder;
        string folderId;
        string href;
        struct Icon
        {
            string browserLink;
            string name;
            string type;
        }

        Icon icon;
        string id;
        string name;
        string owner;
        string ownerName;
        struct SourceDoc
        {
            string browserLink;
            string href;
            string id;
            string type;

        }

        string type;
        SysTime updatedAt;
        struct Workspace
        {
            string browserLink;
            string id;
            string name;
            string type;
        }

        Workspace workspace;
        string workspaceId;
    }

    Document getDocument(string documentId)
    {
        string url = "/docs/%s".format(documentId);
        return get!Document(url, JSONValue(null), false);
    }

    @("coda.getDocument")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto resp = coda.getDocument("6vM0kjfQP6");
        assert(resp.id == "6vM0kjfQP6");
    }

    Document[] listDocuments()
    {
        string url = "/docs";
        return get!(Document[])(url, JSONValue(null), false);
    }

    @("coda.listDocuments")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto resp = coda.listDocuments();
        assert(resp.length > 0);
    }

    struct InitialPage
    {
        string name;
        string subtitle;
        string iconName;
        string imageUrl;
        string parentPageId;
        struct PageContent
        {
            string type = "canvas";
            struct CanvasContent
            {
                string format;
                string content;
            }

            CanvasContent canvasContent;
        }

        PageContent pageContent;
    }

    Document createDocument(string title, string sourceDoc = "", string timezone = "Europe/Sofia", string folderID = "", InitialPage initialPage)
    {
        string url = "/docs";
        JSONValue req = JSONValue(
            [
                "title": JSONValue(title),
                "initialPage": initialPage.toJSON,
                "timezone": JSONValue(timezone)
            ]);
        if (sourceDoc != "")
            req["sourceDoc"] = JSONValue(sourceDoc);
        if (folderID != "")
            req["folderId"] = JSONValue(folderID);

        if (req["initialPage"].object["imageUrl"].str == "")
            req["initialPage"].object.remove("imageUrl");
        if (req["initialPage"].object["parentPageId"].str == "")
            req["initialPage"].object.remove("parentPageId");

        return post!Document(url, req);
    }

    void deleteDocument(string documentId)
    {
        string url = "/docs/%s".format(documentId);
        del!Document(url);
    }

    @("coda.createDocument/deleteDocument")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        InitialPage initialPage = InitialPage("Test Page", "Test Subtitle", "doc:blank", "", "",
            InitialPage.PageContent("canvas",
                InitialPage.PageContent.CanvasContent("html", "<p><b>This</b> is rich text</p>")));
        auto resp = coda.createDocument("Test Document", "", "Europe/Sofia", "", initialPage);
        assert(resp.name == "Test Document");
        coda.deleteDocument(resp.id);
        assertThrown!(HTTPStatusException)(coda.getDocument(resp.id));
    }

    Document patchDocument(string documentId, string title = "", string iconName = "")
    {
        JSONValue req = JSONValue();
        if (title != "")
            req["title"] = JSONValue(title);
        if (iconName != "")
            req["icon"] = JSONValue(iconName);

        string url = "/docs/%s".format(documentId);
        return patch!Document(url, req);
    }

    @("coda.patchDocument")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        InitialPage initialPage = InitialPage("Test Page", "Test Subtitle", "doc:blank", "", "",
            InitialPage.PageContent("canvas",
                InitialPage.PageContent.CanvasContent("html", "<p><b>This</b> is rich text</p>")));
        auto resp = coda.createDocument("Test Document", "", "Europe/Sofia", "", initialPage);
        coda.patchDocument(resp.id, "Patched Document", "");
        auto patched = coda.getDocument(resp.id);
        assert(patched.name == "Patched Document");
        coda.deleteDocument(patched.id);
    }

    struct Table {
        string id;
        string type;
        string tableType;
        string href;
        string browserLink;
        string name;
        struct Parent {
            string id;
            string type;
            string href;
            string browserLink;
            string name;
        }
        Parent parent;
        struct ParentTable {
            string id;
            string type;
            string tableType;
            string href;
            string browserLink;
            string name;
            Parent parent;
        }
        ParentTable parentTable;
        struct DisplayColumn {
            string id;
            string type;
            string href;
        }
        DisplayColumn displayColumn;
        int rowCount;
        struct Sort {
            string direction;
            struct Column {
                string id;
                string type;
                string href;
            }
            Column column;
        }
        Sort[] sorts;
        string layout;
        struct Filter {
            bool valid;
            bool isVolatile;
            bool hasUserFormula;
            bool hasTodayFormula;
            bool hasNowFormula;
        }
        Filter filter;
        SysTime createdAt;
        SysTime updatedAt;
    }

    Table[] listTables(string documentId)
    {
        string url = "/docs/%s/tables".format(documentId);
        return get!(Table[])(url);
    }

    @("coda.listTables")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto resp = coda.listTables("6vM0kjfQP6");
        assert(resp.length > 0);
    }

    Table getTable(string documentId, string tableId)
    {
        string url = "/docs/%s/tables/%s".format(documentId, tableId);
        return get!Table(url);
    }

    @("coda.getTable")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto tables = coda.listTables("6vM0kjfQP6");
        auto resp = coda.getTable("6vM0kjfQP6", tables[0].id);
        assert(resp.id == tables[0].id);
    }

    struct Column {
        string id;
        string type;
        string href;
        string name;
        bool display;
        bool calculated;
        string formula;
        string defaultValue;
        struct Format {
            string type;
            bool isArray;
            string label;
            string disableIf;
            string action;
        }
        Format format;
        struct Parent {
            string id;
            string type;
            string tableType;
            string href;
            string browserLink;
            string name;
            struct ParentParent {
                string id;
                string type;
                string href;
                string browserLink;
                string name;
            }
            ParentParent parent;
        }
        Parent parent;
    }

    Column[] listColumns(string documentId, string tableId)
    {
        string url = "/docs/%s/tables/%s/columns".format(documentId, tableId);
        return get!(Column[])(url);
    }

    @("coda.listColumns")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto tables = coda.listTables("6vM0kjfQP6");
        auto resp = coda.listColumns("6vM0kjfQP6", tables[0].id);
        assert(resp.length > 0);
    }

    Column getColumn(string documentId, string tableId, string columnId)
    {
        string url = "/docs/%s/tables/%s/columns/%s".format(documentId, tableId, columnId);
        return get!Column(url);
    }

    @("coda.getColumn")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto tables = coda.listTables("6vM0kjfQP6");
        auto columns = coda.listColumns("6vM0kjfQP6", tables[0].id);
        auto resp = coda.getColumn("6vM0kjfQP6", tables[0].id, columns[0].id);
        assert(resp.id == columns[0].id);
    }

    alias RowValue = SumType!(string, int, bool, string[], int[], bool[]);

    struct Row {
        string id;
        string type;
        string href;
        string name;
        int index;
        string browserLink;
        SysTime createdAt;
        SysTime updatedAt;
        RowValue[string] values;
        struct Parent {
            string id;
            string type;
            string tableType;
            string href;
            string browserLink;
            string name;
            struct ParentParent {
                string id;
                string type;
                string href;
                string browserLink;
                string name;
            }
            ParentParent parent;
        }
    }

    Row[] listRows(string documentId, string tableId)
    {
        string url = "/docs/%s/tables/%s/rows".format(documentId, tableId);
        return get!(Row[])(url);
    }

    @("coda.listRows")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto tables = coda.listTables("6vM0kjfQP6");
        auto resp = coda.listRows("6vM0kjfQP6", tables[0].id);
        assert(resp.length > 0);
    }

    struct InsertRowsReturn {
        string requestId;
        string[] addedRowIds;
    }

    string[] insertRows(string documentId, string tableId, RowValues[] rows, string[] keyColumns = [])
    {
        string url = "/docs/%s/tables/%s/rows".format(documentId, tableId);
        JSONValue req = JSONValue(
            [
                "rows": rows.toJSON
            ]);
        if (keyColumns.length)
            req["keyColumns"] = JSONValue(keyColumns.toJSON);
        return post!InsertRowsReturn(url, req, false).addedRowIds;
    }

    // Can't be implemented because of the lack of support for a body in DELETE requests
    // void deleteRows(string documentId, string tableId, string[] rowIds)
    // {
    //     string url = "/docs/%s/tables/%s/rows".format(documentId, tableId);
    //     JSONValue req = JSONValue(
    //         [
    //             "rowIds": JSONValue(rowIds)
    //         ]);
    //     del!Row(url, req);
    // }

    void deleteRow(string documentId, string tableId, string rowId)
    {
        string url = "/docs/%s/tables/%s/rows/%s".format(documentId, tableId, rowId);
        del!Row(url, JSONValue(null), false);
    }

    @("coda.insertRows/deleteRow")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto tables = coda.listTables("dEJJPwdxcw");
        RowValues[] rows = [
            RowValues([
                CodaCell("c-p6Yjm8zaEH", "Test Name"),
            ])
        ];
        auto resp = coda.insertRows("dEJJPwdxcw", tables[0].id, rows);
        assert(resp.length > 0);
        coda.deleteRow("dEJJPwdxcw", tables[0].id, resp[0]);
        assertThrown!(HTTPStatusException)(coda.getRow("dEJJPwdxcw", tables[0].id, resp[0]));
    }

    Row getRow(string documentId, string tableId, string rowId)
    {
        string url = "/docs/%s/tables/%s/rows/%s".format(documentId, tableId, rowId);
        return get!Row(url, JSONValue(null), false);
    }

    @("coda.getRow")
    unittest {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto tables = coda.listTables("dEJJPwdxcw");
        auto rows = coda.listRows("dEJJPwdxcw", tables[0].id);
        auto resp = coda.getRow("dEJJPwdxcw", tables[0].id, rows[0].id);
        assert(resp.id == rows[0].id);
    }

    struct UpdateRowReturn {
        string requestId;
        string id;
    }

    string updateRow(string documentId, string tableId, string rowId, RowValues row, string[] keyColumns = [])
    {
        string url = "/docs/%s/tables/%s/rows/%s".format(documentId, tableId, rowId);
        JSONValue req = JSONValue(
            [
                "row": row.toJSON
            ]);
        return put!UpdateRowReturn(url, req).id;
    }

    @("coda.updateRow")
    unittest {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto tables = coda.listTables("dEJJPwdxcw");
        RowValues[] rows = [
            RowValues([
                CodaCell("c-p6Yjm8zaEH", "Test Name"),
            ])
        ];
        auto resp = coda.insertRows("dEJJPwdxcw", tables[0].id, rows);
        RowValues newRow = RowValues([
            CodaCell("c-p6Yjm8zaEH", "Updated Name"),
        ]);

        auto updated = coda.updateRow("dEJJPwdxcw", tables[0].id, resp[0], newRow);

        assert(updated == resp[0]);
        coda.deleteRow("dEJJPwdxcw", tables[0].id, resp[0]);
    }

    void upsertRow(string docId, string tableId, RowValues values, string[] keyColumns = ["name"]) {
        insertRows(docId, tableId, [values], keyColumns);
    }
    void upsertRows(string docId, string tableId, RowValues[] values, string[] keyColumns = ["name"]) {
        insertRows(docId, tableId, values, keyColumns);
    }
    struct PushButtonResponse {
        string requestId;
        string rowId;
        string columnId;
    }

    PushButtonResponse pushButton(string documentId, string tableId, string rowId, string columnId) {
        string url = "/docs/%s/tables/%s/rows/%s/buttons/%s".format(documentId, tableId, rowId, columnId);
        return post!PushButtonResponse(url);
    }

    @("coda.pushButton")
    unittest {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto tables = coda.listTables("dEJJPwdxcw");
        RowValues[] rows = [
            RowValues([
                CodaCell("c-p6Yjm8zaEH", "Test Name"),
            ])
        ];
        auto buttonColumn = "c-9MA3HmNByK";
        auto rowId = "i-HV8Hsf2O8H";
        auto buttonResp = coda.pushButton("dEJJPwdxcw", tables[0].id, rowId, buttonColumn);
        assert(buttonResp.rowId == rowId);
        assert(buttonResp.columnId == buttonColumn);
    }

    struct Category {
        string name;
    }

    Category[] listCategories()
    {
        string url = "/categories";
        return get!(Category[])(url);
    }

    @("coda.listCategories")
    unittest {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto resp = coda.listCategories();
        assert(resp.length > 0);
    }

    void triggerAutomation(string documentId, string automationId, JSONValue req)
    {
        string url = "/docs/%s/hooks/automation/%s".format(documentId, automationId);
        post!JSONValue(url, req, false);
    }

    @("coda.triggerAutomation")
    unittest {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto tables = coda.listTables("dEJJPwdxcw");
        auto automationId = "grid-auto-ZUjL3lcLeA";
        auto req = JSONValue(
            [
                "message": JSONValue("Automation Test")
            ]);
        coda.triggerAutomation("dEJJPwdxcw", automationId, req);
    }

    static foreach (method; [HTTP.Method.get, HTTP.Method.post, HTTP.Method.del, HTTP.Method.patch, HTTP.Method.put])
    {
        mixin(q{
            Response %s(Response)(string endpoint, JSONValue req = JSONValue(null),
                bool retry = true, int maxRetries = 10)
            {
                int count = 1;
                if (retry) {
                    foreach (i; 0 .. maxRetries) {
                        if (count > 1) {
                            // writeln("Retrying " ~ endpoint);
                        }
                        try {
                            return httpRequest!(method, Response)(endpoint, req);
                        }
                        catch (HTTPStatusException e) {
                            count++;
                            Thread.sleep(2.seconds);
                        }
                    }
                }
                return httpRequest!(method, Response)(endpoint, req);
            }
        }.format(method));

    }

    Response httpRequest(HTTP.Method method, Response)(string endpoint,
        JSONValue req = JSONValue(null))
    {
        JSONValue resp = httpRequest!(method)(endpoint, req);

        static if (isArray!Response)
            if ("items" in resp)
                return resp["items"].fromJSON!Response;
            else
                return resp.fromJSON!Response;
        else static if (is(Response == JSONValue))
                return resp;
            else
                return resp.fromJSON!Response;
    }

    JSONValue httpRequest(HTTP.Method method)(
        string endpoint,
        JSONValue req = JSONValue(null))
    {
        auto http = HTTP();
        http.addRequestHeader("Content-Type", "application/json");
        http.addRequestHeader("Authorization", "Bearer " ~ this.apiToken);

        static if (method == HTTP.Method.get)
        {
            auto resp = httpGet(baseEndpoint ~ endpoint, http);
            return parseJSON(resp);
        }
        else static if (method == HTTP.Method.post)
        {
            auto reqBody = req.toString(JSONOptions.doNotEscapeSlashes);
            reqBody = (reqBody == "null") ? "" : reqBody;
            auto resp = httpPost(baseEndpoint ~ endpoint, reqBody, http);
            return parseJSON(resp);
        }
        else static if (method == HTTP.Method.put)
        {
            auto reqBody = req.toString(JSONOptions.doNotEscapeSlashes);
            reqBody = (reqBody == "null") ? "" : reqBody;
            auto resp = httpPut(baseEndpoint ~ endpoint, reqBody, http);
            return parseJSON(resp);
        }
        else static if (method == HTTP.Method.del)
        {
            auto reqBody = req.toString(JSONOptions.doNotEscapeSlashes);
            reqBody = (reqBody == "null") ? "" : reqBody;
            httpDelete(baseEndpoint ~ endpoint, http);
            return parseJSON("{}");
        }
        else static if (method == HTTP.Method.patch)
        {
            auto reqBody = req.toString(JSONOptions.doNotEscapeSlashes);
            reqBody = (reqBody == "null") ? "" : reqBody;
            httpPatch(baseEndpoint ~ endpoint, reqBody, http);
            return parseJSON("{}");
        }
        else
            static assert(0, "Please implement " ~ method);
    }
}
