module mcl.commands.host_info;

import std.system;

import std.stdio : writeln;
import std.conv : to;
import std.string : strip, indexOf, isNumeric, toUpper, toLower, capitalize;
import std.array : split, join, array, replace;
import std.algorithm : map, filter, startsWith, joiner, any, sum, find, canFind;
import std.file : exists, write, read, readText, readLink, dirEntries, SpanMode;
import std.path : baseName, buildNormalizedPath;
import std.json;
import std.process : ProcessPipes, environment;
import std.bitmanip : peek;
import std.format : format;
import std.system : nativeEndian = endian;

import argparse : Command, Description, NamedArgument, Placeholder, EnvFallback, SubCommand, Default, matchCmd;

import mcl.utils.json : toJSON, fromJSON;
import mcl.utils.process : execute, isRoot;
import mcl.utils.number : humanReadableSize, roundToPowerOf2;
import mcl.utils.array : uniqIfSame;
import mcl.utils.nix : Literal;
import mcl.utils.coda : CodaApiClient, RowValues, CodaCell;
import mcl.commands.match_invoices : MatchInvoicesArgs, matchInvoices;

version (linux)
{
    string[string] cpuinfo;
    string[string] meminfo;
}

string[string] getProcInfo(string fileOrData, bool file = true)
{
    string[string] r;
    foreach (line; file ? fileOrData.readText().split(
            "\n").map!(strip).array
        : fileOrData.split("\n").map!(strip).array)
    {
        if (line.indexOf(":") == -1 || line.strip == "edid-decode (hex):")
        {
            continue;
        }
        auto parts = line.split(":");
        if (parts.length >= 2 && parts[0].strip != "")
        {
            r[parts[0].strip] = parts[1].strip;
        }
    }
    return r;
}

@(Command("host-info", "host_info")
    .Description("Get information about the host machine"))
struct HostInfoArgs
{
    SubCommand!(
        PartsArgs,
        MatchInvoicesArgs,
        Default!ShowArgs
    ) cmd;
}

@(Command("show")
    .Description("Show full host information (default)"))
struct ShowArgs
{
    @(NamedArgument(["coda-api-token"])
        .Placeholder("token")
        .EnvFallback("CODA_API_TOKEN"))
    string codaApiToken;

    @(NamedArgument(["upload-to-coda"])
        .Description("Upload the host info to Coda"))
    bool uploadToCoda = false;
}

@(Command("parts")
    .Description("List purchasable hardware components for invoice matching"))
struct PartsArgs
{
    @(NamedArgument(["input", "i"])
        .Placeholder("FILE")
        .Description("Process existing host-info JSON file instead of current machine"))
    string inputFile;
}

export int host_info(HostInfoArgs args)
{
    return args.cmd.matchCmd!(
        (ShowArgs a) => showHostInfo(a),
        (PartsArgs a) => showParts(a),
        (MatchInvoicesArgs a) => matchInvoices(a)
    );
}

int showHostInfo(ShowArgs args)
{
    const hostInfo = gatherHostInfo();

    hostInfo
        .toJSON(true)
        .toPrettyString(JSONOptions.doNotEscapeSlashes)
        .writeln();

    if (args.uploadToCoda)
    {
        if (!args.codaApiToken)
        {
            writeln("No Coda API token specified.");
            return 1;
        }

        writeln("Uploading results to Coda");
        auto coda = CodaApiClient(args.codaApiToken);
        coda.uploadHostInfo(hostInfo);
    }

    return 0;
}

// =============================================================================
// Purchasable Parts - Data Structures
// =============================================================================

struct HostParts
{
    string hostname;
    Part[] parts;
}

// Matches invoice CSV format: name, mark, model, sn
struct Part
{
    string name;  // Category: CPU, MB, RAM, SSD, GPU
    string mark;  // Manufacturer/brand
    string model; // Product model
    string sn;    // Serial number
}

// =============================================================================
// Purchasable Parts - Implementation
// =============================================================================

int showParts(PartsArgs args)
{
    Info hostInfo;

    if (args.inputFile)
    {
        if (!exists(args.inputFile))
        {
            writeln("Error: File not found: ", args.inputFile);
            return 1;
        }
        auto jsonText = readText(args.inputFile);
        auto json = parseJSON(jsonText);
        hostInfo = json.fromJSON!Info;
    }
    else
    {
        hostInfo = gatherHostInfo();
    }

    extractParts(hostInfo)
        .toJSON(true)
        .toPrettyString(JSONOptions.doNotEscapeSlashes)
        .writeln();

    return 0;
}

HostParts extractParts(const(Info) info)
{
    auto hw = info.hardwareInfo;
    Part[] parts;

    // CPU
    parts ~= Part(
        name: "CPU",
        mark: hw.processorInfo.vendor,
        model: hw.processorInfo.model,
        sn: "",
    );

    // Motherboard
    parts ~= Part(
        name: "MB",
        mark: hw.motherboardInfo.vendor,
        model: hw.motherboardInfo.model,
        sn: hw.motherboardInfo.serial.cleanValue,
    );

    // RAM - use individual modules if available, otherwise fall back to aggregate
    if (hw.memoryInfo.modules.length > 0)
    {
        foreach (mod; hw.memoryInfo.modules)
        {
            parts ~= Part(
                name: "RAM",
                mark: mod.vendor,
                model: mod.partNumber,
                sn: mod.serial,
            );
        }
    }
    else
    {
        // No detailed info available - add aggregate entry for review
        // Round up to nearest power of 2 since /proc/meminfo reports usable, not installed RAM
        parts ~= Part(
            name: "RAM",
            mark: "NEEDS REVIEW",
            model: roundToPowerOf2(hw.memoryInfo.totalGiB).to!string ~ " GB",
            sn: "",
        );
    }

    // Storage devices
    foreach (dev; hw.storageInfo.devices)
    {
        parts ~= Part(
            name: dev.type == "disk" ? "SSD" : dev.type.toUpper,
            mark: dev.vendor.cleanValue,
            model: dev.model,
            sn: dev.serial,
        );
    }

    // GPUs (discrete only)
    foreach (gpu; hw.graphicsProcessors)
    {
        if (gpu.isDiscrete)
        {
            parts ~= Part(
                name: "GPU",
                mark: gpu.vendor,
                model: gpu.model,
                sn: "",
            );
        }
    }

    // Periphery devices (keyboards, mice, webcams)
    // Deduplicate by vendor+product to consolidate multiple HID interfaces
    // from the same physical device (e.g., USB receiver as keyboard + mouse + consumer control)
    bool[string] seenPeripherals;
    foreach (peripheral; hw.peripheryInfo.devices)
    {
        // Create a key from vendor+product to identify the physical device
        auto key = peripheral.vendor ~ "|" ~ peripheral.product;

        // Skip if we've already seen this device (same vendor+product)
        if (key in seenPeripherals && peripheral.vendor.length > 0 && peripheral.vendor != "0000")
            continue;

        // Skip generic system HID devices
        auto nameLower = peripheral.name.toLower;
        if (nameLower.canFind("consumer control") ||
            nameLower.canFind("system control") ||
            peripheral.name == "Intel HID events")
            continue;

        // Convert USB vendor ID to brand name if not already resolved
        // (handles saved JSON files that have raw vendor IDs)
        auto vendor = usbVendorName(peripheral.vendor);

        seenPeripherals[key] = true;
        parts ~= Part(
            name: peripheral.type.capitalize,
            mark: vendor,
            model: peripheral.name,
            sn: peripheral.serial,
        );
    }

    return HostParts(
        hostname: info.softwareInfo.hostname,
        parts: parts,
    );
}

// Clean placeholder values that aren't useful for matching
string cleanValue(string s)
{
    if (s == "ROOT PERMISSIONS REQUIRED" || s == "Unknown Vendor" ||
        s == "Unknown" || s == "Not Specified" || s == "Missing Serial Number")
        return "";
    return s.strip;
}

bool isDiscrete(const(GraphicsProcessorInfo) gpu)
{
    return gpu.vendor != "" && gpu.model != "" &&
        gpu.vram != "" && gpu.vram != "Unified Memory" && gpu.vram != "Unknown";
}

