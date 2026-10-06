## shardSplit Module Overview

The **shardSplit** flake module is a flake-parts module that automatically divides build outputs across multiple "shards" for distributed CI/CD evaluation. It's designed to work with tools like `nix-eval-jobs` for parallel building.

### Module Location & Structure

The module is defined in [`modules/shard-split/default.nix`](https://github.com/metacraft-labs/devops-modules/blob/dev/modules/shard-split/default.nix) and uses the [`lib/shard-attrs.nix`](https://github.com/metacraft-labs/devops-modules/blob/dev/lib/shard-attrs.nix) helper function.

### Configuration Options

The module reads from `config.flake.mcl.shard-matrix` with three configurable inputs:

| Option                     | Type            | Default                                               | Purpose                                                                                            |
| -------------------------- | --------------- | ----------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| **shardSize**              | positive number | 1                                                     | Number of items per shard (chunk size for division)                                                |
| **systemsToBuild**         | list of strings | `["x86_64-linux", "aarch64-linux", "aarch64-darwin"]` | Systems to evaluate and shard                                                                      |
| **perSystemAttributePath** | list of strings | `["legacyPackages", "checks"]`                        | Flake attribute path to extract packages from, with `${system}` interpolated after first attribute |

### How It Works

The module performs this pipeline on the evaluated flake outputs:

```
1. For each system in systemsToBuild:
   ├─ Access flake outputs using perSystemAttributePath
   │  └─ e.g., outputs.legacyPackages.${system}.checks
   │
   2. Flatten all systems' attributes into a single namespace:
   │  └─ Each package name becomes: "${name}/${system}"
   │
   3. Split flattened list into shards using shardSize
   │  └─ Shard indices are zero-padded (e.g., "shard-00", "shard-01")
   │
   4. Generate two output structures
```

### Outputs

The module generates four read-only output attributes under `config.flake.mcl.shard-matrix.result`:

#### 1. **shards** - Cross-System Shards

```nix
{
  "shard-0" = {
    "hello-0.0.1/aarch64-darwin" = <derivation>;
    "hello-0.0.1/x86_64-linux" = <derivation>;
    "hello-0.0.2/aarch64-darwin" = <derivation>;
    # ... more packages
  };
  "shard-1" = {
    "bye-0.0.1/aarch64-darwin" = <derivation>;
    "bye-0.0.1/x86_64-linux" = <derivation>;
    # ...
  };
}
```

- **Structure**: `shards.{shardId}.{packageName}/{system}`
- **Use case**: Each shard can be built independently by nix-eval-jobs, with packages distributed across all systems in a single shard

#### 2. **shardsPerSystem** - System-Organized Shards

```nix
{
  "aarch64-darwin" = {
    "shard-0" = {
      "hello-0.0.1" = <derivation>;
      "hello-0.0.2" = <derivation>;
    };
    "shard-1" = {
      "bye-0.0.1" = <derivation>;
    };
  };
  "x86_64-linux" = {
    "shard-0" = { /* ... */ };
    "shard-1" = { /* ... */ };
  };
}
```

- **Structure**: `shardsPerSystem.{system}.{shardId}.{packageName}`
- **Use case**: When you need system-specific shard organization (build per-system shards in parallel)

#### 3. **shardCount** - Total Cross-System Shard Count

- **Type**: unsigned integer
- **Value**: Number of shards in the `shards` output
- Calculated as: `ceil(totalPackageCount / shardSize)`

#### 4. **shardCountPerSystem** - Per-System Shard Counts

- **Type**: `{system: shardCount, ...}`
- **Value**: For each system, the number of shards that system has
- Useful for job scheduling per-system

### Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  Flake Outputs (evaluated for all systems)                  │
│  outputs.legacyPackages.x86_64-linux.checks                 │
│  outputs.legacyPackages.aarch64-darwin.checks               │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
                 ┌───────────────────────┐
                 │  Extract attributes   │
                 │ per system using      │
                 │ perSystemAttributePath│
                 └───────────────────────┘
                              │
          ┌───────────────────┴───────────────────┐
          ▼                                       ▼
   ┌──────────────────┐               ┌──────────────────┐
   │  For each system │               │  For each system │
   │  gen attributes  │               │  shard using     │
   │ as "{name}/{sys}"│               │  shardAttrs()    │
   └──────────────────┘               └──────────────────┘
          │                                     │
          └───────────────┬─────────────────────┘
                          ▼
       ┌──────────────────────────────────┐
       │  shardAttrs(attrs, shardSize)    │
       │  ─────────────────────────────── │
       │  1. Sort attribute names         │
       │  2. Split into chunks            │
       │  3. Create shards with padded ID │
       │  4. Return {shard-N: {...}}      │
       └──────────────────────────────────┘
               │                    │
               ▼                    ▼
      ┌──────────────────┐  ┌────────────────────┐
      │  shards (cross-  │  │ shardsPerSystem    │
      │  system shards)  │  │ (system-grouped)   │
      │ {shard-N:        │  │ {system: {shard-N: │
      │  {pkg/sys: drv}} │  │  {pkg: drv}}}      │
      └──────────────────┘  └────────────────────┘
               │                    │
               └────────┬───────────┘
                        ▼
        ┌───────────────────────────────────┐
        │  shardCount & shardCountPerSystem │
        │  (Metadata for scheduling)        │
        └───────────────────────────────────┘
```

### Shard Splitting Algorithm

The [`shardAttrs`](https://github.com/metacraft-labs/devops-modules/blob/dev/lib/shard-attrs.nix#L1-L25) function implements the core sharding logic:

1. **Calculate shard count**: `ceil(attrCount / shardSize)`
2. **Create fixed-width shard IDs**: Pad IDs to match the width of the highest shard number (e.g., "00", "01", "02" for 100+ shards)
3. **Distribute attributes**: Slice attribute names into consecutive chunks of `shardSize`
4. **Map to derivations**: For each chunk, create a shard object mapping original attribute names to their derivations

### Example Usage

If your flake has 25 packages and `shardSize = 10`:

- 3 shards are created: "shard-0", "shard-1", "shard-2"
- Shards contain \~10, \~10, and \~5 packages respectively
- Each shard can be evaluated independently by nix-eval-jobs in parallel

The module throws an error if `systemsToBuild` specifies systems that don't exist in the flake outputs at the configured `perSystemAttributePath`.
