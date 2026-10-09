{
  lib,
  poolName,
  poolMode,
  poolExtraDatasets,
  partitioningPreset,
}:
let
  translateDataSetToDiskoConfig =
    dataset@{ snapshot, refreservation, ... }:
    lib.recursiveUpdate dataset {
      type = "zfs_fs";
      options = {
        "com.sun:auto-snapshot" = if dataset.snapshot then "on" else "off";
        canmount = "on";
      }
      // (if (refreservation != null) then { inherit refreservation; } else { });
    };

  restructuredDatasets = builtins.mapAttrs (
    n: v:
    (builtins.removeAttrs (translateDataSetToDiskoConfig poolExtraDatasets.${n}) [
      "refreservation"
      "snapshot"
    ])
  ) poolExtraDatasets;
in
{
  ${poolName} = {
    type = "zpool";
    mode = if poolMode == "stripe" then "" else poolMode;
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

    postCreateHook = "zfs snapshot ${poolName}@blank";

    datasets =
      lib.optionalAttrs (partitioningPreset != "ext4") {
        root = {
          mountpoint = "/";
          type = "zfs_fs";
          options = {
            "com.sun:auto-snapshot" = "false";
            mountpoint = "legacy";
          };
        };
      }
      // (lib.recursiveUpdate {
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
      } restructuredDatasets);
  };
}