Info gatherHostInfo()
{
    version (linux)
    {
        cpuinfo = getProcInfo("/proc/cpuinfo");
        meminfo = getProcInfo("/proc/meminfo");
    }

    Info info;

    version (linux)
    {
        if (exists("/etc/hostid"))
            info.softwareInfo.hostid = (cast(ubyte[])read("/etc/hostid"))
                .peek!(int, nativeEndian)
                .format!"%08x";
        if (exists("/etc/hostname"))
            info.softwareInfo.hostname = readText("/etc/hostname").strip();
    }
    version (OSX)
    {
        info.softwareInfo.hostid = execute("sysctl -n kern.uuid", false);
        info.softwareInfo.hostname = execute("hostname", false);
    }
    info.softwareInfo.operatingSystemInfo = getOperatingSystemInfo();
    info.softwareInfo.opensshInfo = getOpenSSHInfo();
    info.softwareInfo.machineConfigInfo = getMachineConfigInfo();

    info.hardwareInfo.processorInfo = getProcessorInfo();
    info.hardwareInfo.motherboardInfo = getMotherboardInfo();
    info.hardwareInfo.memoryInfo = getMemoryInfo();
    info.hardwareInfo.storageInfo = getStorageInfo();
    info.hardwareInfo.displayInfo = getDisplayInfo();
    info.hardwareInfo.graphicsProcessors = getGraphicsProcessors();
    info.hardwareInfo.peripheryInfo = getPeripheryInfo();

    return info;
}

void uploadHostInfo(CodaApiClient coda, const(Info) info)
{
    auto docId = "0rz18jyJ1M";
    auto hostTableId = "grid-b3MAjem325";
    auto cpuTableId = "grid-mCI3x3nEIE";
    auto memoryTableId = "grid-o7o2PeB4rz";
    auto motherboardTableId = "grid-270PlzmA8K";
    auto gpuTableId = "grid-ho6EPztvni";
    auto storageTableId = "grid-JvXFbttMNz";
    auto osTableId = "grid-ora7n98-ls";

    auto hostValues = RowValues([
        CodaCell("Host Name", info.softwareInfo.hostname),
        CodaCell("Host ID", info.softwareInfo.hostid),
        CodaCell("OpenSSH Public Keys", info.softwareInfo.opensshInfo.publicKeys.to!string),
        CodaCell("JSON", info.toJSON(true).toPrettyString(JSONOptions.doNotEscapeSlashes))
    ]);

    coda.upsertRow(docId, hostTableId, hostValues);

    auto cpuValues = RowValues([
        CodaCell("Host Name", info.softwareInfo.hostname),
        CodaCell("Vendor", info.hardwareInfo.processorInfo.vendor),
        CodaCell("Model", info.hardwareInfo.processorInfo.model),
        CodaCell("Architecture", info.hardwareInfo.processorInfo.architectureInfo.architecture),
        CodaCell("Flags", info.hardwareInfo.processorInfo.architectureInfo.flags),
    ]);
    coda.upsertRow(docId, cpuTableId, cpuValues);

    auto mem = info.hardwareInfo.memoryInfo;
    auto memoryValues = RowValues([
        CodaCell("Host Name", info.softwareInfo.hostname),
        CodaCell("Vendor", mem.modules.map!(m => m.vendor).array.uniqIfSame.join("/")),
        CodaCell("Part Number", mem.modules.map!(m => m.partNumber).array.uniqIfSame.join("/")),
        CodaCell("Serial", mem.modules.map!(m => m.serial).array.uniqIfSame.join("/")),
        CodaCell("Generation", mem.type),
        CodaCell("Slots", mem.slots == 0 ? "Soldered" : mem.count.to!string ~ "/" ~ mem.slots.to!string),
        CodaCell("Total", mem.totalGiB.to!string ~ " GiB"),
        CodaCell("Speed", mem.modules.map!(m => m.speed).array.uniqIfSame.join("/")),
    ]);
    coda.upsertRow(docId, memoryTableId, memoryValues);

    auto motherboardValues = RowValues([
        CodaCell("Host Name", info.softwareInfo.hostname),
        CodaCell("Vendor", info.hardwareInfo.motherboardInfo.vendor),
        CodaCell("Model", info.hardwareInfo.motherboardInfo.model),
        CodaCell("Revision", info.hardwareInfo.motherboardInfo.version_),
        CodaCell("Serial", info.hardwareInfo.motherboardInfo.serial),
        CodaCell("BIOS Vendor", info.hardwareInfo.motherboardInfo.biosInfo.vendor),
        CodaCell("BIOS Version", info.hardwareInfo.motherboardInfo.biosInfo.version_),
        CodaCell("BIOS Release", info.hardwareInfo.motherboardInfo.biosInfo.release),
        CodaCell("BIOS Date", info.hardwareInfo.motherboardInfo.biosInfo.date)
    ]);
    coda.upsertRow(docId, motherboardTableId, motherboardValues);

    foreach (gpu; info.hardwareInfo.graphicsProcessors)
    {
        auto gpuValues = RowValues([
            CodaCell("Host Name", info.softwareInfo.hostname),
            CodaCell("Vendor", gpu.vendor),
            CodaCell("Model", gpu.model),
            CodaCell("VRam", gpu.vram)
        ]);
        coda.upsertRow(docId, gpuTableId, gpuValues);
    }

    auto osValues = RowValues([
        CodaCell("Host Name", info.softwareInfo.hostname),
        CodaCell("Distribution", info.softwareInfo.operatingSystemInfo.distribution),
        CodaCell("Distribution Version", info.softwareInfo.operatingSystemInfo.distributionVersion),
        CodaCell("Kernel", info.softwareInfo.operatingSystemInfo.kernel),
        CodaCell("Kernel Version", info.softwareInfo.operatingSystemInfo.kernelVersion)
    ]);
    coda.upsertRow(docId, osTableId, osValues);

    auto storageValues = RowValues([
        CodaCell("Host Name", info.softwareInfo.hostname),
        CodaCell("Count", info.hardwareInfo.storageInfo.devices.length.to!string),
        CodaCell("Total", info.hardwareInfo.storageInfo.total),
        CodaCell("JSON", info.hardwareInfo.storageInfo.toJSON(true)
                .toPrettyString(JSONOptions.doNotEscapeSlashes))
    ]);
    coda.upsertRow(docId, storageTableId, storageValues);

}

struct Info
{
    SoftwareInfo softwareInfo;
    HardwareInfo hardwareInfo;
}

struct SoftwareInfo
{
    string hostname;
    string hostid;
    OperatingSystemInfo operatingSystemInfo;
    OpenSSHInfo opensshInfo;
    MachineConfigInfo machineConfigInfo;
}

struct HardwareInfo
{
    ProcessorInfo processorInfo;
    MotherboardInfo motherboardInfo;
    MemoryInfo memoryInfo;
    StorageInfo storageInfo;
    DisplayInfo displayInfo;
    GraphicsProcessorInfo[] graphicsProcessors;
    PeripheryInfo peripheryInfo;
}

struct ArchitectureInfo
{
    string architecture;
    string opMode;
    string byteOrder;
    string addressSizes;
    string flags;
}

ArchitectureInfo getArchitectureInfo()
{
    ArchitectureInfo r;
    r.architecture = instructionSetArchitecture.to!string;
    r.byteOrder = nativeEndian.to!string;
    r.opMode = getOpMode();

    version (linux)
    {
        r.addressSizes = cpuinfo.get("address sizes", "");
        r.flags = cpuinfo.get("flags", "").split(" ").map!(a => a.strip).join(", ");
    }
    version (OSX)
    {
        // macOS doesn't expose address sizes, use architecture-based defaults
        r.addressSizes = instructionSetArchitecture == ISA.x86_64 ? "48 bits virtual, 46 bits physical" : "48 bits virtual, 52 bits physical";
        // Get CPU features from sysctl hw.optional on macOS
        auto sysctlOutput = execute("sysctl -a", false).split("\n")
            .filter!(a => a.startsWith("hw.optional."))
            .filter!(a => a.indexOf(": 1") != -1)
            .map!(a => a.split(":")[0].replace("hw.optional.", "").replace("arm.FEAT_", "").replace(".", "_"))
            .join(", ");
        r.flags = sysctlOutput;
    }

    return r;
}

