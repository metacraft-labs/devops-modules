top@{ ... }:
{
  # Gate `t_garm_incus_storage_pool_source` — the `zfs` storage pool a GARM
  # incus runner host declares must ADOPT an existing dataset, and the
  # loop-file outcome must be impossible to reach by accident.
  #
  # ── THE DEFECT THIS GATE EXISTS TO KEEP OUT ────────────────────────────────
  #
  # `services.garm-incus-runner-host.storagePool` used to carry only `name` and
  # `driver`, and `garm-incus-storage-network` ran a bare
  #   incus storage create "$pool" "$driver"
  # Incus does not treat a source-less `zfs` pool as an error. Its
  # driver_zfs.go `FillConfig()` has an explicit branch for it:
  #
  #   } else if len(devices) == 0 || (len(devices) == 1 && devices[0] == loopPath) {
  #           // Create a loop based pool.
  #           d.config["source"] = loopPath          // <varpath>/disks/<pool>.img
  #
  # so `driver = "zfs"` ALONE gets you a sparse file under
  # /var/lib/incus/disks/, a zpool built inside it, and — this is the part that
  # makes it dangerous rather than merely wrong — `incus storage list` that
  # goes on reporting `driver: zfs`. Every per-job container rootfs then lives
  # in a zpool stacked on a file on the host's real pool: strictly worse than
  # the `dir` driver a ZFS cutover exists to remove, with nothing anywhere
  # saying so. The btrfs and lvm drivers have the same branch.
  #
  # The one check that tells the two apart is `ls -A /var/lib/incus/disks/`,
  # which must be EMPTY on a host with adopted backing stores. This gate is
  # built around exactly that check.
  #
  # ── HOW THIS GATE DISCRIMINATES (the negative controls) ────────────────────
  #
  # A gate that only asserted "the adopted pool has source=X" would pass on a
  # host where Incus quietly ignored the key, and would say nothing about
  # whether the hazard is real on the Incus actually pinned here. So:
  #
  #   (A) EVAL. Four evaluations of the SAME module differing in one option
  #       each, asserting that the rejection fires on exactly the dangerous one
  #       and on nothing else — including that the message names the loop-file
  #       path and the remedy, and that `dir` (which has no such fallback) is
  #       untouched.
  #
  #   (B) RUNTIME NEGATIVE CONTROL — node `loopfile`. The same module, with
  #       `allowLoopFileBacking = true`, i.e. byte-for-byte the behaviour the
  #       module had BEFORE this change (a bare `incus storage create <pool>
  #       zfs`). It asserts the defect REPRODUCES on this Incus: the unit is
  #       GREEN, `incus storage show` reports `driver: zfs`, and yet
  #       /var/lib/incus/disks/<pool>.img exists and the pool's `source` is
  #       that file. If a future Incus ever stopped doing this, this node fails
  #       and the whole premise of the fix gets re-examined rather than the fix
  #       silently becoming decorative.
  #
  #   (C) RUNTIME POSITIVE — node `adopted`. `source` set to a pre-existing
  #       dataset: the pool adopts it (`source` and `zfs.pool_name` both point
  #       at the real dataset), Incus creates its volume datasets underneath
  #       it, and /var/lib/incus/disks/ is EMPTY.
  #
  #   (D) THE RUNTIME GUARD IS NOT DECORATIVE. On the `adopted` node the gate
  #       PLANTS a loop file at the path the driver would have used and
  #       restarts the convergence oneshot; the unit must FAIL and say so. An
  #       eval-time assertion only constrains what this module renders — it
  #       says nothing about what a previous generation left on the host — so
  #       the on-host re-check has to be proven too.
  #
  # Both runtime nodes neutralise nixpkgs' `incus-preseed.service` (test-only
  # `mkForce`, and the ONLY mkForce in this file) so that the module's
  # `garm-incus-storage-network` oneshot is provably the thing that creates the
  # pool. That is not an artificial arrangement: it is the documented state of
  # gpu-server-001, whose incus daemon self-initialised empty before this
  # config landed, which is why the convergence oneshot exists at all. Node
  # `preseeded` covers the other half — a fresh incus where the PRESEED is the
  # creator — and asserts `incus-preseed.service` is green, because a preseed
  # that under-declares the pool's driver leaves that unit permanently red
  # ("Storage pool X is of type zfs instead of dir").
  perSystem =
    {
      pkgs,
      lib,
      ...
    }:
    let
      flake = top.config.flake;

      subnet = "10.157.159.0/24";

      # The gate's own zpool, and the dataset a declared pool must adopt. Named
      # after the milestone rather than after any host so nothing here can be
      # mistaken for a live configuration.
      zpoolName = "gatepool";
      backingDataset = "${zpoolName}/incus-storage";
      vdevFile = "/var/lib/gate-vdev.img";

      # ---- (A) the eval-time half ------------------------------------------
      #
      # Evaluate the module standalone (no VM) and read back `config.assertions`
      # rather than letting the module system throw, so a REJECTION is an
      # observable value we can assert the content of.
      evalRunnerHost =
        storagePool: extra:
        (lib.evalModules {
          specialArgs = { inherit pkgs; };
          modules = [
            flake.modules.nixos.garm-incus-runner-host
            {
              options = {
                # The handful of things the module reads out of the wider NixOS
                # config. Stubbed so this eval needs no full nixosSystem.
                virtualisation.incus.package = lib.mkOption {
                  type = lib.types.package;
                  default = pkgs.incus;
                };
                virtualisation.incus.preseed = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = { };
                };
                boot.kernelModules = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                };
                systemd.services = lib.mkOption {
                  type = lib.types.attrsOf lib.types.anything;
                  default = { };
                };
                assertions = lib.mkOption {
                  type = lib.types.listOf lib.types.anything;
                  default = [ ];
                };
              };
            }
            {
              services.garm-incus-runner-host = {
                enable = true;
                bridgeSubnet = subnet;
                image.enable = false;
                inherit storagePool;
              }
              // extra;
            }
          ];
        }).config;

      # The failing assertion messages of one such evaluation.
      failedMessages =
        cfg: map (a: a.message) (builtins.filter (a: !a.assertion) (cfg.assertions or [ ]));

      evalCases = {
        # THE DANGEROUS DECLARATION — must be rejected.
        zfsNoSource = evalRunnerHost {
          name = "default";
          driver = "zfs";
        } { };
        # The fix — must be accepted. `extraConfig` rides along so the
        # pass-through for every OTHER pool config key is covered too; an
        # option nothing exercises is an option that quietly stops working.
        zfsWithSource = evalRunnerHost {
          name = "default";
          driver = "zfs";
          source = backingDataset;
          extraConfig."zfs.clone_copy" = "rebase";
        } { };
        # The explicit opt-in — must be accepted.
        zfsOptIn = evalRunnerHost {
          name = "default";
          driver = "zfs";
          allowLoopFileBacking = true;
        } { };
        # `dir` has no loop-file fallback — must NOT be caught by the rejection.
        dirNoSource = evalRunnerHost { name = "default"; } { };
        # The module creates no pool at all here, so there is nothing to reject.
        zfsNoSourceUnmanaged = evalRunnerHost {
          name = "default";
          driver = "zfs";
        } { managePreseed = false; };
        # btrfs shares driver_zfs.go's loop-file branch — must be rejected too.
        btrfsNoSource = evalRunnerHost {
          name = "default";
          driver = "btrfs";
        } { };
      };

      rejection = lib.head (failedMessages evalCases.zfsNoSource ++ [ "" ]);

      evalFailures =
        # The rejection fires ...
        lib.optional (failedMessages evalCases.zfsNoSource == [ ])
          "driver = \"zfs\" with no `source` and managePreseed = true was ACCEPTED; the module still renders a silent loop-file pool"
        ++ lib.optional (
          failedMessages evalCases.btrfsNoSource == [ ]
        ) "driver = \"btrfs\" with no `source` was ACCEPTED; btrfs has the same loop-file fallback as zfs"
        # ... and says what is wrong, where the damage lands, and how to fix it.
        # A rejection nobody can act on is a different bug, not a fix.
        ++ lib.optional (
          !(lib.hasInfix "/var/lib/incus/disks/default.img" rejection)
        ) "the rejection does not name the loop file it prevents: ${rejection}"
        ++ lib.optional (
          !(lib.hasInfix "storagePool.source" rejection)
        ) "the rejection does not name the option that fixes it: ${rejection}"
        ++ lib.optional (
          !(lib.hasInfix "allowLoopFileBacking" rejection)
        ) "the rejection does not name the opt-in escape hatch: ${rejection}"
        # ... and ONLY on the dangerous declaration.
        ++
          lib.optional (failedMessages evalCases.zfsWithSource != [ ])
            "declaring `source` did NOT satisfy the module: ${toString (failedMessages evalCases.zfsWithSource)}"
        ++
          lib.optional (failedMessages evalCases.zfsOptIn != [ ])
            "allowLoopFileBacking = true did NOT satisfy the module: ${toString (failedMessages evalCases.zfsOptIn)}"
        ++
          lib.optional (failedMessages evalCases.dirNoSource != [ ])
            "the `dir` driver was rejected; it has no loop-file fallback and must be untouched: ${toString (failedMessages evalCases.dirNoSource)}"
        ++
          lib.optional (failedMessages evalCases.zfsNoSourceUnmanaged != [ ])
            "managePreseed = false was rejected; with it the module creates no pool, so there is nothing to reject: ${toString (failedMessages evalCases.zfsNoSourceUnmanaged)}"
        # The declared `source` must reach BOTH renderers. The preseed and the
        # oneshot create the pool on different hosts (fresh vs already
        # self-initialised incus); a `source` that reached only one of them
        # would leave the other producing the loop file.
        ++ lib.optional (
          let
            pools = evalCases.zfsWithSource.virtualisation.incus.preseed.storage_pools or [ ];
          in
          !(builtins.length pools == 1 && (lib.head pools).config.source or null == backingDataset)
        ) "the preseed's storage_pools entry does not carry config.source = ${backingDataset}"
        ++ lib.optional (
          let
            pools = evalCases.zfsWithSource.virtualisation.incus.preseed.storage_pools or [ ];
          in
          !(builtins.length pools == 1 && (lib.head pools).config."zfs.clone_copy" or null == "rebase")
        ) "storagePool.extraConfig does not reach the preseed's config block"
        ++ lib.optional (
          let
            unit = evalCases.zfsWithSource.systemd.services.garm-incus-storage-network or null;
            exec = if unit == null then "" else toString (unit.serviceConfig.ExecStart or "");
            script = if exec == "" then "" else builtins.readFile exec;
          in
          !(lib.hasInfix "'zfs.clone_copy=rebase'" script)
        ) "storagePool.extraConfig does not reach `incus storage create`"
        ++ lib.optional (
          let
            unit = evalCases.zfsWithSource.systemd.services.garm-incus-storage-network or null;
            exec = if unit == null then "" else toString (unit.serviceConfig.ExecStart or "");
            script = if exec == "" then "" else builtins.readFile exec;
          in
          # Match the EXECUTABLE invocation, not the word. A bare
          # `hasInfix "source=<dataset>"` was vacuous when this was first
          # written: the unit's own progress `echo` mentions
          # "(zfs, source=<dataset>)", so deleting the argument from
          # `incus storage create` — the whole defect — still satisfied it.
          # Verified by doing exactly that: `poolCreateArgs = [ ]` left the
          # gate GREEN. Pinning the argument position (single-quoted by
          # lib.escapeShellArgs, right after the driver) is what makes this
          # discriminate.
          !(lib.hasInfix "storage create \"$pool\" \"$driver\" 'source=${backingDataset}'" script)
        ) "garm-incus-storage-network never passes source=${backingDataset} to `incus storage create`";

      evalReport =
        if evalFailures == [ ] then
          ''
            (A) eval contract OK:
              - driver = "zfs" / "btrfs" with no `source` and managePreseed = true
                is REJECTED, naming /var/lib/incus/disks/<pool>.img, the
                `storagePool.source` remedy, and the `allowLoopFileBacking` opt-in
              - `source`, `allowLoopFileBacking = true`, the `dir` driver and
                managePreseed = false are each ACCEPTED (no false positives)
              - the declared source reaches BOTH the preseed's storage_pools
                config block and `incus storage create` in
                garm-incus-storage-network
          ''
        else
          throw ''
            (A) eval contract FAILED:
            - ${lib.concatStringsSep "\n- " evalFailures}
          '';

      # ---- (B)/(C)/(D) the runtime half ------------------------------------
      #
      # Shared node skeleton. ZFS in a nixosTest needs the module loaded and a
      # hostId; the vdev is a sparse file on the VM's own disk so nothing here
      # depends on the builder's RAM.
      baseNode =
        { config, ... }:
        {
          imports = [ flake.modules.nixos.garm-incus-runner-host ];

          boot.supportedFilesystems.zfs = true;
          boot.kernelModules = [ "zfs" ];
          networking.hostId = "c0ffee01";
          networking.nftables.enable = true;

          virtualisation.incus.enable = true;
          # Incus refuses to build a default-sized loop pool with less than
          # 5 GiB free under /var/lib/incus (drivers/utils.go
          # loopFileSizeDefault), and the negative control NEEDS that path to
          # succeed — a node that was merely too small would "pass" it for the
          # wrong reason.
          virtualisation.diskSize = 16384;
          virtualisation.memorySize = 4096;

          environment.systemPackages = [
            config.boot.zfs.package
            pkgs.jq
          ];

          services.garm-incus-runner-host = {
            enable = true;
            bridgeSubnet = subnet;
            # Nothing here is about images; keep the import oneshot out of the
            # way so a failure can only be about storage.
            image.enable = false;
          };
        };

      # The host-side provisioning of the backing store. Deliberately a
      # SEPARATE unit ordered before incus, mirroring how a real host provisions
      # the dataset (`ensure-incus-storage-dataset`): this module ADOPTS an
      # existing dataset, it never creates one.
      zpoolNode =
        { config, ... }:
        {
          systemd.services.gate-zpool = {
            description = "Gate: create the zpool + dataset the declared Incus pool must adopt";
            before = [ "incus.service" ];
            wantedBy = [ "multi-user.target" ];
            path = [
              config.boot.zfs.package
              pkgs.coreutils
            ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              set -euo pipefail
              if ! zpool list -H -o name ${zpoolName} >/dev/null 2>&1; then
                truncate -s 4G ${vdevFile}
                zpool create -f ${zpoolName} ${vdevFile}
              fi
              if ! zfs list -H -o name ${backingDataset} >/dev/null 2>&1; then
                zfs create -o mountpoint=none ${backingDataset}
              fi
            '';
          };
          # incus (and therefore incus-preseed, which is After=incus.service)
          # must not run before the dataset exists.
          systemd.services.incus = {
            after = [ "gate-zpool.service" ];
            wants = [ "gate-zpool.service" ];
          };
        };

      # The ONLY mkForce in this gate, and it is test-only: it reproduces the
      # documented gpu-server-001 state — an incus daemon that self-initialised
      # empty before this config landed, where nixpkgs' preseed contributes
      # nothing and `garm-incus-storage-network` is the sole creator of the
      # pool. Without it the preseed wins the race on both runtime nodes and
      # the oneshot's `incus storage create` path would never be exercised.
      preseedInert = {
        systemd.services.incus-preseed.wantedBy = lib.mkForce [ ];
      };
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_incus_storage_pool_source =
          let
            e2e = pkgs.testers.nixosTest {
              name = "t_garm_incus_storage_pool_source";

              nodes = {
                # (C)+(D) the fix: a declared `source` adopts the dataset.
                adopted =
                  { ... }:
                  {
                    imports = [
                      baseNode
                      zpoolNode
                      preseedInert
                    ];
                    services.garm-incus-runner-host.storagePool = {
                      name = "default";
                      driver = "zfs";
                      source = backingDataset;
                    };
                  };

                # (B) the negative control: the pre-fix behaviour, opted into.
                loopfile =
                  { ... }:
                  {
                    imports = [
                      baseNode
                      preseedInert
                    ];
                    services.garm-incus-runner-host.storagePool = {
                      name = "default";
                      driver = "zfs";
                      # No `source` — exactly what the module used to emit
                      # unconditionally. The opt-in is the only reason this
                      # node evaluates at all, which is itself the point.
                      allowLoopFileBacking = true;
                    };
                  };

                # The other creator: a FRESH incus, where the preseed applies.
                preseeded =
                  { ... }:
                  {
                    imports = [
                      baseNode
                      zpoolNode
                    ];
                    services.garm-incus-runner-host.storagePool = {
                      name = "default";
                      driver = "zfs";
                      source = backingDataset;
                    };
                  };
              };

              testScript = ''
                start_all()

                for m in (adopted, loopfile, preseeded):
                    m.wait_for_unit("multi-user.target")
                    m.wait_for_unit("incus.service")

                with subtest("(B) NEGATIVE CONTROL: a source-less zfs pool IS silently loop-file backed"):
                    # This node runs the module with allowLoopFileBacking = true,
                    # i.e. the bare `incus storage create <pool> zfs` the module
                    # used to run unconditionally. Everything about it looks
                    # healthy — which is the defect.
                    loopfile.wait_for_unit("garm-incus-storage-network.service")
                    result = loopfile.succeed(
                        "systemctl show -p Result --value garm-incus-storage-network.service"
                    ).strip()
                    assert result == "success", f"negative-control oneshot result={result!r}"

                    pool_driver = loopfile.succeed(
                        "incus storage show default | sed -n 's/^driver: //p'"
                    ).strip()
                    assert pool_driver == "zfs", f"negative control did not produce a zfs pool: {pool_driver!r}"

                    # ... and yet:
                    disks = loopfile.succeed("ls -A /var/lib/incus/disks/ || true").strip()
                    assert "default.img" in disks, (
                        "the loop-file hazard did NOT reproduce on this Incus "
                        f"(/var/lib/incus/disks is {disks!r}); the premise of this fix "
                        "no longer holds and must be re-examined"
                    )
                    src = loopfile.succeed("incus storage get default source").strip()
                    assert src == "/var/lib/incus/disks/default.img", (
                        f"negative-control pool source={src!r}"
                    )
                    # The `zfs list` view is the plainest statement of what went
                    # wrong: a whole zpool living inside one file.
                    print(loopfile.succeed("zpool status default || true"))

                with subtest("(C) the declared source makes the pool ADOPT the existing dataset"):
                    adopted.wait_for_unit("garm-incus-storage-network.service")
                    result = adopted.succeed(
                        "systemctl show -p Result --value garm-incus-storage-network.service"
                    ).strip()
                    assert result == "success", f"convergence oneshot result={result!r}"
                    # The oneshot, not the preseed, created it here.
                    adopted.succeed(
                        "journalctl -u garm-incus-storage-network.service "
                        "| grep -qF \"creating storage pool 'default' (zfs, source=${backingDataset})\""
                    )

                    pool_driver = adopted.succeed(
                        "incus storage show default | sed -n 's/^driver: //p'"
                    ).strip()
                    assert pool_driver == "zfs", f"pool driver={pool_driver!r}"
                    src = adopted.succeed("incus storage get default source").strip()
                    assert src == "${backingDataset}", f"pool source={src!r}"
                    pool_name = adopted.succeed("incus storage get default zfs.pool_name").strip()
                    assert pool_name == "${backingDataset}", f"zfs.pool_name={pool_name!r}"

                with subtest("(C) THE discriminator: /var/lib/incus/disks/ is empty"):
                    disks = adopted.succeed("ls -A /var/lib/incus/disks/ 2>/dev/null || true").strip()
                    assert disks == "", (
                        f"/var/lib/incus/disks is not empty ({disks!r}) — the pool is "
                        "loop-file backed, not adopted"
                    )

                with subtest("(C) Incus really writes into the adopted dataset"):
                    # Datasets appearing UNDER the adopted one is the positive
                    # proof that the pool is rooted there rather than merely
                    # labelled with its name.
                    adopted.succeed("incus storage volume create default gatevol")
                    datasets = adopted.succeed("zfs list -H -o name -r ${backingDataset}")
                    assert "${backingDataset}/custom" in datasets, (
                        f"no volume datasets under ${backingDataset}: {datasets!r}"
                    )
                    adopted.succeed("incus storage volume delete default gatevol")

                with subtest("(D) the on-host guard fails the unit if a loop file ever appears"):
                    # An eval assertion constrains what this module RENDERS; it
                    # says nothing about a loop file an earlier generation left
                    # behind. Plant one and require the unit to refuse.
                    adopted.succeed("mkdir -p /var/lib/incus/disks && touch /var/lib/incus/disks/default.img")
                    adopted.fail("systemctl restart garm-incus-storage-network.service")
                    adopted.succeed(
                        "journalctl -u garm-incus-storage-network.service "
                        "| grep -qF 'LOOP-FILE BACKED'"
                    )
                    adopted.succeed("rm -f /var/lib/incus/disks/default.img")
                    adopted.succeed("systemctl restart garm-incus-storage-network.service")

                with subtest("the preseed alone also produces an ADOPTED pool, and stays green"):
                    # `incus admin init --preseed` HARD-FAILS on a driver
                    # mismatch against an existing pool, so a preseed that
                    # under-declares the pool leaves this unit permanently red.
                    preseeded.wait_for_unit("incus-preseed.service")
                    result = preseeded.succeed(
                        "systemctl show -p Result --value incus-preseed.service"
                    ).strip()
                    assert result == "success", f"incus-preseed.service result={result!r}"
                    src = preseeded.succeed("incus storage get default source").strip()
                    assert src == "${backingDataset}", f"preseeded pool source={src!r}"
                    disks = preseeded.succeed("ls -A /var/lib/incus/disks/ 2>/dev/null || true").strip()
                    assert disks == "", f"preseeded /var/lib/incus/disks is not empty ({disks!r})"

                with subtest("the default profile's root disk lands on the adopted pool"):
                    for m in (adopted, preseeded):
                        rootpool = m.succeed("incus profile device get default root pool").strip()
                        assert rootpool == "default", f"root device pool={rootpool!r}"
              '';
            };
          in
          pkgs.runCommand "t_garm_incus_storage_pool_source"
            {
              passthru = { inherit e2e; };
              meta.description =
                "A declared zfs storage pool adopts an existing dataset; the "
                + "silent loop-file fallback is rejected at eval and refused on the host";
            }
            ''
              mkdir -p "$out"
              cat > "$out/eval-contract.txt" <<'EOF'
              ${evalReport}
              EOF
              ln -s ${e2e} "$out/e2e"
              echo passed > "$out/result"
            '';
      };
    };
}
