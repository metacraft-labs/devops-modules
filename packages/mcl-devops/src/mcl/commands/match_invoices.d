module mcl.commands.match_invoices;

import std.stdio : writeln, File;
import std.conv : to;
import std.string : strip, toUpper, toLower, startsWith, endsWith;
import std.array : array, replace;
import std.algorithm : map, filter, canFind, min, joiner;
import std.file : exists, dirEntries, SpanMode, readText;
import std.path : baseName;
import std.json : JSONOptions, parseJSON;
import std.typecons : Nullable, nullable;
import std.csv : csvReader, Malformed;
import std.exception : ifThrown;

import argparse : Command, Description, NamedArgument, Placeholder, Required;

import mcl.utils.json : toJSON, fromJSON;
import mcl.commands.host_info : Part, HostParts;

// =============================================================================
// Command Args
// =============================================================================

@(Command("match-invoices")
    .Description("Match hardware parts to purchase invoices"))
struct MatchInvoicesArgs
{
    @(NamedArgument(["invoices"])
        .Placeholder("DIR")
        .Description("Directory containing invoice CSV files")
        .Required())
    string invoicesDir;

    @(NamedArgument(["host-info-dir"])
        .Placeholder("DIR")
        .Description("Directory containing host-info JSON files")
        .Required())
    string hostInfoDir;
}

// =============================================================================
// Invoice Data Structures
// =============================================================================

// CSV record structure matching the invoice file columns
struct CsvRecord
{
    string purchasedbid;
    string clientdbid;
    string date;
    string name;
    string mark;
    string model;
    string sn;
    string price;
    string vat;
    string lastchange;
    string modul;
    string manifacturer;
    string productid;
    string descr;
}

struct Invoice
{
    string file;           // Source CSV filename (added after parsing)
    string purchasedbid;   // Invoice ID
    string date;           // Purchase date
    string name;           // Category (CPU, MB, RAM, SSD, etc.)
    string mark;           // Manufacturer/brand
    string model;          // Product model
    string sn;             // Serial number
    string price;          // Price
    string descr;          // Description

    this(string file, CsvRecord r)
    {
        this.file = file;
        this.purchasedbid = r.purchasedbid;
        this.date = r.date;
        this.name = r.name;
        this.mark = r.mark;
        this.model = r.model;
        this.sn = r.sn;
        this.price = r.price;
        this.descr = r.descr;
    }
}

struct PartMatch
{
    Part part;
    Nullable!InvoiceInfo invoice;
    string confidence;     // "high", "medium", "low", or ""
    string matchType;      // "serial", "model", "model+brand", or ""
}

struct InvoiceInfo
{
    string file;
    string purchasedbid;
    string date;
    string price;
    string descr;
}

struct MatchResult
{
    string hostname;
    PartMatch[] matches;
    Invoice[] unmatchedInvoices;
}

// =============================================================================
// Command Handler
// =============================================================================

int matchInvoices(MatchInvoicesArgs args)
{
    auto invoices = loadInvoices(args.invoicesDir);
    auto allHostParts = loadHostParts(args.hostInfoDir);

    allHostParts
        .map!(parts => matchPartsToInvoices(parts, invoices))
        .array
        .toJSON(true)
        .toPrettyString(JSONOptions.doNotEscapeSlashes)
        .writeln();

    return 0;
}

HostParts[] loadHostParts(string hostInfoDir)
{
    return exists(hostInfoDir)
        ? dirEntries(hostInfoDir, "*.json", SpanMode.shallow)
            .map!(entry => readText(entry.name).parseJSON.fromJSON!HostParts.ifThrown(HostParts.init))
            .filter!(p => p.hostname.length > 0)
            .array
        : [];
}

// =============================================================================
// Invoice Loading
// =============================================================================

Invoice[] loadInvoices(string invoicesDir)
{
    return exists(invoicesDir)
        ? dirEntries(invoicesDir, "*.csv", SpanMode.shallow)
            .map!(entry => parseInvoiceCsv(entry.name))
            .joiner
            .array
        : [];
}

Invoice[] parseInvoiceCsv(string filepath)
{
    auto filename = baseName(filepath);
    return ifThrown(
        readText(filepath)
            .csvReader!(CsvRecord, Malformed.ignore)(null)
            .map!(record => Invoice(filename, record))
            .array,
        cast(Invoice[]) []
    );
}

// =============================================================================
// Serial Number Normalization
// =============================================================================

string normalizeSerial(string sn)
{
    if (sn.length == 0)
        return "";

    auto normalized = sn.toUpper.strip;

    // Remove common prefixes
    if (normalized.startsWith("JAR"))
        normalized = normalized[3 .. $];
    if (normalized.startsWith("S") && normalized.length > 10)
        normalized = normalized[1 .. $];

    // Remove common suffixes
    if (normalized.endsWith("N") && normalized.length > 10)
        normalized = normalized[0 .. $ - 1];

    return normalized;
}