string getOpMode()
{
    int[] opMode = [];
    switch (instructionSetArchitecture)
    {
    case ISA.avr:
        opMode = [8];
        break;
    case ISA.msp430:
        opMode = [16];
        break;
    case ISA.x86_64:
    case ISA.aarch64:
    case ISA.ppc64:
    case ISA.mips64:
    case ISA.nvptx64:
    case ISA.riscv64:
    case ISA.sparc64:
    case ISA.hppa64:
        opMode = [32, 64];
        break;
    case ISA.x86:
    case ISA.arm:
    case ISA.ppc:
    case ISA.mips32:
    case ISA.nvptx:
    case ISA.riscv32:
    case ISA.sparc:
    case ISA.s390:
    case ISA.hppa:
    case ISA.sh:
    case ISA.webAssembly:
        opMode = [32];
        break;
    case ISA.ia64:
    case ISA.alpha:
        opMode = [64];
        break;
    case ISA.systemZ:
        opMode = [24, 31, 32, 64];
        break;
    case ISA.epiphany:
    default:
        throw new Exception(
            "Unsupported architecture" ~ instructionSetArchitecture.to!string);
    }
    return opMode.map!(to!string).join("-bit, ") ~ "-bit";
}

struct ProcessorInfo
{
    ArchitectureInfo architectureInfo;
    string model;
    string vendor;
    size_t cpus;
    size_t[] cores;
    size_t[] threads;
    string voltage;
    size_t[] frequency;
    size_t[] maxFrequency;
}

ProcessorInfo getProcessorInfo()
{
    ProcessorInfo r;
    version (OSX)
    {
        auto hwInfo = execute!JSONValue("system_profiler SPHardwareDataType -json", false);
        auto hw = hwInfo["SPHardwareDataType"].array[0];
        r.vendor = "Apple";
        r.model = hw["chip_type"].str;
        // number_processors format: "proc 14:10:4" meaning 14 total, 10 perf, 4 efficiency
        auto numProcs = hw["number_processors"].str;
        if (numProcs.startsWith("proc "))
        {
            auto parts = numProcs[5 .. $].split(":");
            r.cpus = 1; // Apple Silicon is single-chip
            r.cores = [parts[0].to!size_t];
            r.threads = [parts[0].to!size_t]; // Apple Silicon doesn't have SMT
        }
        r.architectureInfo = getArchitectureInfo();
    }
    else version (linux)
    {
        // Get CPU info from /proc/cpuinfo
        r.vendor = cpuinfo.get("vendor_id", "").cpuVendorName;
        r.model = cpuinfo.get("model name", "");
        r.cores = [cpuinfo.get("cpu cores", "1").to!size_t];
        r.threads = [cpuinfo.get("siblings", r.cores[0].to!string).to!size_t];
        r.cpus = 1; // Default to 1 physical CPU
        r.architectureInfo = getArchitectureInfo();

        if (isRoot)
        {
            try
            {
                auto dmi = execute("dmidecode -t 4", false).split("\n");
                auto voltages = dmi.getFromDmi("Voltage:").map!(a => a.split(" ")[0]).array.uniqIfSame;
                if (voltages.length > 0)
                    r.voltage = voltages[0];
                auto freqs = dmi.getFromDmi("Current Speed:")
                    .map!(a => a.split(" ")[0].to!size_t).array.uniqIfSame;
                if (freqs.length > 0)
                    r.frequency = freqs;
                auto maxFreqs = dmi.getFromDmi("Max Speed:")
                    .map!(a => a.split(" ")[0].to!size_t).array.uniqIfSame;
                if (maxFreqs.length > 0)
                    r.maxFrequency = maxFreqs;
                auto cpuCount = dmi.getFromDmi("Processor Information").length;
                if (cpuCount > 0)
                    r.cpus = cpuCount;
                auto coreCount = dmi.getFromDmi("Core Count").map!(a => a.to!size_t).array.uniqIfSame;
                if (coreCount.length > 0)
                    r.cores = coreCount;
                auto threadCount = dmi.getFromDmi("Thread Count").map!(a => a.to!size_t).array.uniqIfSame;
                if (threadCount.length > 0)
                    r.threads = threadCount;
            }
            catch (Exception e)
            {
                // dmidecode may fail in containers or without /dev/mem access
            }
        }
    }

    return r;
}

struct MotherboardInfo
{
    string vendor;
    string model;
    string version_;
    string serial = "ROOT PERMISSIONS REQUIRED";
    BiosInfo biosInfo;
}

struct BiosInfo
{
    string date;
    string version_;
    string release;
    string vendor;
}

string safeReadText(string path, string defaultValue = "")
{
    try
    {
        if (exists(path))
            return readText(path).strip;
    }
    catch (Exception e)
    {
        // Permission denied or other read errors
    }
    return defaultValue;
}

MotherboardInfo getMotherboardInfo()
{
    MotherboardInfo r;

    version (OSX)
    {
        auto hwInfo = execute!JSONValue("system_profiler SPHardwareDataType -json", false);
        auto hw = hwInfo["SPHardwareDataType"].array[0];
        r.vendor = "Apple";
        r.model = hw["machine_model"].str;
        r.version_ = hw["machine_name"].str;
        r.serial = hw["serial_number"].str;
        r.biosInfo = getBiosInfo();
    }
    else
    {
        r.vendor = safeReadText("/sys/devices/virtual/dmi/id/board_vendor");
        r.model = safeReadText("/sys/devices/virtual/dmi/id/board_name");
        r.version_ = safeReadText("/sys/devices/virtual/dmi/id/board_version");
        if (isRoot)
        {
            r.serial = safeReadText("/sys/devices/virtual/dmi/id/board_serial", "ROOT PERMISSIONS REQUIRED");
        }
        r.biosInfo = getBiosInfo();
    }

    return r;
}

BiosInfo getBiosInfo()
{
    BiosInfo r;
    version (OSX)
    {
        auto hwInfo = execute!JSONValue("system_profiler SPHardwareDataType -json", false);
        auto hw = hwInfo["SPHardwareDataType"].array[0];
        r.vendor = "Apple";
        r.version_ = hw["boot_rom_version"].str;
        r.release = hw["os_loader_version"].str;
        r.date = ""; // Not available on macOS
    }
    else
    {
        r.date = safeReadText("/sys/devices/virtual/dmi/id/bios_date");
        r.version_ = safeReadText("/sys/devices/virtual/dmi/id/bios_version");
        r.release = safeReadText("/sys/devices/virtual/dmi/id/bios_release");
        r.vendor = safeReadText("/sys/devices/virtual/dmi/id/bios_vendor");
    }

    return r;
}

struct OperatingSystemInfo
{
    string kernel;
    string kernelVersion;
    string distribution;
    string distributionVersion;
}

OperatingSystemInfo getOperatingSystemInfo()
{
    OperatingSystemInfo r;

    r.kernel = getKernel();
    r.kernelVersion = getKernelVersion();
    r.distribution = getDistribution();
    r.distributionVersion = getDistributionVersion();

    return r;
}

string getKernel()
{
    version (linux)
        return readText("/proc/sys/kernel/ostype").strip;
    else version (OSX)
        return "Darwin";
    else
        return "Unknown";
}

string getKernelVersion()
{
    version (linux)
        return readText("/proc/sys/kernel/osrelease").strip;
    else version (OSX)
        return execute("uname -r", false);
    else
        return "Unknown";
}

// Parse /etc/os-release or similar KEY=VALUE files
string getOsReleaseValue(string filePath, string key)
{
    import std.algorithm : findSplitAfter;
    import std.range : front, empty;
    import std.string : lineSplitter;

    if (!exists(filePath))
        return "";

    auto result = readText(filePath)
        .lineSplitter
        .map!strip
        .filter!(line => line.startsWith(key ~ "="))
        .map!(line => line.findSplitAfter("=")[1].strip("\""));

    return result.empty ? "" : result.front;
}

string getDistribution()
{
    version (OSX)
    {
        return execute("sw_vers -productName", false);
    }
    else
    {
        // Try /etc/os-release first (standard on modern Linux)
        if (exists("/etc/os-release"))
        {
            auto name = getOsReleaseValue("/etc/os-release", "NAME");
            if (name != "")
                return name;
        }
        // Fallback to /etc/lsb-release
        if (exists("/etc/lsb-release"))
        {
            auto name = getOsReleaseValue("/etc/lsb-release", "DISTRIB_ID");
            if (name != "")
                return name;
        }
        // Default fallback
        return "GNU/Linux";
    }
}

string getDistributionVersion()
{
    version (OSX)
    {
        return execute("sw_vers -productVersion", false) ~ " (" ~ execute(
            "sw_vers -buildVersion", false) ~ ")";
    }
    else
    {
        // Try /etc/os-release first
        if (exists("/etc/os-release"))
        {
            auto ver = getOsReleaseValue("/etc/os-release", "VERSION");
            if (ver != "")
                return ver;
        }
        // Fallback to /etc/lsb-release
        if (exists("/etc/lsb-release"))
        {
            auto ver = getOsReleaseValue("/etc/lsb-release", "DISTRIB_RELEASE");
            if (ver != "")
                return ver;
        }
        // Fallback to kernel version
        return getKernelVersion();
    }
}

