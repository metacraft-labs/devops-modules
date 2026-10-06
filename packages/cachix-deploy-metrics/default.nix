{
  lib,
  buildDubPackage,
  pkg-config,
  openssl,
  zlib,
  ...
}:
buildDubPackage rec {
  pname = "cachix-deploy-metrics";
  version = "unstable";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (
      file:
      builtins.any file.hasExt [
        "d"
        "sdl"
        "json"
      ]
    ) ./.;
  };
  dubLock = ./dub.lock.json; # Auto generated with `dub-to-nix`.

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 ./build/${pname} $out/bin/${pname}
    runHook postInstall
  '';

  nativeBuildInputs = [
    pkg-config
  ];

  buildInputs = [
    openssl
    zlib
  ];

  meta.mainProgram = pname;
}
