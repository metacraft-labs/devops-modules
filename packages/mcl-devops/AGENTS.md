# MCL Agent Guidelines

This document provides instructions for AI agents working on the `mcl-devops` (Metacraft Labs CLI) codebase.

## Project Overview

`mcl-devops` is a Swiss-knife CLI tool for managing NixOS deployments, written in D. It provides commands for:

- Host information gathering (`host-info`)
- Remote host management (`hosts`)
- CI evaluation and matrix generation (`ci`, `ci-matrix`, `print-table`, `merge-ci-matrices`, `shard-matrix`)
- Machine configuration (`machine`, `config`)
- Deployment (`deploy-spec`, `deploy-plan`, `deploy-apply`, `deploy-agent`, `deploy-reconcile`, `deploy-ssh`, `deploy-status`)
- Deployment cache backends (`cache`)
- Age-encrypted secret management (`secret`)

A module under `src/mcl/commands/` becomes a top-level command only when it is
listed in `commandModulesToExport` in `src/mcl/commands/package.d` — that map is
the authoritative command registry, and `mcl-devops --help` prints exactly what it
contains. Everything else in `commands/` is reachable only as a subcommand (for
example `match_invoices.d`, wired in under `host-info`), or not at all.

## Code Style Philosophy

Prefer **functional style** with UFCS (Uniform Function Call Syntax) using `std.algorithm` and `std.range`. Use the ternary operator and direct returns rather than mutating variables with if/else.

```d
// Preferred: functional pipeline with UFCS
auto result = items
    .filter!(a => a.isValid)
    .map!(a => a.name)
    .array;

// Preferred: ternary operator
auto value = condition ? "yes" : "no";

// Avoid: mutation with if/else
string value;
if (condition)
    value = "yes";
else
    value = "no";
```

## Building

```bash
# Build the project
dub --root ./packages/mcl-devops/ build

# The binary is output to:
./packages/mcl-devops/build/mcl-devops
```

> **Note**: In the Nix devshell, `packages/mcl-devops/build` is automatically added to `PATH` (see `shells/default.nix`). After running `dub build`, you can invoke `mcl-devops` directly without the full path.

## Testing

### Run All Tests

```bash
# Exclude coda tests (requires auth token)
dub --root ./packages/mcl-devops/ test -- -e coda
```

### Run Specific Tests

Use `-i` (include) to filter tests by regex pattern:

```bash
# Run tests matching "loadHostsFrom"
dub --root ./packages/mcl-devops/ test -- -i "loadHostsFrom"

# Run tests matching "parseDmi"
dub --root ./packages/mcl-devops/ test -- -i "parseDmi"
```

### Test Options

```
-i, --include    Run tests matching regex
-e, --exclude    Skip tests matching regex
-v, --verbose    Show full stack traces and durations
-t, --threads    Number of worker threads (0 = auto)
--no-colours     Disable colored output
```

### Manual Testing

Test CLI commands directly after building:

```bash
# Show host information
mcl-devops host-info

# Show purchasable parts (for invoice matching)
mcl-devops host-info parts

# Scan network for hosts with SSH
mcl-devops hosts scan --network 192.168.1

# Get help for any command
mcl-devops host-info --help
```

## Code Style

### Imports

Group imports in this order:

1. `std.*` modules (one per line, with specific symbols)
2. External dependencies (`argparse`, etc.)
3. Internal modules (`mcl.*`)

```d
import std.stdio : writeln;
import std.conv : to;
import std.string : strip, indexOf;
import std.array : split, join, array;
import std.algorithm : map, filter, startsWith;

import argparse : Command, Description, NamedArgument;

import mcl.utils.json : toJSON, fromJSON;
```

### Command Structure

Commands use the `argparse` library with `@Command` attributes:

```d
@(Command("my-command")
    .Description("Brief description of the command"))
struct MyCommandArgs
{
    @(NamedArgument(["input", "i"])
        .Placeholder("FILE")
        .Description("Input file path"))
    string inputFile;
}

export int my_command(MyCommandArgs args)
{
    // Implementation
    return 0;
}
```

### Subcommands

Use `SubCommand!` template for commands with subcommands:

```d
@(Command("parent-command")
    .Description("Parent command"))
struct ParentArgs
{
    SubCommand!(
        SubCmd1Args,
        SubCmd2Args,
        Default!SubCmd1Args  // Default subcommand
    ) cmd;
}

export int parent_command(ParentArgs args)
{
    return args.cmd.matchCmd!(
        (SubCmd1Args a) => handleSubCmd1(a),
        (SubCmd2Args a) => handleSubCmd2(a)
    );
}
```