struct MemoryModule
{
    string vendor;
    string partNumber;
    string serial;
    string size;
    string speed;
    string dataWidth;
    string totalWidth;
    string errorCorrectionType;
}

struct MemoryInfo
{
    ushort totalGiB;
    ushort count;
    ushort slots;
    bool ecc;
    string type;
    MemoryModule[] modules;
}

string[] getFromDmi(string[] dmi, string key)
{
    return dmi.filter!(a => a.strip.startsWith(key))
        .map!(x => x.indexOf(":") != -1 ? x.split(":")[1].strip : x)
        .filter!(a => a != "Unknown" && a != "No Module Installed" && a != "Not Provided" && a != "None")
        .array;
}

MemoryInfo getMemoryInfo()
{
    MemoryInfo r;
    version (OSX)
    {
        auto memInfo = execute!JSONValue("system_profiler SPMemoryDataType -json", false);
        auto mem = memInfo["SPMemoryDataType"].array[0];
        auto memTotal = execute("sysctl -n hw.memsize", false).to!size_t;
        r.totalGiB = (memTotal / (1024 * 1024 * 1024)).to!ushort;
        r.count = 1;
        r.slots = 0;
        r.ecc = false;
        r.type = mem["dimm_type"].str;
        r.modules ~= MemoryModule(
            vendor: mem["dimm_manufacturer"].str,
            size: memTotal.humanReadableSize,
            speed: "Unified Memory",
        );
    }
    else
    {
        auto memTotal = meminfo.get("MemTotal", "0 kB").split(" ")[0].to!ulong * 1024;
        // /proc/meminfo reports usable RAM, round up to installed RAM
        r.totalGiB = roundToPowerOf2((memTotal / (1024 * 1024 * 1024)).to!int).to!ushort;

        // Check ECC via EDAC (doesn't require root)
        r.ecc = exists("/sys/devices/system/edac/mc/mc0");

        if (isRoot)
        {
            auto dmiOutput = execute("dmidecode -t memory", false);
            auto dmiResult = parseDmiMemoryModules(dmiOutput);
            r.modules = dmiResult.modules;
            r.type = dmiResult.type;
            r.slots = dmiOutput.split("\n")
                .filter!(a => a.indexOf("DMI type 17") != -1)
                .array.length.to!ushort;
            r.count = r.modules.length.to!ushort;
            r.totalGiB = r.modules
                .map!(m => m.size.split(" ")[0])
                .filter!isNumeric
                .map!(to!int)
                .sum.to!ushort;
        }
    }
    return r;
}

struct DmiMemoryResult
{
    MemoryModule[] modules;
    string type;
}

DmiMemoryResult parseDmiMemoryModules(string dmiOutput)
{
    MemoryModule[] modules;
    MemoryModule current;
    string currentType;
    string resultType;
    bool inDevice = false;

    foreach (line; dmiOutput.split("\n"))
    {
        auto stripped = line.strip;

        if (stripped.startsWith("Memory Device"))
        {
            if (inDevice && current.size != "" && current.size != "No Module Installed")
            {
                modules ~= current;
                if (resultType == "")
                    resultType = currentType;
                else
                    assert(resultType == currentType, "Memory modules have different types: " ~ resultType ~ " vs " ~ currentType);
            }
            current = MemoryModule.init;
            currentType = "";
            inDevice = true;
            continue;
        }

        if (!inDevice || stripped.indexOf(":") == -1)
            continue;

        auto parts = stripped.split(":");
        if (parts.length < 2)
            continue;

        auto key = parts[0].strip;
        auto value = parts[1].strip;
        if (value == "Unknown" || value == "Not Specified" || value == "None")
            value = "";

        switch (key)
        {
            case "Size": current.size = value; break;
            case "Type": currentType = value; break;
            case "Speed": current.speed = value; break;
            case "Manufacturer": current.vendor = value; break;
            case "Part Number": current.partNumber = value; break;
            case "Serial Number": current.serial = value; break;
            case "Data Width": current.dataWidth = value; break;
            case "Total Width": current.totalWidth = value; break;
            case "Error Correction Type": current.errorCorrectionType = value; break;
            default: break;
        }
    }

    if (inDevice && current.size != "" && current.size != "No Module Installed")
    {
        modules ~= current;
        if (resultType == "")
            resultType = currentType;
        else
            assert(resultType == currentType, "Memory modules have different types: " ~ resultType ~ " vs " ~ currentType);
    }

    return DmiMemoryResult(modules, resultType);
}

struct Partition
{
    string dev;
    string size;
    string type;
    string mount;
    string fslabel;
    string partlabel;
    string id;
}

struct Device
{
    string dev;
    string uuid;
    string type;
    string size;
    string model;
    string serial;
    string vendor;
    string state;
    string partitionTableType;
    string partitionTableUUID;
    Partition[] partitions;

}

struct StorageInfo
{
    string total;
    Device[] devices;
}

StorageInfo getStorageInfo()
{
    StorageInfo r;
    real total = 0;

    version (OSX)
    {
        auto nvmeInfo = execute!JSONValue("system_profiler SPNVMeDataType -json", false);
        foreach (JSONValue controller; nvmeInfo["SPNVMeDataType"].array)
        {
            if ("_items" !in controller)
                continue;
            foreach (JSONValue dev; controller["_items"].array)
            {
                Device d;
                d.dev = dev["bsd_name"].str;
                d.model = dev["device_model"].str;
                d.serial = dev["device_serial"].str;
                d.vendor = "Apple";
                d.type = "nvme";
                d.state = dev["smart_status"].str;
                d.partitionTableType = dev["partition_map_type"].str.replace("_partition_map_type", "");
                d.uuid = "";

                auto sizeBytes = dev["size_in_bytes"].integer;
                total += sizeBytes;
                d.size = sizeBytes.humanReadableSize;

                if ("volumes" in dev)
                {
                    foreach (JSONValue vol; dev["volumes"].array)
                    {
                        Partition p;
                        p.dev = vol["bsd_name"].str;
                        p.fslabel = vol["_name"].str;
                        p.partlabel = vol["_name"].str;
                        p.size = vol["size_in_bytes"].integer.humanReadableSize;
                        p.type = vol["iocontent"].str;
                        p.mount = "";
                        p.id = "";
                        d.partitions ~= p;
                    }
                }

                r.devices ~= d;
            }
        }
    }
    else
    {
        auto lsblk = execute!JSONValue(
            "lsblk --nodeps -o KNAME,ID,TYPE,SIZE,MODEL,SERIAL,VENDOR,STATE,PTTYPE,PTUUID -J", false);
        foreach (JSONValue dev; lsblk["blockdevices"].array)
        {
            if (dev["id"].isNull)
            {
                continue;
            }
            Device d;
            d.dev = dev["kname"].isNull ? "" : dev["kname"].str;
            d.uuid = dev["id"].isNull ? "" : dev["id"].str;
            d.type = dev["type"].isNull ? "" : dev["type"].str;
            d.size = dev["size"].isNull ? "" : dev["size"].str;
            d.model = dev["model"].isNull ? "Unknown Model" : dev["model"].str;
            d.serial = dev["serial"].isNull ? "Missing Serial Number" : dev["serial"].str;
            d.vendor = dev["vendor"].isNull ? "Unknown Vendor" : dev["vendor"].str;
            d.state = dev["state"].isNull ? "" : dev["state"].str;
            d.partitionTableType = dev["pttype"].isNull ? "" : dev["pttype"].str;
            d.partitionTableUUID = dev["ptuuid"].isNull ? "" : dev["ptuuid"].str;

            switch (d.size[$ - 1])
            {
            case 'B':
                total += d.size[0 .. $ - 1].to!real;
                break;
            case 'K':
                total += d.size[0 .. $ - 1].to!real * 1024;
                break;
            case 'M':
                total += d.size[0 .. $ - 1].to!real * 1024 * 1024;
                break;
            case 'G':
                total += d.size[0 .. $ - 1].to!real * 1024 * 1024 * 1024;
                break;
            case 'T':
                total += d.size[0 .. $ - 1].to!real * 1024 * 1024 * 1024 * 1024;
                break;
            default:
                assert(0, "Unknown size unit" ~ d.size[$ - 1]);
            }

            auto partData = execute!JSONValue("lsblk -o KNAME,SIZE,PARTFLAGS,PARTLABEL,PARTN,PARTTYPE,PARTTYPENAME,PARTUUID,MOUNTPOINT,FSTYPE,LABEL -J /dev/" ~ d
                    .dev, false)["blockdevices"].array;
            foreach (JSONValue part; partData.array)
            {
                if (part["partuuid"].isNull)
                {
                    continue;
                }
                Partition p;
                p.dev = part["kname"].isNull ? "" : part["kname"].str;
                p.fslabel = part["label"].isNull ? "" : part["label"].str;
                p.partlabel = part["partlabel"].isNull ? "" : part["partlabel"].str;
                p.size = part["size"].isNull ? "" : part["size"].str;
                p.type = part["fstype"].isNull ? "" : part["fstype"].str;
                p.mount = part["mountpoint"].isNull ? "Not Mounted" : part["mountpoint"].str;
                p.id = part["partuuid"].isNull ? "" : part["partuuid"].str;
                d.partitions ~= p;
            }

            r.devices ~= d;
        }
    }
    r.total = total.humanReadableSize;

    return r;
}

