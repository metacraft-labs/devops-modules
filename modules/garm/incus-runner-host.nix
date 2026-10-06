{ ... }:
{
  # Declarative GARM Reconcile — deliverables (2) + (3): make the incus
  # bridge + the runner image declarative, so the "run `incus admin init` once"
  # and "`incus image import` once" operator steps disappear from EXP2/EXP4.
  #
  # This is a small REUSABLE host helper the per-host garm-runner configs turn
  # on (setting their per-host subnet). It has NO opinion about GARM itself —
  # `services.garm` still owns the control plane. It only provisions the two
  # host-level prerequisites GARM's incus provider consumes:
  #
  #   (2) `virtualisation.incus.preseed` for the FULL host triple a fresh GARM
  #       host needs — the managed `incusbr0` bridge on the per-host /24
  #       (high-mem-server 10.157.159.0/24, gpu-server-001 10.158.160.0/24), a
  #       storage pool on the declared driver/`source` (`dir` by default; a
  #       `zfs` pool ADOPTS an existing dataset), and the `default` profile's
  #       root+eth0 devices.
  #       nixpkgs' incus module ships an idempotent `incus-preseed.service`
  #       (ordered After=incus.service) that applies the preseed; the preseed
  #       CREATES/UPDATES entities but never REMOVES them, so it is safe to
  #       re-apply on every switch and coexists with the host's other incus
  #       containers/networks. Replaces the manual `incus admin init` /
  #       `incus network create incusbr0 …`.
  #
  #       CAVEAT (why (2b) exists): nixpkgs' `incus-preseed.service` only runs
  #       `incus admin init --preseed` while incus is UNINITIALISED (it guards on
  #       a first-run marker) and only on an incus.service (re)start. A host whose
  #       incus daemon self-initialised EMPTY before this config landed (as
  #       gpu-server-001 did) therefore gets NOTHING from the preseed — no pool,
  #       no bridge, no profile devices. So the preseed alone cannot guarantee a
  #       converged host.
  #
  #   (2b) an IDEMPOTENT `garm-incus-storage-network.service` convergence oneshot
  #        that, on EVERY switch, create-if-missing reconciles the same triple
  #        directly via the incus CLI (storage pool, bridge network, default
  #        profile root+eth0 devices). Each step is guarded (`incus … show ||
  #        incus … create`) so it is a NO-OP on a converged host and NEVER mutates
  #        an existing pool's immutable fields. This SUPERSEDES relying on the
  #        preseed's uninitialised-only / restart-coupled semantics, so a fresh
  #        GPU host converges on first `nixos-rebuild switch` with zero hand
  #        steps. Runs only when `managePreseed` is true (the host we manage);
  #        adopted hosts (managePreseed = false) stay byte-unchanged.
  #
  #   (3) an idempotent `garm-incus-image-import.service` oneshot that imports
  #       the runner image (default alias `vmh-linux-runner`) if — and ONLY if —
  #       it is absent from the host's incus image store, from a nix-built or
  #       operator-provided tarball. Replaces the manual `incus image import` /
  #       `incus image alias create`. A re-run with the image already present is
  #       a no-op (the oneshot checks `incus image alias list` first).
  flake.modules.nixos.garm-incus-runner-host =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.garm-incus-runner-host;
      inherit (lib)
        mkEnableOption
        mkIf
        mkOption
        types
        ;
      incusPkg = config.virtualisation.incus.package;
      incusBin = "${incusPkg}/bin/incus";
    in
    {
      options.services.garm-incus-runner-host = {
        enable = mkEnableOption ''
          the declarative incus host prerequisites for GARM incus runners: the
          managed `incusbr0` bridge (via incus.preseed) and the runner-image
          import oneshot
        '';

        bridgeName = mkOption {
          type = types.str;
          default = "incusbr0";
          description = ''
            The managed incus bridge name. Must match
            `services.garm.providers.<name>.incusBridge`.
          '';
        };

        bridgeSubnet = mkOption {
          type = types.str;
          example = "10.157.159.0/24";
          description = ''
            The per-host incusbr0 subnet, `a.b.c.0/nn`. The bridge host IP (the
            `.1` gateway the per-job containers reach GARM on) is derived by
            replacing the host octet with `1`. Distinct per host so two hosts on
            a shared netbird L2 never collide (high-mem-server 10.157.159.0/24,
            gpu-server-001 10.158.160.0/24).
          '';
        };

        bridgeGateway = mkOption {
          type = types.str;
          default = "";
          example = "10.157.159.1";
          description = ''
            The bridge host IP / gateway in `a.b.c.d/nn`-less dotted form. Empty
            (default) ⇒ derived from `bridgeSubnet` by setting the host octet to
            `1`. Emitted as `ipv4.address = <gateway>/<prefix>` in the preseed.
          '';
        };

        nat = mkOption {
          type = types.bool;
          default = true;
          description = "Enable ipv4.nat on the managed bridge (container egress).";
        };

        managePreseed = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether to declare the full incus host triple (bridge network,
            storage pool, default profile devices) via
            `virtualisation.incus.preseed` AND run the idempotent
            `garm-incus-storage-network` convergence oneshot that reconciles the
            same triple on every switch (belt-and-suspenders for an incus that
            self-initialised before this config landed). Default true. Set false
            on a host whose incus is provisioned some other way / adopted (the
            image-import oneshot then still applies, but the preseed + the
            storage-network convergence oneshot are BOTH inert, so the host is
            byte-unchanged).
          '';
        };

        storagePool = {
          name = mkOption {
            type = types.str;
            default = "default";
            description = ''
              The incus storage pool the `default` profile's root disk uses.
              Declared in the preseed and reconciled by the convergence oneshot
              (create-if-missing; never mutated once present).
            '';
          };

          driver = mkOption {
            type = types.str;
            default = "dir";
            example = "zfs";
            description = ''
              The storage pool driver. `dir` (the default) needs no extra host
              setup (a plain directory pool under /var/lib/incus).

              For `zfs`, `btrfs` and `lvm` you MUST also set
              {option}`storagePool.source` (or opt in to
              {option}`storagePool.allowLoopFileBacking`) — see the hazard
              documented on `source`.
            '';
          };

          source = mkOption {
            type = types.str;
            default = "";
            example = "zroot/root/var/lib/incus-storage";
            description = ''
              The pool's `source=` config key — the EXISTING backing store the
              pool ADOPTS. For the `zfs` driver this is a dataset name
              (`<zpool>/<path>`); for `btrfs`/`lvm` a block device or existing
              subvolume/VG; for `dir` an existing directory. Empty (the
              default) leaves `source` unset.

              THIS IS NOT COSMETIC ON A LOOP-FILE-CAPABLE DRIVER. Incus'
              `FillConfig()` (internal/server/storage/drivers/driver_zfs.go,
              and the btrfs/lvm equivalents) treats "no source" as a REQUEST
              for a loop-backed pool: it rewrites `source` to
              `/var/lib/incus/disks/<pool>.img`, creates a sparse file there
              and builds the zpool/filesystem INSIDE it. No error, no warning,
              and `incus storage list` still reports `driver: zfs` — so the
              host looks converged while every per-job container rootfs lives
              in a zpool-in-a-file stacked on the host's real pool, which is
              strictly worse than the `dir` driver it replaced.

              The check that distinguishes an adopted dataset from that
              outcome is `ls -A /var/lib/incus/disks/` — it must be EMPTY. The
              module refuses to render a loop-backed pool at eval time (see
              {option}`storagePool.allowLoopFileBacking`) and re-checks the
              live host in `garm-incus-storage-network`.
            '';
          };

          extraConfig = mkOption {
            type = types.attrsOf types.str;
            default = { };
            example = {
              "zfs.pool_name" = "zroot";
            };
            description = ''
              Additional storage-pool config keys, emitted verbatim in the
              preseed's `config` block and passed as `key=value` arguments to
              `incus storage create`. `source` has its own option above
              because the module reasons about it; everything else
              (`zfs.pool_name`, `size`, `lvm.vg_name`, `ceph.cluster_name`, …)
              goes here.

              Only consulted at pool CREATION — the convergence oneshot never
              mutates an existing pool's config.
            '';
          };

          allowLoopFileBacking = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Explicit opt-in to a LOOP-FILE-BACKED storage pool, i.e. a
              `zfs`/`btrfs`/`lvm` pool declared with no
              {option}`storagePool.source`, which Incus silently builds inside
              `/var/lib/incus/disks/<pool>.img`.

              With this `false` (the default) that configuration is REJECTED at
              eval time, and `garm-incus-storage-network` additionally fails
              the host if a loop file for the declared pool is ever found on
              disk. Set it true only when a file-backed pool is what you
              actually want (a throwaway VM, a laptop, a test); it is never
              what a CI runner host wants.
            '';
          };
        };

        image = {
          enable = mkOption {
            type = types.bool;
            default = true;
            description = "Whether to run the runner-image import oneshot.";
          };

          alias = mkOption {
            type = types.str;
            default = "vmh-linux-runner";
            description = ''
              The incus image alias GARM's provider references
              (`services.garm.providers.<name>.images.<k>.sourceImage`). The
              oneshot imports the tarball under this alias iff it is absent.
            '';
          };

          source = mkOption {
            type = types.nullOr types.path;
            default = null;
            example = "/var/lib/garm/images/vmh-linux-runner.tar.gz";
            description = ''
              Path to a unified incus image tarball (`incus image export`
              format) imported under `alias` when the alias is absent. Null
              (default) ⇒ the oneshot is a NO-OP unless the image already
              exists (it never fails a host that has no source AND no image —
              it just logs that the operator must seed the image). A nix-built
              image derivation can be pointed at here.
            '';
          };
        };
      };

      config = mkIf cfg.enable (
        let
          # subnet a.b.c.0/nn -> prefix + derived gateway a.b.c.1
          parts = lib.splitString "/" cfg.bridgeSubnet;
          netAddr = builtins.elemAt parts 0;
          prefix = builtins.elemAt parts 1;
          octets = lib.splitString "." netAddr;
          derivedGateway = lib.concatStringsSep "." ((lib.sublist 0 3 octets) ++ [ "1" ]);
          gateway = if cfg.bridgeGateway != "" then cfg.bridgeGateway else derivedGateway;

          # ---- The storage pool's config block ---------------------------------
          #
          # `source` gets its own option (the module reasons about it — see the
          # loop-file hazard below); everything else is passed through verbatim.
          # One value, rendered into BOTH the preseed's `config:` mapping and the
          # `incus storage create` argument list, so the two can never disagree.
          poolConfig =
            lib.optionalAttrs (cfg.storagePool.source != "") { source = cfg.storagePool.source; }
            // cfg.storagePool.extraConfig;

          # `incus storage create <pool> <driver> key=value …`
          poolCreateArgs = lib.mapAttrsToList (k: v: "${k}=${v}") poolConfig;

          # Incus' `internalUtil.VarPath()`. The loop file a source-less
          # zfs/btrfs/lvm pool is silently built inside lands at
          # <varPath>/disks/<pool>.img (drivers/utils.go: loopFilePath).
          incusVarPath = "/var/lib/incus";
          poolLoopFile = "${incusVarPath}/disks/${cfg.storagePool.name}.img";

          # The drivers whose FillConfig() turns "no source" into a loop file
          # rather than an error. `dir` and the networked drivers (ceph*,
          # powerflex, linstor, truenas) have no such fallback, so a missing
          # `source` there is either legal or a loud Incus error.
          loopFileCapableDrivers = [
            "zfs"
            "btrfs"
            "lvm"
          ];
          driverIsLoopFileCapable = lib.elem cfg.storagePool.driver loopFileCapableDrivers;
          # The exact declaration that yields a silent loop-file pool.
          poolWouldBeLoopFileBacked = driverIsLoopFileCapable && cfg.storagePool.source == "";

          # (2b) The idempotent storage+network+profile convergence oneshot.
          # Every step is create-if-missing so it is a no-op on a converged host
          # and never mutates an existing pool's immutable fields. `</dev/null`
          # on every incus call keeps the CLI from consuming the script's stdin.
          convergeScript = pkgs.writeShellApplication {
            name = "garm-incus-storage-network";
            runtimeInputs = [
              incusPkg
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.gnused
            ];
            text = ''
              set -euo pipefail
              pool="${cfg.storagePool.name}"
              driver="${cfg.storagePool.driver}"
              declared_source="${cfg.storagePool.source}"
              loop_file="${poolLoopFile}"
              allow_loop="${lib.boolToString cfg.storagePool.allowLoopFileBacking}"
              # True only for the declaration the eval-time assertion rejects.
              refuse_sourceless="${
                lib.boolToString (poolWouldBeLoopFileBacked && !cfg.storagePool.allowLoopFileBacking)
              }"
              bridge="${cfg.bridgeName}"
              addr="${gateway}/${prefix}"
              nat="${lib.boolToString cfg.nat}"

              # The LOOP-FILE GUARD, run before and after the pool step. A
              # zfs/btrfs/lvm pool created with no `source=` is not an error in
              # Incus — FillConfig() rewrites `source` to $loop_file, builds the
              # pool inside a sparse file there, and `incus storage list` goes on
              # reporting the real driver name. Nothing else on the host ever
              # says anything is wrong. So we say it, here, and fail.
              assert_not_loop_backed() { # $1 = when (a label for the message)
                # storagePool.allowLoopFileBacking = true ⇒ a file-backed pool is
                # what this host explicitly asked for; nothing to assert.
                if [ "$allow_loop" = "true" ]; then
                  return 0
                fi
                if [ -e "$loop_file" ]; then
                  echo "garm-incus-storage-network: FATAL ($1): storage pool '$pool' is" \
                    "LOOP-FILE BACKED — '$loop_file' exists, so Incus built the pool inside" \
                    "a sparse file instead of adopting a real backing store. Every per-job" \
                    "container rootfs would live in a $driver pool stacked on a file on the" \
                    "host filesystem. Set" \
                    "services.garm-incus-runner-host.storagePool.source to the backing" \
                    "store to adopt (or .allowLoopFileBacking = true if a file-backed pool" \
                    "is genuinely wanted). Contents of ${incusVarPath}/disks:" >&2
                  ls -A "${incusVarPath}/disks" >&2 || true
                  exit 1
                fi
              }

              assert_not_loop_backed "pre-existing"

              # Storage pool (immutable-safe: only create if absent).
              if ${incusBin} storage show "$pool" </dev/null >/dev/null 2>&1; then
                echo "garm-incus-storage-network: storage pool '$pool' present — no-op"

                # A pool that is already there is never mutated (Incus cannot
                # change a pool's driver in place and has no `storage rename`),
                # but a SILENT divergence between the declaration and the live
                # pool is how this host drifts back to the defect. Say it loudly
                # and leave the cutover to the operator — a hard failure here
                # would break every deploy on a host merely awaiting a window.
                have_driver=$(${incusBin} storage show "$pool" </dev/null 2>/dev/null \
                  | sed -n 's/^driver: //p' | head -n1)
                if [ -n "$have_driver" ] && [ "$have_driver" != "$driver" ]; then
                  echo "garm-incus-storage-network: NEEDS-OPERATOR-CUTOVER: storage pool" \
                    "'$pool' is on driver '$have_driver' but this configuration declares" \
                    "'$driver'. Incus cannot change a pool's driver in place." >&2
                fi
                if [ -n "$declared_source" ]; then
                  have_source=$(${incusBin} storage get "$pool" source </dev/null 2>/dev/null || true)
                  if [ -n "$have_source" ] && [ "$have_source" != "$declared_source" ]; then
                    echo "garm-incus-storage-network: NEEDS-OPERATOR-CUTOVER: storage pool" \
                      "'$pool' has source '$have_source' but this configuration declares" \
                      "'$declared_source'." >&2
                  fi
                fi
              else
                # Inert while the eval-time assertion stands; kept so the unit
                # still refuses if this script is ever reached by another route
                # (a hand-edited unit, a stale generation left on the host).
                if [ "$refuse_sourceless" = "true" ]; then
                  echo "garm-incus-storage-network: FATAL: refusing to create a '$driver'" \
                    "pool with no source= — Incus would build it inside '$loop_file'." >&2
                  exit 1
                fi
                echo "garm-incus-storage-network: creating storage pool '$pool'" \
                  "($driver${
                    lib.optionalString (cfg.storagePool.source != "") ", source=${cfg.storagePool.source}"
                  })"
                ${incusBin} storage create "$pool" "$driver" ${lib.escapeShellArgs poolCreateArgs} </dev/null

                # Post-condition. `incus storage create` succeeding proves
                # nothing about WHAT it created: the loop-file fallback is a
                # success path.
                assert_not_loop_backed "just created"
              fi

              # Managed bridge (only create if absent — never re-set an existing
              # bridge's immutable ipv4.address).
              if ${incusBin} network show "$bridge" </dev/null >/dev/null 2>&1; then
                echo "garm-incus-storage-network: network '$bridge' present — no-op"
              else
                echo "garm-incus-storage-network: creating network '$bridge' ($addr, nat=$nat)"
                ${incusBin} network create "$bridge" \
                  "ipv4.address=$addr" "ipv4.nat=$nat" "ipv6.address=none" </dev/null
              fi

              # default profile root disk (create if the device is absent).
              if ${incusBin} profile device list default </dev/null 2>/dev/null | grep -qxF root; then
                echo "garm-incus-storage-network: profile default root present — no-op"
              else
                echo "garm-incus-storage-network: adding profile default root (pool=$pool)"
                ${incusBin} profile device add default root disk \
                  "pool=$pool" path=/ </dev/null
              fi

              # default profile eth0 nic on the managed bridge.
              if ${incusBin} profile device list default </dev/null 2>/dev/null | grep -qxF eth0; then
                echo "garm-incus-storage-network: profile default eth0 present — no-op"
              else
                echo "garm-incus-storage-network: adding profile default eth0 (network=$bridge)"
                ${incusBin} profile device add default eth0 nic \
                  "network=$bridge" name=eth0 </dev/null
              fi

              echo "garm-incus-storage-network: converged"
            '';
          };

          importScript = pkgs.writeShellApplication {
            name = "garm-incus-image-import";
            runtimeInputs = [
              incusPkg
              pkgs.coreutils
            ];
            text = ''
              set -euo pipefail
              alias="${cfg.image.alias}"
              src="${if cfg.image.source == null then "" else toString cfg.image.source}"

              # Idempotent: if the alias already resolves to an image, do nothing.
              if ${incusBin} image alias list --format csv 2>/dev/null \
                  | cut -d, -f1 | grep -qxF "$alias"; then
                echo "garm-incus-image-import: alias '$alias' already present — no-op"
                exit 0
              fi

              if [ -z "$src" ]; then
                echo "garm-incus-image-import: alias '$alias' absent and no source configured — operator must seed the image (services.garm-incus-runner-host.image.source)" >&2
                exit 0
              fi
              if [ ! -e "$src" ]; then
                echo "garm-incus-image-import: source '$src' does not exist" >&2
                exit 1
              fi

              echo "garm-incus-image-import: importing '$src' as alias '$alias'"
              ${incusBin} image import "$src" --alias "$alias" --reuse
              echo "garm-incus-image-import: done"
            '';
          };
        in
        {
          # (0) THE LOOP-FILE OUTCOME IS UNREACHABLE, not merely documented.
          #
          # `driver = "zfs"` with no `source` is not rejected by Incus — it is
          # QUIETLY REINTERPRETED as "build me a zpool inside
          # /var/lib/incus/disks/<pool>.img" (driver_zfs.go FillConfig(), and the
          # btrfs/lvm equivalents). The host then reports `driver: zfs` while
          # every per-job container rootfs lives in a file-backed pool stacked on
          # the real one — strictly worse than the `dir` driver a ZFS cutover
          # exists to remove, and indistinguishable from success in every status
          # output an operator would think to check.
          #
          # An option alone does not fix that: the defect is that the DEFAULT
          # (omit `source`) is the dangerous one. So the combination is refused
          # here, at eval, naming the hazard and the remedy — and the only way to
          # get a file-backed pool is to ask for one by name. The convergence
          # oneshot re-checks the live host on every switch (see
          # `assert_not_loop_backed` above), because an assertion only constrains
          # what THIS module renders, not what a previous generation left behind.
          #
          # Scoped to `managePreseed` because that is exactly when this module
          # creates a pool. With `managePreseed = false` both the preseed and the
          # convergence oneshot are inert, the options are pure declaration for
          # host-local units to read, and rejecting them here would fail hosts
          # this module never touches.
          assertions = [
            {
              assertion =
                !(cfg.managePreseed && poolWouldBeLoopFileBacked && !cfg.storagePool.allowLoopFileBacking);
              message = ''
                services.garm-incus-runner-host.storagePool declares
                driver = "${cfg.storagePool.driver}" with an empty `source`, and
                managePreseed = true.

                Incus does NOT treat that as an error. Its ${cfg.storagePool.driver} driver
                FillConfig() rewrites the pool's `source` to
                ${poolLoopFile}, creates a sparse file there, and builds the
                pool INSIDE it. The result reports `driver: ${cfg.storagePool.driver}` in
                `incus storage list` while every per-job container rootfs lives
                in a file-backed pool stacked on the host filesystem — worse
                than the `dir` driver, and silent. The check that tells the two
                apart is `ls -A /var/lib/incus/disks/`, which must be empty.

                Fix: set
                  services.garm-incus-runner-host.storagePool.source
                to the EXISTING backing store the pool should adopt (for zfs, a
                dataset name such as "zroot/root/var/lib/incus-storage"; the
                dataset must already exist — this module adopts, it does not
                create).

                If a loop-file-backed pool really is what you want, say so:
                  services.garm-incus-runner-host.storagePool.allowLoopFileBacking = true;
              '';
            }
          ];

          # (1) FUSE on the HOST kernel. Incus bind-mounts `/dev/fuse` into
          # every container from its own static device set — NOT from LXC's
          # config templates, which only carry the `c 10:229 rwm` cgroup allow.
          # The bind is in Incus itself,
          # internal/server/instance/drivers/driver_lxc.go, where "/dev/fuse"
          # heads an unconditional `bindMounts` list emitted as
          #   lxc.mount.entry = /dev/fuse dev/fuse none bind,create=file,optional 0 0
          # The surrounding privilege branches only affect binfmt_misc and
          # mqueue, so a per-job container gets the device with NO
          # container-side config — unprivileged and idmapped included, and
          # FUSE mounts from inside a user namespace have been permitted since
          # Linux 4.18. (Confirmed on a live per-job container:
          # `crw-rw-rw- 1 nobody nogroup 10, 229 /dev/fuse`, uid_map
          # `0 1000000 1000000000`, no security.privileged/nesting.)
          #
          # But the loop skips any path that `!PathExists()` on the HOST, and
          # the entry is `optional` besides. So a host without `/dev/fuse`
          # produces containers with no device and NO error anywhere — nothing
          # fails, nothing logs. Nothing in a minimal NixOS closure guarantees
          # the module is loaded: `/dev/fuse` appears on demand via module
          # autoload, and on a host where no service ever opens it the device
          # is simply absent — and then every per-job container
          # silently lacks it too, which surfaces to CI as
          #   tup error: Unable to mount FUSE on .tup/mnt
          # in a job that has no way to fix it. Declare the dependency here,
          # where the runner class is declared, so it holds from boot rather
          # than by luck of what else the host happens to run.
          #
          # This is the runner class's HALF of the requirement. The other half
          # is guest-side: the image must ship a SETUID `fusermount3`
          # (Debian's `fuse3` package), because libfuse spawns that helper to
          # obtain the `/dev/fuse` descriptor and nothing in a Nix store can be
          # setuid. That half lives in the vm-harness runner-image recipe.
          boot.kernelModules = [ "fuse" ];

          # (2) The full host triple — managed incusbr0 bridge + the declared
          # storage pool + the `default` profile's root/eth0 devices — declared via
          # incus.preseed. nixpkgs' incus module renders an idempotent
          # incus-preseed.service that CREATES/UPDATES (never removes) these
          # after incus.service, on a FRESH (uninitialised) incus. For a host
          # whose incus already self-initialised, (2b) below converges the same
          # triple imperatively.
          virtualisation.incus.preseed = mkIf cfg.managePreseed {
            networks = [
              {
                name = cfg.bridgeName;
                type = "bridge";
                config = {
                  "ipv4.address" = "${gateway}/${prefix}";
                  "ipv4.nat" = lib.boolToString cfg.nat;
                  "ipv6.address" = "none";
                };
              }
            ];
            storage_pools = [
              (
                {
                  name = cfg.storagePool.name;
                  driver = cfg.storagePool.driver;
                }
                # `config.source` is what makes a zfs/btrfs/lvm pool ADOPT an
                # existing backing store instead of being built inside
                # /var/lib/incus/disks/<pool>.img. Emitted from the same
                # `poolConfig` the convergence oneshot passes to `incus storage
                # create`, so preseed and oneshot cannot disagree — and note
                # `incus admin init --preseed` HARD-FAILS on a driver mismatch
                # against an existing pool ("Storage pool X is of type zfs
                # instead of dir"), so a preseed that under-declares the pool
                # leaves incus-preseed.service permanently red.
                // lib.optionalAttrs (poolConfig != { }) { config = poolConfig; }
              )
            ];
            profiles = [
              {
                name = "default";
                devices = {
                  root = {
                    type = "disk";
                    path = "/";
                    pool = cfg.storagePool.name;
                  };
                  eth0 = {
                    type = "nic";
                    network = cfg.bridgeName;
                    name = "eth0";
                  };
                };
              }
            ];
          };

          # (2b) The convergence oneshot — idempotent create-if-missing of the
          # storage pool + bridge + default profile devices, ordered after the
          # incus daemon. RemainAfter so a re-switch re-checks; each guarded step
          # keeps it a no-op on a converged host. This is what lets a fresh GPU
          # host (whose incus self-initialised empty before this config landed)
          # come up with zero hand steps. Gated on managePreseed so adopted hosts
          # (managePreseed = false) stay byte-unchanged.
          systemd.services.garm-incus-storage-network = mkIf cfg.managePreseed {
            description = "Converge the GARM incus storage pool, bridge, and default profile devices";
            after = [
              "incus.service"
              "incus-preseed.service"
            ];
            requires = [ "incus.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = lib.getExe convergeScript;
            };
          };

          # (3) The runner-image import oneshot — idempotent, ordered after the
          # incus daemon (and after the preseed so the bridge exists). RemainAfter
          # so a re-switch re-checks; the check-then-import keeps it a no-op when
          # the image is already present.
          systemd.services.garm-incus-image-import = mkIf cfg.image.enable {
            description = "Import the GARM incus runner image if absent";
            # Order after the storage-network convergence oneshot only when it
            # exists (managePreseed); this keeps the image-import unit
            # byte-identical on adopted hosts (managePreseed = false).
            after = [
              "incus.service"
              "incus-preseed.service"
            ]
            ++ lib.optional cfg.managePreseed "garm-incus-storage-network.service";
            requires = [ "incus.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = lib.getExe importScript;
            };
          };
        }
      );
    };
}