### Enum Aliases with `@AllowedValues`

Use `@AllowedValues` on enum members to accept alternative CLI spellings. Name enum members to match their canonical string form so `to!string` produces the right value without needing `@StringRepresentation`:

```d
import argparse : AllowedValues;

enum ConfigurationType
{
    @AllowedValues("nixos", "nixosConfigurations")
    nixosConfigurations,

    @AllowedValues("nix-darwin", "darwinConfigurations")
    darwinConfigurations,
}
```

> **Note**: Use `.Parse(lambda)` (runtime argument), **not** `.Parse!(lambda)` (template argument), when customizing parsing on a `NamedArgument`.

### Data Structures

Use named parameters for struct initialization:

```d
parts ~= Part(
    name: "CPU",
    mark: hw.processorInfo.vendor,
    model: hw.processorInfo.model,
    sn: "",
);
```

## Commit Message Convention

Follow the conventional commits format used in this repo:

```
<type>(<scope>): <description>
```

### Types

- `feat` - New feature
- `fix` - Bug fix
- `refactor` - Code refactoring
- `chore` - Maintenance tasks
- `build` - Build system changes
- `ci` - CI/CD changes

### Scopes

- `mcl.commands.<command>` - For command-specific changes
- `mcl.utils.<module>` - For utility module changes
- `flake.nix` - For Nix flake changes

### Examples

```
feat(mcl.commands.host-info): Add periphery section for input devices
fix(mcl.utils.json): Handle Nullable types in serialization
refactor(mcl.commands.host-info): Rewrite getMemoryInfo function
chore(flake.lock): Update all Flake inputs
```

## File Structure

```
packages/mcl-devops/
├── src/mcl/
│   ├── commands/       # CLI command implementations
│   │   ├── host_info.d # host-info command
│   │   ├── hosts.d     # hosts command
│   │   ├── machine.d   # machine command
│   │   └── ...
│   ├── utils/          # Utility modules
│   │   ├── json.d      # JSON serialization
│   │   ├── process.d   # Process execution
│   │   └── ...
│   └── package.d       # Module exports
├── build/              # Build output directory
├── dub.sdl             # D package configuration
└── AGENTS.md           # This file
```

## Common Patterns

### Type-safe Parsing / Serde

Use `fromJSON!T` for deserialization and `toJSON` for serialization:

```d
// Deserialize JSON to struct
auto json = parseJSON(jsonText);
auto data = json.fromJSON!MyStruct;

// Serialize struct to JSON with pretty printing
data
    .toJSON(true)
    .toPrettyString(JSONOptions.doNotEscapeSlashes)
    .writeln();
```

Use `std.csv.csvReader!T` for type-safe CSV parsing:

```d
import std.csv : csvReader, Malformed;

struct Record
{
    string name;
    string value;
    int count;
}

auto content = readText("data.csv");
auto records = csvReader!(Record, Malformed.ignore)(content, null);
foreach (record; records)
{
    // record is a Record struct
}
```

## Debugging Tips

1. **Build with debug info**: The default build includes debug symbols
2. **Use verbose test output**: `dub test -- -v` shows full stack traces
3. **Test single functions**: Use `-i "functionName"` to isolate tests
4. **Check JSON output**: Pipe commands through `jq` for readable output:
   ```bash
   mcl-devops host-info | jq .
   ```

## Dependencies

The full set declared in `dub.sdl`:

- `argparse` - CLI argument parsing (`@Command`, `SubCommand!`, `CLI!`)
- `silly` - Test runner backing `dub test`
- `sparkles:core-cli` - Shared CLI scaffolding (`initLogger` in `src/main.d`)
- `sparkles:test-utils` - Test fixtures (e.g. the `TmpFS` temp-directory helper)
- `mir-cpuid` - CPU identification (pulls in `mir-core` transitively)

All dependencies are managed via `dub.sdl` and Nix flake.

### Updating `dub-lock.json`

After changing dependencies in `dub.sdl`, regenerate the Nix lock file used by `buildDubPackage`:

```bash
cd packages/mcl-devops
dub upgrade          # update dub.selections.json
dub-to-nix > dub-lock.json  # regenerate dub-lock.json from selections
```

`dub-to-nix` is available in the Nix devshell (see `shells/default.nix`).
