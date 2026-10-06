{
  lib,
  dCompiler,
  pkgs,
  nix,
  nix-eval-jobs,
  ...
}:
let
  inherit (pkgs.stdenv.hostPlatform) isLinux isx86;
  deps =
    with pkgs;
    [
      nix
      nix-eval-jobs
    ]
    ++ (with pkgs; [
      age
      gitMinimal
      jc
      util-linux
      bash
      coreutils
      xrandr
      alejandra
      openssh
      cachix
      attic-client
      curl
    ])
    ++ lib.optionals (isLinux && isx86) [
      dmidecode
      systemd
    ];
  excludedTests = (
    lib.concatStringsSep "|" [
      "(nix\\.(build|run|eval))"
      "fetchJson|(coda\.)"
      "isCached"
      "generateShardMatrix"
    ]
  );

  # metacraft-cli.md §2.5 — "the deprecation shim fails. It does not forward."
  #
  # During the rename window this package still ships `bin/mcl`, but invoking
  # it prints the new name plus the arguments it was given and exits non-zero
  # without doing anything. A forwarding shim would keep stale call sites alive,
  # and those are exactly the sites that become dangerous once the name `mcl`
  # is rebound to the (unrelated) end-user client — a loud failure now is
  # cheaper than a silent retarget later.
  #
  # REMOVE THIS STUB before the new `mcl` client is published: at no instant may
  # two packages provide `bin/mcl`. `checks/mcl-devops-rename.nix` enforces both
  # halves of that (exactly one provider, and during the window it is this stub).
  deprecationStub = pkgs.writeShellScript "mcl-renamed-to-mcl-devops" ''
    {
      echo "mcl: this tool has been renamed to 'mcl-devops'."
      if [ "$#" -gt 0 ]; then
        echo "mcl: you invoked : mcl $*"
        echo "mcl: run instead : mcl-devops $*"
      else
        echo "mcl: run 'mcl-devops' instead."
      fi
      echo "mcl: this stub deliberately does not forward; see metacraft-specs/infrastructure/metacraft-cli.md section 2.5."
    } >&2
    exit 64
  '';
in
pkgs.buildDubPackage rec {
  pname = "mcl-devops";
  version = "unstable";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (
      file:
      builtins.any file.hasExt [
        "d"
        "sdl"
        "json"
        "nix"
      ]
    ) ./.;
  };

  inherit dCompiler;

  dubLock = ./dub-lock.json;

  nativeBuildInputs = [ pkgs.makeWrapper ] ++ deps;

  dubBuildType = "debug";

  doCheck = true;

  checkPhase = ''
    dub test --skip-registry=all "''${dubFlags[@]}" ''${dubTestFlags[@]}
  '';

  dubTestFlags = [
    "--"
    "-e"
    excludedTests
  ];

  installPhase = ''
    runHook preInstall
    install -Dm755 ./build/${pname} -t $out/bin/
    runHook postInstall
  '';

  # Installed in postInstall rather than postFixup so that `wrapProgram` below
  # (which runs in postFixup and touches only ${pname}) never wraps the stub.
  postInstall = ''
    install -Dm755 ${deprecationStub} $out/bin/mcl
  '';

  dontStrip = true;

  postFixup = ''
    wrapProgram $out/bin/${pname} \
      --prefix PATH : "${lib.makeBinPath deps}" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath deps}"
  '';

  meta = {
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = pname;
  };
}
