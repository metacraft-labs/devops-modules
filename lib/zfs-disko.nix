rec {
  makePrimaryZfsDisk =
    {
      disk,
      zpoolName,
      espSizeGB,
      swapSizeGB,
    }:
    {
      type = "disk";
      device = disk;
      content = {
        type = "table";
        format = "gpt";
        partitions = [
          {
            name = "ESP";
            start = "0";
            end = "${toString espSizeGB}GiB";
            bootable = true;
            fs-type = "fat32";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          }
          {
            name = "zfs";
            start = "${toString espSizeGB}GiB";
            end = "-${toString swapSizeGB}GiB";
            part-type = "primary";
            content = {
              type = "zfs";
              pool = "${zpoolName}";
            };
          }
          {
            name = "swap";
            start = "-${toString swapSizeGB}GiB";
            end = "100%";
            part-type = "primary";
            content = {
              type = "swap";
              randomEncryption = true;
            };
          }
        ];
      };
    };

  makeSecondaryZfsDisk =
    {
      disk,
      zpoolName,
    }:
    {
      type = "disk";
      device = disk;
      content = {
        type = "table";
        format = "gpt";
        partitions = [
          {
            name = "zfs";
            start = "0";
            end = "100%";
            part-type = "primary";
            content = {
              type = "zfs";
              pool = "${zpoolName}";
            };
          }
        ];
      };
    };

  makeZpool =
    {
      config,
      zpoolName,
    }:
    {
      ${zpoolName} = {
        type = "zpool";
        rootFsOptions = {
          acltype = "posixacl";
          atime = "off";
          canmount = "off";
          checksum = "sha512";
          compression = "lz4";
          xattr = "sa";
          mountpoint = "none";
          "com.sun:auto-snapshot" = "false";
        };
        options = {
          autotrim = "on";
          listsnapshots = "on";
        };

        postCreateHook = "zfs snapshot ${zpoolName}@blank";

        datasets = {
          root = {
            mountpoint = "/";
            type = "zfs_fs";
            options = {
              "com.sun:auto-snapshot" = "false";
              mountpoint = "legacy";
            };
          };

          "root/nix" = {
            mountpoint = "/nix";
            type = "zfs_fs";
            options = {
              "com.sun:auto-snapshot" = "false";
              canmount = "on";
              mountpoint = "legacy";
              refreservation = "100GiB";
            };
          };

          "root/var" = {
            mountpoint = "/var";
            type = "zfs_fs";
            options = {
              "com.sun:auto-snapshot" = "true";
              canmount = "on";
              mountpoint = "legacy";
            };
          };

          "root/var/lib" = {
            mountpoint = "/var/lib";
            type = "zfs_fs";
            options = {
              "com.sun:auto-snapshot" = "true";
              canmount = "on";
              mountpoint = "legacy";
            };
          };

          "root/home" = {
            mountpoint = "/home";
            type = "zfs_fs";
            options = {
              "com.sun:auto-snapshot" = "true";
              canmount = "on";
              mountpoint = "legacy";
              # A plain `reservation`, not `refreservation`: both guarantee /home
              # 200 GiB, but a refreservation must ALSO be re-guaranteed in full
              # the moment a snapshot exists (every block the dataset references
              # becomes shared with it), so with less than 200 GiB free in the
              # pool every `zfs snapshot` of /home fails with "out of space".
              # That broke Agent Harbor's copy-on-write workspaces and the
              # snapshot-first /home procedures in infra's runbooks. A reservation
              # counts snapshots against the same 200 GiB instead.
              # Existing pools keep the old property until it is changed in place:
              #   zfs set reservation=200GiB <pool>/root/home
              #   zfs set refreservation=none <pool>/root/home
              reservation = "200GiB";
            };
          };

          "root/var/lib/docker" = {
            mountpoint = "/var/lib/docker";
            type = "zfs_fs";
            options = {
              "com.sun:auto-snapshot" = "false";
              canmount = "on";
              mountpoint = "legacy";
              refreservation = "100GiB";
            };
          };

          "root/var/lib/containers" = {
            mountpoint = "/var/lib/containers";
            type = "zfs_fs";
            options = {
              "com.sun:auto-snapshot" = "false";
              canmount = "on";
              mountpoint = "legacy";
              refreservation = "100GiB";
            };
          };
        };
      };
    };

  makeZfsPartitions =
    {
      disks,
      config,
      zpoolName ? "zfs_root",
      espSizeGB ? 4,
      swapSizeGB ? 32,
    }:
    let
      first = builtins.head disks;
      rest = builtins.tail disks;
      secondaryDisks = builtins.listToAttrs (
        builtins.map (disk: {
          name = disk;
          value = makeSecondaryZfsDisk { inherit disk zpoolName; };
        }) rest
      );
    in
    {
      devices = {
        disk = secondaryDisks // {
          "${first}" = makePrimaryZfsDisk {
            disk = first;
            inherit zpoolName espSizeGB swapSizeGB;
          };
        };
        zpool = makeZpool { inherit config zpoolName; };
      };
    };
}
