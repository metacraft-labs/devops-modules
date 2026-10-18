{ withSystem, inputs, ... }:
{
  flake.modules.nixos.mcl-disko =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    with lib;
    let
      cfg = config.mcl.disko;
    in
    {
      imports = [
        inputs.disko.nixosModules.disko
      ];
      options.mcl.disko = {
        enable = mkEnableOption "Enable Module";

        partitioningPreset = mkOption {
          type = types.enum [
            "zfs"
            "zfs-legacy-boot"
            "ext4"
          ];
          default = "zfs";
          example = "zfs-legacy-boot";
          description = "Declare the type of the primary partition";
        };

        swap = {
          size = mkOption {
            type = types.nullOr types.str;
            default = "32G";
            example = "32768M";
            description = "The size of the hard disk space used when RAM is full";
          };

          randomEncryption = mkOption {
            type = types.bool;
            default = true;
            example = false;
            description = "Whether to use random encryption for swap partition";
          };
        };

        espSize = mkOption {
          type = types.str;
          default = "4G";
          example = "4096M";
          description = "The size of the hard disk space used for the ESP filesystem";
        };

        disks = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [
            "/dev/disk/sda"
            "/dev/disk/sdb"
            "/dev/disk/sdc"
          ];
          description = "The disk partitions to be used when ZFS is being created";
        };

        disksNames = mkOption {
          type = types.listOf types.str;
          default = cfg.disks;
          example = [
            "sda"
            "sdb"
            "sdc"
          ];
          description = "The disk partitions names to be used when ZFS is being created";
        };

        zpool = {
          name = mkOption {
            type = types.str;
            default = "zfs_root";
            description = "The name of the ZFS Pool";
          };

          mode = mkOption {
            type = types.enum [
              "stripe"
              "mirror"
              "raidz1"
              "raidz2"
              "raidz3"
            ];
            default = "stripe";
            description = "Set ZFS Pool redundancy - e.g. 'mirror', 'raidz1', etc.";
          };

          extraDatasets = mkOption {
            type = types.attrsOf (
              types.submodule (
                { name, ... }:
                {
                  options = {
                    mountpoint = mkOption {
                      type = types.nullOr types.str;
                      default = name;
                      example = "/var/lib";
                      description = "The ZFS dataset mountpoint";
                    };

                    type = mkOption {
                      type = types.enum [
                        "zfs_fs"
                        "zfs_volume"
                      ];
                      default = "zfs_fs";
                      description = "Type of ZFS dataset";
                    };

                    options = mkOption {
                      type = types.attrs;
                      default = { };
                      example = {
                        refreservation = "50G";
                      };
                      description = "";
                    };

                    snapshot = mkEnableOption "Whether to enable ZFS snapshots";

                    refreservation = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                      description = "Size of reservations";
                    };
                  };
                }
              )
            );
            default = { };
            example = {
              "/opt".snapshot = false;
              "/opt/downloads".snapshot = false;
              "/opt/downloads/vm-images" = {
                snapshot = false;
                options = {
                  quota = "120G";
                };
              };
            };
            description = "Extra ZFS Pool datasets";
          };
        };
      };

      # EXISTING POOLS: move /home from `refreservation` to `reservation` IN
      # PLACE (zpool.nix explains why the property changed). disko applies dataset
      # properties only when it creates the pool, so hosts installed before the
      # change keep `refreservation=200GiB`, and every `zfs snapshot` of /home
      # fails with "out of space" once less than 200 GiB is free. This converges
      # them on the next deploy and is a no-op everywhere else: a pool without
      # `root/home`, or one already at `refreservation=none`, exits at once.
      # The reservation is set BEFORE the refreservation is dropped, so /home is
      # never without its 200 GiB guarantee; a failure leaves the unit failed,
      # visibly, rather than half-applied in silence.
      config.systemd.services.mcl-disko-home-reservation = lib.mkIf cfg.enable {
        description = "Move /home from refreservation to reservation (mcl-disko)";
        wantedBy = [ "multi-user.target" ];
        after = [ "zfs-mount.service" ];
        path = [ config.boot.zfs.package ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ds=${cfg.zpool.name}/root/home
          zfs list -H -o name "$ds" >/dev/null 2>&1 || exit 0
          if [ "$(zfs get -H -o value refreservation "$ds")" = none ]; then
            exit 0
          fi
          zfs set reservation=200GiB "$ds"
          zfs set refreservation=none "$ds"
          echo "mcl-disko: $ds now uses reservation=200GiB, refreservation=none"
        '';
      };

      config.disko =
        let
          makePrimaryZfsDisk = import ./primaryPartition;
          makeSecondaryZfsDisk = import ./secondaryZfsPartition.nix;

          first = builtins.head cfg.disks;
          rest = builtins.tail cfg.disks;

          firstDiskName = builtins.head cfg.disksNames;
          restDisksNames = builtins.tail cfg.disksNames;

          secondaryDisks = builtins.listToAttrs (
            lib.zipListsWith (disk: diskName: {
              name = diskName;
              value =
                if cfg.zpool.mode != "stripe" then
                  makePrimaryZfsDisk {
                    inherit disk lib;
                    isSecondary = true;
                    espSize = cfg.espSize;
                    swapSize = cfg.swap.size;
                    partitioningPreset = cfg.partitioningPreset;
                    poolName = cfg.zpool.name;
                    randomEncryption = cfg.swap.randomEncryption;
                  }
                else
                  makeSecondaryZfsDisk {
                    poolName = cfg.zpool.name;
                    inherit disk lib;
                  };
            }) rest restDisksNames
          );

        in
        lib.mkIf cfg.enable {
          devices = {
            disk = secondaryDisks // {
              "${firstDiskName}" = makePrimaryZfsDisk {
                inherit lib;
                disk = first;
                isSecondary = false;
                espSize = cfg.espSize;
                swapSize = cfg.swap.size;
                partitioningPreset = cfg.partitioningPreset;
                poolName = cfg.zpool.name;
                randomEncryption = cfg.swap.randomEncryption;
              };
            };
            zpool = import ./zpool.nix {
              poolName = cfg.zpool.name;
              poolMode = cfg.zpool.mode;
              poolExtraDatasets = cfg.zpool.extraDatasets;
              partitioningPreset = cfg.partitioningPreset;
              inherit lib;
            };
          };
        };
    };
}