struct Display
{
    string name;
    string vendor;
    string model;
    string serial;
    string resolution;
    string[] modes;
    string refreshRate;
    string size;
    bool connected;
    bool primary;
    string manufactureDate;
}

struct DisplayInfo
{
    Display[] displays;
    size_t count;
}

DisplayInfo getDisplayInfo()
{
    DisplayInfo r;
    version (OSX)
    {
        try
        {
            auto displayData = execute!JSONValue("system_profiler SPDisplaysDataType -json", false);
            foreach (JSONValue gpu; displayData["SPDisplaysDataType"].array)
            {
                if ("spdisplays_ndrvs" !in gpu)
                    continue;
                foreach (JSONValue disp; gpu["spdisplays_ndrvs"].array)
                {
                    Display d;
                    d.name = disp["_name"].str;
                    d.vendor = ("_spdisplays_display-vendor-id" in disp) ? disp["_spdisplays_display-vendor-id"].str : "Apple";
                    d.model = d.name;
                    d.serial = ("_spdisplays_display-serial-number" in disp) ? disp["_spdisplays_display-serial-number"].str : "";
                    d.resolution = ("_spdisplays_resolution" in disp) ? disp["_spdisplays_resolution"].str : "";
                    d.connected = ("spdisplays_online" in disp) && disp["spdisplays_online"].str == "spdisplays_yes";
                    d.primary = ("spdisplays_main" in disp) && disp["spdisplays_main"].str == "spdisplays_yes";
                    if ("_spdisplays_pixels" in disp)
                    {
                        d.modes ~= disp["_spdisplays_pixels"].str;
                    }
                    // Extract refresh rate from resolution string (e.g., "1728 x 1117 @ 120.00Hz")
                    if (d.resolution.indexOf("@") != -1)
                    {
                        auto parts = d.resolution.split("@");
                        if (parts.length > 1)
                            d.refreshRate = parts[1].strip;
                    }
                    r.displays ~= d;
                    r.count++;
                }
            }
        }
        catch (Exception e)
        {
            return r;
        }
    }
    else
    {
        if ("DISPLAY" !in environment)
            return r;
        try
        {
            auto xrandr = execute!JSONValue("jc xrandr --properties", false)["screens"].array;
            foreach (JSONValue screen; xrandr)
            {
                foreach (JSONValue device; screen["devices"].array)
                {
                    Display d;

                    d.name = device["device_name"].str;
                    d.connected = device["is_connected"].boolean;
                    d.primary = device["is_primary"].boolean;
                    d.resolution = device["resolution_width"].integer.to!string ~ "x" ~ device["resolution_height"]
                        .integer.to!string;
                    foreach (JSONValue mode; device["modes"].array)
                    {
                        foreach (JSONValue freq; mode["frequencies"].array)
                        {
                            d.modes ~= mode["resolution_width"].integer.to!string ~ "x" ~ mode["resolution_height"].integer
                                .to!string ~ "@" ~ freq["frequency"].floating.to!string ~ "Hz";
                            if (freq["is_current"].boolean)
                            {
                                d.refreshRate = freq["frequency"].floating.to!string ~ "Hz";
                            }
                        }
                    }
                    if ("/sys/class/rm/card0-" ~ d.name.replace("HDMI-", "HDMI-A-") ~ "/edid".exists)
                    {
                        auto edidTmp = execute("edid-decode /sys/class/drm/card0-" ~ d.name.replace("HDMI-", "HDMI-A-") ~ "/edid", false);
                        auto edidData = getProcInfo(edidTmp, false);
                        d.vendor = ("Manufacturer" in edidData) ? edidData["Manufacturer"] : "Unknown";
                        d.model = ("Model" in edidData) ? edidData["Model"] : "Unknown";
                        d.serial = ("Serial Number" in edidData) ? edidData["Serial Number"] : "Unknown";
                        d.manufactureDate = ("Made in" in edidData) ? edidData["Made in"] : "Unknown";
                        d.size = ("Maximum image size" in edidData) ? edidData["Maximum image size"]
                            : "Unknown";
                    }

                    r.displays ~= d;
                    r.count++;
                }
            }
        }
        catch (Exception e)
        {
            return r;
        }
    }
    return r;
}

struct GraphicsProcessorInfo
{
    string vendor;
    string model;
    string coreProfile;
    string vram;
}

string pciVendorName(string vendorId)
{
    switch (vendorId)
    {
        case "0x10de": return "NVIDIA";
        case "0x1002": return "AMD";
        case "0x8086": return "Intel";
        default: return vendorId;
    }
}

string cpuVendorName(string vendorId)
{
    switch (vendorId)
    {
        case "AuthenticAMD": return "AMD";
        case "GenuineIntel": return "Intel";
        default: return vendorId;
    }
}

string usbVendorName(string vendorId)
{
    switch (vendorId)
    {
        case "046d": return "Logitech";
        case "045e": return "Microsoft";
        case "04f2": return "Chicony";
        case "0bda": return "Realtek";
        case "1bcf": return "Sunplus";
        case "05ac": return "Apple";
        case "1e4e": return "Cubeternet";
        case "0c45": return "Microdia";
        case "1532": return "Razer";
        case "1b1c": return "Corsair";
        case "2516": return "Cooler Master";
        case "258a": return "HORI";
        case "0951": return "Kingston";
        case "1038": return "SteelSeries";
        case "04d9": return "Holtek";
        case "413c": return "Dell";
        case "17ef": return "Lenovo";
        case "03f0": return "HP";
        default: return vendorId;
    }
}

string pciDeviceName(string vendorId, string deviceId)
{
    // Common GPU device IDs - full PCI ID database would be too large
    // NVIDIA GPUs get their names from /proc/driver/nvidia/gpus/*/information
    if (vendorId == "0x8086") // Intel
    {
        switch (deviceId)
        {
            // Alder Lake (12th Gen)
            case "0x4680": return "UHD Graphics 770";
            case "0x4682": return "UHD Graphics 730";
            case "0x4688": return "UHD Graphics";
            case "0x468a": return "UHD Graphics";
            // Raptor Lake (13th/14th Gen)
            case "0xa780": return "UHD Graphics 770";
            case "0xa788": return "UHD Graphics";
            // Tiger Lake
            case "0x9a49": return "Iris Xe Graphics";
            case "0x9a40": return "Iris Xe Graphics";
            // Ice Lake
            case "0x8a56": return "Iris Plus Graphics";
            case "0x8a52": return "Iris Plus Graphics";
            default: break;
        }
    }
    else if (vendorId == "0x1002") // AMD
    {
        switch (deviceId)
        {
            // RDNA 3
            case "0x744c": return "Radeon RX 7900 XTX";
            case "0x7448": return "Radeon RX 7900 XT";
            // RDNA 2
            case "0x73bf": return "Radeon RX 6900 XT";
            case "0x73af": return "Radeon RX 6800 XT";
            case "0x73df": return "Radeon RX 6700 XT";
            // APUs
            case "0x1638": return "Radeon Graphics (Renoir)";
            case "0x164c": return "Radeon Graphics (Rembrandt)";
            case "0x15e7": return "Radeon Graphics (Phoenix)";
            default: break;
        }
    }

    // Fallback to vendor:device ID
    return vendorId ~ ":" ~ deviceId;
}