// Check if two serial numbers match (handles partial matches)
bool serialsMatch(string sn1, string sn2)
{
    if (sn1.length == 0 || sn2.length == 0)
        return false;

    auto norm1 = normalizeSerial(sn1);
    auto norm2 = normalizeSerial(sn2);

    if (norm1 == norm2)
        return true;

    // Check suffix match (invoice may have truncated SN)
    auto minLen = min(norm1.length, norm2.length);
    if (minLen >= 6)
    {
        if (norm1.endsWith(norm2[$ - minLen .. $]) || norm2.endsWith(norm1[$ - minLen .. $]))
            return true;
        if (norm1.canFind(norm2) || norm2.canFind(norm1))
            return true;
    }

    return false;
}

// =============================================================================
// Brand/Model Normalization
// =============================================================================

string normalizeBrand(string brand)
{
    auto normalized = brand.toLower.strip;

    // Common brand normalizations
    normalized = normalized
        .replace("intl", "")
        .replace("international", "")
        .replace("co.", "")
        .replace("ltd.", "")
        .replace("ltd", "")
        .replace("inc.", "")
        .replace("inc", "")
        .replace("corp.", "")
        .replace("corp", "")
        .replace(",", "")
        .replace(".", "")
        .replace(" ", "");

    return normalized;
}

bool brandsMatch(string brand1, string brand2)
{
    if (brand1.length == 0 || brand2.length == 0)
        return false;

    auto norm1 = normalizeBrand(brand1);
    auto norm2 = normalizeBrand(brand2);

    return norm1 == norm2 || norm1.canFind(norm2) || norm2.canFind(norm1);
}

string normalizeModel(string model)
{
    return model.toUpper.strip
        // Remove trademark symbols
        .replace("(R)", "")
        .replace("(TM)", "")
        .replace("®", "")
        .replace("™", "")
        // Remove common prefixes that add noise
        .replace("INTEL", "")
        .replace("AMD", "")
        .replace("CORE", "")
        .replace("RYZEN", "")
        // Remove generation prefixes
        .replace("14TH GEN", "")
        .replace("13TH GEN", "")
        .replace("12TH GEN", "")
        .replace("11TH GEN", "")
        .replace("10TH GEN", "")
        // Remove separators
        .replace(" ", "")
        .replace("-", "")
        .replace("_", "");
}

// Extract key identifying tokens from a model string (e.g., "i9", "13900K")
string[] extractModelTokens(string model)
{
    import std.regex : regex, matchAll;
    import std.uni : toUpper;

    string[] tokens;
    auto normalized = model.toUpper;

    // Match CPU model identifiers like i9, i7, i5, i3
    auto cpuTierPattern = regex(`\b(I[3579])\b`);
    foreach (m; normalized.matchAll(cpuTierPattern))
        tokens ~= m[1].to!string;

    // Match CPU SKU numbers like 13900K, 7950X, 5800X3D
    auto skuPattern = regex(`\b(\d{4,5}[A-Z]*\d*[A-Z]*)\b`);
    foreach (m; normalized.matchAll(skuPattern))
        tokens ~= m[1].to!string;

    // Match GPU identifiers like RTX4090, GTX1080, RX7900
    auto gpuPattern = regex(`\b(RTX|GTX|RX|RADEON|GEFORCE)?\s*(\d{3,4})\s*(TI|XT|XTX|SUPER)?\b`);
    foreach (m; normalized.matchAll(gpuPattern))
    {
        string token = m[2].to!string;
        if (m[1].length > 0)
            token = m[1].to!string ~ token;
        if (m[3].length > 0)
            token ~= m[3].to!string;
        if (token.length > 0)
            tokens ~= token;
    }

    // Match peripheral product names (words 3+ chars, alphanumeric with optional version suffix)
    // e.g., "Ornata", "V2", "K120", "MX Master", "G502"
    auto productPattern = regex(`\b([A-Z][A-Z0-9]{2,}|V\d+)\b`);
    foreach (m; normalized.matchAll(productPattern))
    {
        auto token = m[1].to!string;
        // Skip common noise words
        if (token != "USB" && token != "RECEIVER" && token != "KEYBOARD" &&
            token != "MOUSE" && token != "GAMING" && token != "RGB")
            tokens ~= token;
    }

    return tokens;
}

