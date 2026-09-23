{
  nix2container,

  lib,
  runCommand,
  buildEnv,

  nix,
  coreutils,
  bashInteractive,
  cacert,
}:
rec {
  # Based on:
  # https://github.com/nlewo/nix2container/blob/93aa7880805df3c8d3b9008923c4c3b47e2bd70b/examples/nix-user.nix#L10
  mkUser =
    {
      user ? "user",
      group ? user,
      uid ? 1000,
      gid ? 1000,
      trustedUsers ? [
        "root"
        user
      ],
    }:
    runCommand "mkUser" { } ''
      mkdir -p $out/etc/pam.d
      mkdir -p $out/etc/nix

      echo "${user}:x:${toString uid}:${toString gid}::" > $out/etc/passwd
      echo "${user}:!x:::::::" > $out/etc/shadow

      echo "${group}:x:${toString gid}:" > $out/etc/group
      echo "${group}:x::" > $out/etc/gshadow

      cat > $out/etc/pam.d/other <<EOF
      account sufficient pam_unix.so
      auth sufficient pam_rootok.so
      password requisite pam_unix.so nullok sha512
      session required pam_unix.so
      EOF

      cat > $out/etc/nix/nix.conf <<EOF
      trusted-users = ${lib.concatStringsSep " " trustedUsers}
      experimental-features = nix-command flakes
      fallback = false
      download-attempts = 5
      connect-timeout = 60
      narinfo-cache-negative-ttl = 120
      allow-import-from-derivation = true
      EOF

      touch $out/etc/login.defs
      mkdir -p $out/home/${user}
      mkdir -p $out/tmp
    '';

  mkNixImage =
    {
      imageName,
      packages ? [ ],
      userName ? "user",
      groupName ? userName,
      uid ? 1000,
      gid ? 1001,
    }:
    let
      userDrv = mkUser {
        inherit uid gid;
        user = userName;
        group = groupName;
        trustedUsers = [
          "root"
          userName
        ];
      };

      homeDir = "/home/${userName}";
    in
    nix2container.buildImage {
      name = imageName;

      initializeNixDatabase = true;
      nixUid = uid;
      nixGid = gid;

      copyToRoot = [
        (buildEnv {
          name = "root";
          paths = [
            coreutils
            nix
            cacert
            bashInteractive
          ]
          ++ packages;
          pathsToLink = [ "/bin" ];
        })
        userDrv
      ];

      perms = [
        {
          path = userDrv;
          regex = homeDir;
          mode = "0755";
          inherit uid gid;
          uname = userName;
          gname = groupName;
        }
        {
          path = userDrv;
          regex = "/tmp";
          mode = "1777";
          uid = 0;
          gid = 0;
          uname = "root";
          gname = "root";
        }
      ];

      config = {
        Entrypoint = [ (lib.getExe bashInteractive) ];
        User = toString uid;
        WorkingDir = homeDir;
        Env = [
          "HOME=${homeDir}"
          "USER=${userName}"
          "NIX_PAGER=cat"
          "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt"
          # NOTE: for Haskell's TLS library (used by `cachix`) library
          "SYSTEM_CERTIFICATE_PATH=${cacert}/etc/ssl/certs/ca-bundle.crt"
        ];
      };
    };
}