// Dynamic library loading for GPU detection
version (linux)
{
    import core.sys.posix.dlfcn : dlopen, dlsym, dlclose, RTLD_LAZY;

    // OpenCL types and constants
    alias cl_int = int;
    alias cl_uint = uint;
    alias cl_ulong = ulong;
    alias cl_platform_id = void*;
    alias cl_device_id = void*;
    alias cl_device_info = uint;
    alias cl_platform_info = uint;

    enum : cl_int { CL_SUCCESS = 0 }
    enum : cl_device_info {
        CL_DEVICE_NAME = 0x102B,
        CL_DEVICE_VENDOR = 0x102C,
        CL_DEVICE_GLOBAL_MEM_SIZE = 0x101F,
        CL_DEVICE_TYPE = 0x1000,
    }
    enum : cl_ulong { CL_DEVICE_TYPE_GPU = 1 << 2 }

    // OpenCL function signatures
    alias clGetPlatformIDs_t = extern(C) cl_int function(cl_uint, cl_platform_id*, cl_uint*);
    alias clGetDeviceIDs_t = extern(C) cl_int function(cl_platform_id, cl_ulong, cl_uint, cl_device_id*, cl_uint*);
    alias clGetDeviceInfo_t = extern(C) cl_int function(cl_device_id, cl_device_info, size_t, void*, size_t*);

    // NVML types and constants
    alias nvmlReturn_t = int;
    alias nvmlDevice_t = void*;
    struct nvmlMemory_t { ulong total; ulong free; ulong used; }

    enum : nvmlReturn_t { NVML_SUCCESS = 0 }

    // NVML function signatures
    alias nvmlInit_t = extern(C) nvmlReturn_t function();
    alias nvmlShutdown_t = extern(C) nvmlReturn_t function();
    alias nvmlDeviceGetCount_t = extern(C) nvmlReturn_t function(uint*);
    alias nvmlDeviceGetHandleByIndex_t = extern(C) nvmlReturn_t function(uint, nvmlDevice_t*);
    alias nvmlDeviceGetName_t = extern(C) nvmlReturn_t function(nvmlDevice_t, char*, uint);
    alias nvmlDeviceGetMemoryInfo_t = extern(C) nvmlReturn_t function(nvmlDevice_t, nvmlMemory_t*);

    // Try to load a library from multiple paths
    void* tryLoadLibrary(string[] names)
    {
        import std.string : toStringz;
        foreach (name; names)
        {
            auto lib = dlopen(name.toStringz, RTLD_LAZY);
            if (lib !is null)
                return lib;
        }
        return null;
    }

    // Try to get GPU info via OpenCL (works for NVIDIA, AMD, Intel)
    GraphicsProcessorInfo[] getGpuInfoViaOpenCL()
    {
        GraphicsProcessorInfo[] results;

        // Try different library names and paths (including NixOS locations)
        void* lib = tryLoadLibrary([
            "libOpenCL.so.1",
            "libOpenCL.so",
            "/run/opengl-driver/lib/libOpenCL.so.1",
            "/run/opengl-driver/lib/libOpenCL.so",
        ]);
        if (lib is null)
            return results;

        scope(exit) dlclose(lib);

        // Load functions
        auto clGetPlatformIDs = cast(clGetPlatformIDs_t) dlsym(lib, "clGetPlatformIDs");
        auto clGetDeviceIDs = cast(clGetDeviceIDs_t) dlsym(lib, "clGetDeviceIDs");
        auto clGetDeviceInfo = cast(clGetDeviceInfo_t) dlsym(lib, "clGetDeviceInfo");

        if (clGetPlatformIDs is null || clGetDeviceIDs is null || clGetDeviceInfo is null)
            return results;

        // Get platforms
        cl_uint numPlatforms;
        if (clGetPlatformIDs(0, null, &numPlatforms) != CL_SUCCESS || numPlatforms == 0)
            return results;

        auto platforms = new cl_platform_id[numPlatforms];
        if (clGetPlatformIDs(numPlatforms, platforms.ptr, null) != CL_SUCCESS)
            return results;

        // Collect all GPU devices from all platforms
        foreach (platform; platforms)
        {
            cl_uint numDevices;
            if (clGetDeviceIDs(platform, CL_DEVICE_TYPE_GPU, 0, null, &numDevices) != CL_SUCCESS || numDevices == 0)
                continue;

            auto devices = new cl_device_id[numDevices];
            if (clGetDeviceIDs(platform, CL_DEVICE_TYPE_GPU, numDevices, devices.ptr, null) != CL_SUCCESS)
                continue;

            // Get info for all GPUs on this platform
            foreach (device; devices)
            {
                GraphicsProcessorInfo gpu;
                char[256] nameBuf, vendorBuf;
                cl_ulong memSize;
                size_t retSize;

                if (clGetDeviceInfo(device, CL_DEVICE_NAME, nameBuf.length, nameBuf.ptr, &retSize) == CL_SUCCESS)
                    gpu.model = cast(string) nameBuf[0 .. retSize - 1].idup;

                if (clGetDeviceInfo(device, CL_DEVICE_VENDOR, vendorBuf.length, vendorBuf.ptr, &retSize) == CL_SUCCESS)
                    gpu.vendor = cast(string) vendorBuf[0 .. retSize - 1].idup;

                if (clGetDeviceInfo(device, CL_DEVICE_GLOBAL_MEM_SIZE, cl_ulong.sizeof, &memSize, null) == CL_SUCCESS)
                    gpu.vram = humanReadableSize(memSize);

                if (gpu.model != "")
                    results ~= gpu;
            }
        }

        return results;
    }

    // Try to get GPU info via NVML (NVIDIA-specific, more detailed)
    GraphicsProcessorInfo[] getGpuInfoViaNVML()
    {
        GraphicsProcessorInfo[] results;

        // Try different library names and paths (including NixOS locations)
        void* lib = tryLoadLibrary([
            "libnvidia-ml.so.1",
            "libnvidia-ml.so",
            "/run/opengl-driver/lib/libnvidia-ml.so.1",
            "/run/opengl-driver/lib/libnvidia-ml.so",
        ]);
        if (lib is null)
            return results;

        scope(exit) dlclose(lib);

        // Load functions
        auto nvmlInit = cast(nvmlInit_t) dlsym(lib, "nvmlInit_v2");
        if (nvmlInit is null)
            nvmlInit = cast(nvmlInit_t) dlsym(lib, "nvmlInit");
        auto nvmlShutdown = cast(nvmlShutdown_t) dlsym(lib, "nvmlShutdown");
        auto nvmlDeviceGetCount = cast(nvmlDeviceGetCount_t) dlsym(lib, "nvmlDeviceGetCount_v2");
        if (nvmlDeviceGetCount is null)
            nvmlDeviceGetCount = cast(nvmlDeviceGetCount_t) dlsym(lib, "nvmlDeviceGetCount");
        auto nvmlDeviceGetHandleByIndex = cast(nvmlDeviceGetHandleByIndex_t) dlsym(lib, "nvmlDeviceGetHandleByIndex_v2");
        if (nvmlDeviceGetHandleByIndex is null)
            nvmlDeviceGetHandleByIndex = cast(nvmlDeviceGetHandleByIndex_t) dlsym(lib, "nvmlDeviceGetHandleByIndex");
        auto nvmlDeviceGetName = cast(nvmlDeviceGetName_t) dlsym(lib, "nvmlDeviceGetName");
        auto nvmlDeviceGetMemoryInfo = cast(nvmlDeviceGetMemoryInfo_t) dlsym(lib, "nvmlDeviceGetMemoryInfo");

        if (nvmlInit is null || nvmlShutdown is null || nvmlDeviceGetCount is null ||
            nvmlDeviceGetHandleByIndex is null || nvmlDeviceGetName is null || nvmlDeviceGetMemoryInfo is null)
            return results;

        // Initialize NVML
        if (nvmlInit() != NVML_SUCCESS)
            return results;

        scope(exit) nvmlShutdown();

        // Get device count
        uint deviceCount;
        if (nvmlDeviceGetCount(&deviceCount) != NVML_SUCCESS || deviceCount == 0)
            return results;

        // Get info for all devices
        foreach (i; 0 .. deviceCount)
        {
            nvmlDevice_t device;
            if (nvmlDeviceGetHandleByIndex(i, &device) != NVML_SUCCESS)
                continue;

            GraphicsProcessorInfo gpu;
            gpu.vendor = "NVIDIA";

            char[256] nameBuf;
            if (nvmlDeviceGetName(device, nameBuf.ptr, cast(uint) nameBuf.length) == NVML_SUCCESS)
            {
                import core.stdc.string : strlen;
                gpu.model = cast(string) nameBuf[0 .. strlen(nameBuf.ptr)].idup;
                // Remove "NVIDIA " prefix if present
                if (gpu.model.startsWith("NVIDIA "))
                    gpu.model = gpu.model[7 .. $];
            }

            nvmlMemory_t memory;
            if (nvmlDeviceGetMemoryInfo(device, &memory) == NVML_SUCCESS)
                gpu.vram = humanReadableSize(memory.total);

            results ~= gpu;
        }

        return results;
    }
}