bool modelsMatch(string model1, string model2)
{
    if (model1.length == 0 || model2.length == 0)
        return false;

    auto norm1 = normalizeModel(model1);
    auto norm2 = normalizeModel(model2);

    // Direct match after normalization
    if (norm1 == norm2 || norm1.canFind(norm2) || norm2.canFind(norm1))
        return true;

    // Token-based matching: check if key identifiers match
    auto tokens1 = extractModelTokens(model1);
    auto tokens2 = extractModelTokens(model2);

    if (tokens1.length > 0 && tokens2.length > 0)
    {
        // Check if all tokens from the shorter list are in the longer one
        auto shorter = tokens1.length <= tokens2.length ? tokens1 : tokens2;
        auto longer = tokens1.length > tokens2.length ? tokens1 : tokens2;

        size_t matchCount = 0;
        foreach (t; shorter)
        {
            if (longer.canFind(t))
                matchCount++;
        }

        // If at least half of the shorter tokens match, consider it a match
        if (matchCount > 0 && matchCount >= (shorter.length + 1) / 2)
            return true;
    }

    return false;
}

// =============================================================================
// Category Matching
// =============================================================================

bool categoriesMatch(string partCat, string invoiceCat)
{
    auto p = partCat.toLower;
    auto i = invoiceCat.toLower;

    if (p == i)
        return true;

    // Handle common category variations
    if (p == "cpu" && i.canFind("cpu"))
        return true;
    if (p == "mb" && (i.canFind("mb") || i.canFind("motherboard")))
        return true;
    if (p == "ram" && (i.canFind("ram") || i.canFind("memory") || i.canFind("ddr")))
        return true;
    if (p == "ssd" && (i.canFind("ssd") || i.canFind("disk") || i.canFind("drive")))
        return true;
    if (p == "gpu" && (i.canFind("gpu") || i.canFind("video") || i.canFind("graphics")))
        return true;
    if (p == "keyboard" && (i.canFind("kbd") || i.canFind("keyboard")))
        return true;
    if (p == "mouse" && (i.canFind("mouse") || i.canFind("mice")))
        return true;
    if (p == "webcam" && (i.canFind("camera") || i.canFind("webcam")))
        return true;

    return false;
}

// =============================================================================
// Matching Logic
// =============================================================================

MatchResult matchPartsToInvoices(HostParts parts, Invoice[] invoices)
{
    MatchResult result;
    result.hostname = parts.hostname;

    bool[] invoiceMatched = new bool[invoices.length];

    foreach (part; parts.parts)
    {
        PartMatch match;
        match.part = part;

        // Try serial number match first (highest confidence)
        if (part.sn.length > 0)
        {
            foreach (i, inv; invoices)
            {
                if (!invoiceMatched[i] && serialsMatch(part.sn, inv.sn))
                {
                    match.invoice = InvoiceInfo(
                        inv.file, inv.purchasedbid, inv.date, inv.price, inv.descr
                    ).nullable;
                    match.confidence = "high";
                    match.matchType = "serial";
                    invoiceMatched[i] = true;
                    break;
                }
            }
        }

        // Try model + brand match (medium confidence)
        // Skip generic receivers - they're bundled accessories without individual invoices
        auto modelLower = part.model.toLower;
        bool isGenericReceiver = modelLower.canFind("usb receiver") ||
            modelLower.canFind("unifying receiver") ||
            modelLower.canFind("nano receiver");

        if (match.invoice.isNull && part.model.length > 0 && !isGenericReceiver)
        {
            foreach (i, inv; invoices)
            {
                if (!invoiceMatched[i] &&
                    categoriesMatch(part.name, inv.name) &&
                    modelsMatch(part.model, inv.model))
                {
                    bool brandOk = part.mark.length == 0 || inv.mark.length == 0 ||
                        brandsMatch(part.mark, inv.mark);

                    if (brandOk)
                    {
                        match.invoice = InvoiceInfo(
                            inv.file, inv.purchasedbid, inv.date, inv.price, inv.descr
                        ).nullable;
                        match.confidence = brandsMatch(part.mark, inv.mark) ? "medium" : "low";
                        match.matchType = brandsMatch(part.mark, inv.mark) ? "model+brand" : "model";
                        invoiceMatched[i] = true;
                        break;
                    }
                }
            }
        }

        result.matches ~= match;
    }

    // Collect unmatched invoices (only hardware-related)
    foreach (i, inv; invoices)
    {
        if (!invoiceMatched[i] && isHardwareInvoice(inv))
        {
            result.unmatchedInvoices ~= inv;
        }
    }

    return result;
}

bool isHardwareInvoice(Invoice inv)
{
    auto name = inv.name.toLower;
    return name.canFind("cpu") || name.canFind("mb") || name.canFind("motherboard") ||
        name.canFind("ram") || name.canFind("memory") || name.canFind("ddr") ||
        name.canFind("ssd") || name.canFind("disk") || name.canFind("gpu") ||
        name.canFind("video") || name.canFind("graphics");
}