GraphicsProcessorInfo[] getGraphicsProcessors()
{
    GraphicsProcessorInfo[] results;

    version (OSX)
    {
        try
        {
            auto displayData = execute!JSONValue("system_profiler SPDisplaysDataType -json", false);
            foreach (JSONValue gpu; displayData["SPDisplaysDataType"].array)
            {
                GraphicsProcessorInfo r;
                r.vendor = ("spdisplays_vendor" in gpu) ? gpu["spdisplays_vendor"].str.replace("sppci_vendor_", "") : "Apple";
                r.model = ("sppci_model" in gpu) ? gpu["sppci_model"].str : gpu["_name"].str;
                r.coreProfile = ("spdisplays_mtlgpufamilysupport" in gpu) ? gpu["spdisplays_mtlgpufamilysupport"].str.replace("spdisplays_", "") : "";
                r.vram = ("sppci_cores" in gpu) ? gpu["sppci_cores"].str ~ " GPU cores" : "Unified Memory";
                results ~= r;
            }
        }
        catch (Exception e)
        {
            return results;
        }
    }
    else
    {
        // Try NVML first (NVIDIA-specific, provides accurate VRAM)
        results = getGpuInfoViaNVML();

        // Try OpenCL to find additional GPUs (cross-vendor: NVIDIA, AMD, Intel)
        auto openclGpus = getGpuInfoViaOpenCL();

        // Merge OpenCL results, avoiding duplicates by model name
        foreach (oclGpu; openclGpus)
        {
            bool isDuplicate = false;
            foreach (existing; results)
            {
                if (existing.model == oclGpu.model)
                {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate)
                results ~= oclGpu;
        }

        // Always check sysfs/procfs to find GPUs not detected via NVML/OpenCL (e.g., Intel iGPUs)
        try
        {
            // Also check PCI sysfs for any GPU (works for AMD, Intel, etc.)
            foreach (pciDevice; dirEntries("/sys/bus/pci/devices", SpanMode.shallow))
            {
                auto classPath = pciDevice.name ~ "/class";
                if (!exists(classPath))
                    continue;

                auto deviceClass = readText(classPath).strip;
                // Class 0x03xxxx = Display controller
                if (!deviceClass.startsWith("0x03"))
                    continue;

                auto vendorId = readText(pciDevice.name ~ "/vendor").strip;
                auto deviceId = readText(pciDevice.name ~ "/device").strip;

                // Try to get model name from NVIDIA proc if available
                string model;
                auto pciSlot = baseName(pciDevice.name);
                auto nvidiaProcPath = "/proc/driver/nvidia/gpus/" ~ pciSlot ~ "/information";
                if (exists(nvidiaProcPath))
                {
                    auto gpuInfo = getProcInfo(nvidiaProcPath);
                    model = gpuInfo.get("Model", "").replace("NVIDIA ", "");
                }
                else
                {
                    model = pciDeviceName(vendorId, deviceId);
                }

                // Check if already found via NVML/OpenCL
                bool isDuplicate = false;
                foreach (existing; results)
                {
                    // Match by model name or by vendor:device ID pattern
                    if (existing.model == model ||
                        (model.startsWith("0x") && existing.vendor == pciVendorName(vendorId)))
                    {
                        isDuplicate = true;
                        break;
                    }
                }
                if (!isDuplicate)
                {
                    GraphicsProcessorInfo r;
                    r.vendor = pciVendorName(vendorId);
                    r.model = model;
                    results ~= r;
                }
            }
        }
        catch (Exception e)
        {
            // Ignore sysfs errors
        }

    }

    return results;
}

struct Peripheral
{
    string type;        // "keyboard", "mouse", "webcam"
    string name;        // Device name
    string vendor;      // Vendor ID or name
    string product;     // Product ID or name
    string serial;      // Serial number/unique ID
}

struct PeripheryInfo
{
    Peripheral[] devices;
}

PeripheryInfo getPeripheryInfo()
{
    PeripheryInfo r;

    version (OSX)
    {
        // TODO: macOS peripheral detection via system_profiler SPUSBDataType
        return r;
    }
    else
    {
        // Parse /proc/bus/input/devices for keyboards and mice
        if (exists("/proc/bus/input/devices"))
        {
            try
            {
                auto content = readText("/proc/bus/input/devices");
                Peripheral current;
                bool hasHandlers = false;
                string handlers;

                foreach (line; content.split("\n"))
                {
                    if (line.length == 0)
                    {
                        // End of device block - determine type and add if relevant
                        if (current.name.length > 0 && hasHandlers)
                        {
                            // Skip system devices
                            if (!current.name.canFind("Button") &&
                                !current.name.canFind("Video Bus") &&
                                !current.name.canFind("PC Speaker") &&
                                !current.name.canFind("HDA ") &&
                                !current.name.canFind("ALSA"))
                            {
                                // Determine type from handlers
                                bool hasMouse = handlers.canFind("mouse");
                                bool hasKbd = handlers.canFind("kbd");

                                if (hasMouse && hasKbd)
                                {
                                    // Combo device - check name for hints
                                    auto nameLower = current.name.toLower;
                                    if (nameLower.canFind("mouse") ||
                                        nameLower.canFind("trackpad") ||
                                        nameLower.canFind("touchpad") ||
                                        nameLower.canFind("mx master") ||
                                        nameLower.canFind("mx anywhere") ||
                                        nameLower.canFind("trackball"))
                                        current.type = "mouse";
                                    else if (nameLower.canFind("keyboard"))
                                        current.type = "keyboard";
                                    else
                                        current.type = "keyboard";  // Default to keyboard for combo
                                }
                                else if (hasMouse)
                                    current.type = "mouse";
                                else if (hasKbd)
                                    current.type = "keyboard";

                                if (current.type.length > 0)
                                    r.devices ~= current;
                            }
                        }
                        current = Peripheral.init;
                        hasHandlers = false;
                        handlers = "";
                        continue;
                    }

                    if (line.startsWith("N: Name="))
                        current.name = line[9 .. $].strip("\"");
                    else if (line.startsWith("U: Uniq="))
                        current.serial = line[8 .. $];
                    else if (line.startsWith("I: Bus="))
                    {
                        // Parse "Bus=0003 Vendor=046d Product=c52b Version=0111"
                        foreach (part; line[3 .. $].split(" "))
                        {
                            auto kv = part.split("=");
                            if (kv.length == 2)
                            {
                                if (kv[0] == "Vendor")
                                    current.vendor = usbVendorName(kv[1]);
                                else if (kv[0] == "Product")
                                    current.product = kv[1];
                            }
                        }
                    }
                    else if (line.startsWith("H: Handlers="))
                    {
                        handlers = line[12 .. $];
                        hasHandlers = true;
                    }
                }
            }
            catch (Exception e)
            {
                // Ignore parsing errors
            }
        }

        // Check for webcams in /sys/class/video4linux
        if (exists("/sys/class/video4linux"))
        {
            string[] seenSerials;  // Deduplicate by serial
            try
            {
                foreach (entry; dirEntries("/sys/class/video4linux", SpanMode.shallow))
                {
                    auto namePath = entry.name ~ "/name";
                    if (!exists(namePath))
                        continue;

                    auto name = readText(namePath).strip;
                    // Skip dummy/virtual devices
                    if (name.canFind("Dummy") || name.canFind("virtual"))
                        continue;

                    Peripheral cam;
                    cam.type = "webcam";
                    cam.name = name;

                    // Walk up directory tree to find USB device with idVendor
                    auto currentPath = entry.name ~ "/device";
                    for (int depth = 0; depth < 10 && exists(currentPath); depth++)
                    {
                        auto vendorPath = currentPath ~ "/idVendor";
                        if (exists(vendorPath))
                        {
                            cam.vendor = usbVendorName(safeReadText(vendorPath));
                            cam.product = safeReadText(currentPath ~ "/idProduct");
                            cam.serial = safeReadText(currentPath ~ "/serial");
                            // Use manufacturer name if available
                            auto mfg = safeReadText(currentPath ~ "/manufacturer");
                            if (mfg.length > 0)
                                cam.vendor = mfg;
                            break;
                        }
                        currentPath = currentPath ~ "/..";
                    }

                    // Deduplicate by serial (multiple v4l2 nodes for same device)
                    if (cam.serial.length > 0)
                    {
                        if (seenSerials.canFind(cam.serial))
                            continue;
                        seenSerials ~= cam.serial;
                    }

                    r.devices ~= cam;
                }
            }
            catch (Exception e)
            {
                // Ignore errors
            }
        }
    }

    return r;
}

struct OpenSSHInfo
{
    string[] publicKeys;
}

OpenSSHInfo getOpenSSHInfo()
{
    if (!exists("/etc/ssh"))
        return OpenSSHInfo.init;
    return dirEntries("/etc/ssh", "*.pub", SpanMode.shallow)
        .map!(key => key.name.readText().strip())
        .array()
        .to!OpenSSHInfo();
}

struct MachineConfigInfo
{
    string[] kernelModules;
    string[] extraModulePackages;
    string[] availableKernelModules;
    string[] imports;
    string[] literalAttrs;
    string[] blacklistedKernelModules;
    string[] videoDrivers;
}

MachineConfigInfo getMachineConfigInfo()
{
    MachineConfigInfo r;

    version (OSX)
    {
        // macOS doesn't have Linux-style kernel modules or /sys filesystem
        // Return empty config info for Darwin
        return r;
    }
    else
    {
        // PCI devices
        foreach (path; dirEntries("/sys/bus/pci/devices", SpanMode.shallow).map!(a => a.name).array)
        {
            string vendor = readText(path ~ "/vendor").strip;
            string device = readText(path ~ "/device").strip;
            string _class = readText(path ~ "/class").strip;
            string _module;
            if (exists(path ~ "/driver/module"))
            {
                _module = readLink(path ~ "/driver/module").baseName;
            }

            if (_module != "" && (
                    // Mass-storage controller.  Definitely important.
                    _class.startsWith("0x01") ||
                    //Firewire controller.  A disk might be attached.
                    _class.startsWith("0x0c00") ||
                    //USB controller.  Needed if we want to use the
                    // keyboard when things go wrong in the initrd.
                    _class.startsWith("0x0c03")))
            {
                r.availableKernelModules ~= _module;
            }

            // broadcom STA driver (wl.ko)
            // list taken from http://www.broadcom.com/docs/linux_sta/README.txt
            if (vendor.startsWith("0x14e4") &&
                [
                    "0x4311", "0x4312", "0x4313",
                    "0x4315", "0x4327", "0x4328",
                    "0x4329", "0x432a", "0x432b",
                    "0x432c", "0x432d", "0x4353",
                    "0x4357", "0x4358", "0x4359",
                    "0x4331", "0x43a0", "0x43b1"
                ].any!(a => device.startsWith(a)))
            {
                r.extraModulePackages ~= Literal(
                    "config.boot.kernelPackages.broadcom_sta");
                r.kernelModules ~= "wl";
            }

            // broadcom FullMac driver
            // list taken from
            // https://wireless.wiki.kernel.org/en/users/Drivers/brcm80211#brcmfmac
            if (vendor.startsWith("0x14e4") && [
                    "0x43a3", "0x43df", "0x43ec",
                    "0x43d3", "0x43d9", "0x43e9",
                    "0x43ba", "0x43bb", "0x43bc",
                    "0xaa52", "0x43ca", "0x43cb",
                    "0x43cc", "0x43c3", "0x43c4",
                    "0x43c5"
                ].any!(a => device.startsWith(a)))
            {
                r.imports ~= Literal(
                    "(modulesPath + \"/hardware/network/broadcom-43xx.nix\")");
            }

            // In case this is a virtio scsi device, we need to explicitly make this available.
            if (vendor.startsWith("0x1af4") && ["0x1004", "0x1048"].any!(a => device.startsWith(a)))
            {
                r.availableKernelModules ~= "virtio_scsi";
            }

            // Can't rely on $module here, since the module may not be loaded
            // due to missing firmware.  Ideally we would check modules.pcimap
            // here.
            if (vendor.startsWith("0x8086"))
            {
                if (["0x1043", "0x104f", "0x4220", "0x4221", "0x4223", "0x4224"].any!(
                        a => device.startsWith(a)))
                {
                    r.literalAttrs ~= Literal(
                        "networking.enableIntel2200BGFirmware = true;");
                }
                else if (["0x4229", "0x4230", "0x4222", "0x4227"].any!(a => device.startsWith(a)))
                {
                    r.literalAttrs ~= Literal(
                        "networking.enableIntel3945ABGFirmware = true;");
                }
            }

            // Assume that all NVIDIA cards are supported by the NVIDIA driver.
            // There may be exceptions (e.g. old cards).
            // FIXME: do we want to enable an unfree driver here?
            if (vendor.startsWith("0x10de") && _class.startsWith("0x03"))
            {
                r.videoDrivers ~= "nvidia";
                r.blacklistedKernelModules ~= "nouveau";
            }
        }

        // USB devices
        foreach (path; dirEntries("/sys/bus/usb/devices", SpanMode.shallow).map!(a => a.name).array)
        {
            if (!exists(path ~ "/bInterfaceClass"))
            {
                continue;
            }
            string _class = readText(path ~ "/bInterfaceClass").strip;
            string subClass = readText(path ~ "/bInterfaceSubClass").strip;
            string protocol = readText(path ~ "/bInterfaceProtocol").strip;

            string _module;
            if (exists(path ~ "/driver/module"))
            {
                _module = readLink(path ~ "/driver/module").baseName;
            }

            if (_module != "" &&
                // Mass-storage controller. Definitely important.
                _class.startsWith("0x08") ||
                // Keyboard. Needed if we want to use the keyboard when things go wrong in the initrd.
                (subClass.startsWith("0x03") || protocol.startsWith("0x01")))
            {
                r.availableKernelModules ~= _module;
            }
        }

        // Block and MMC devices
        foreach (path; (
                (exists("/sys/class/block") ? dirEntries("/sys/class/block", SpanMode.shallow)
                .array : []) ~
                (exists("/sys/class/mmc_host") ? dirEntries("/sys/class/mmc_host", SpanMode.shallow).array
                : []))
            .map!(a => a.name).array)
        {
            if (exists(path ~ "/device/driver/module"))
            {
                string _module = readLink(path ~ "/device/driver/module").baseName;
                r.availableKernelModules ~= _module;
            }
        }
        // Bcache
        auto bcacheDevices = dirEntries("/dev", SpanMode.shallow).map!(a => a.name)
            .array
            .filter!(a => a.startsWith("bcache"))
            .array;
        bcacheDevices = bcacheDevices.filter!(device => device.indexOf("dev/bcachefs") == -1).array;

        if (bcacheDevices.length > 0)
        {
            r.availableKernelModules ~= "bcache";
        }
        //Prevent unbootable systems if LVM snapshots are present at boot time.
        if (execute("lsblk -o TYPE", false).indexOf("lvm") != -1)
        {
            r.kernelModules ~= "dm-snapshot";
        }
        // Check if we're in a VirtualBox guest. If so, enable the guest additions.
        auto virt = execute!ProcessPipes("systemd-detect-virt", false).stdout.readln.strip;
        switch (virt)
        {
        case "oracle":
            r.literalAttrs ~= Literal("virtualisation.virtualbox.guest.enable = true;");
            break;
        case "parallels":
            r.literalAttrs ~= Literal("hardware.parallels.enable = true;");
            r.literalAttrs ~= Literal(
                "nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ \"prl-tools\" ];");
            break;
        case "qemu":
        case "kvm":
        case "bochs":
            r.imports ~= Literal("(modulesPath + \"/profiles/qemu-guest.nix\")");
            break;
        case "microsoft":
            r.literalAttrs ~= Literal("virtualization.hypervGuest.enable = true;");
            break;
        case "systemd-nspawn":
            r.literalAttrs ~= Literal("boot.isContainer;");
            break;
        default:
            break;
        }

        return r;
    }
}
