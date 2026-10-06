{
  stdenv,
  fetchurl,
  lib,
}:
stdenv.mkDerivation {
  name = "aztec";
  srcs = [
    (fetchurl {
      url = "https://install.aztec.network/.aztec-run";
      hash = "sha256-hLLneMb+RE/+btcIz/pK54Diz5N8i4tsKz+1zZatlPQ=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec";
      hash = "sha256-jEYhHpQJMzOg8Nx0AzYW6vOP4mW0TlzGd6/KDu6zQ9U=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec-up";
      hash = "sha256-8CB1s2pQzo3KiigKRmgRAKbgfb+p3YcJIDfMTdru3Uo=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec-nargo";
      hash = "sha256-9T9m/Ops1O/uYKNIaBxZ9RC+q7ADQnMjRDU4oTbSORA=";
    })
    (fetchurl {
      url = "https://install.aztec.network/aztec-wallet";
      hash = "sha256-WZvmrVWEnxVRh/zwhaTk6PWSHBD8ElgX8ivODFUUZzU=";
    })
  ];
  sourceRoot = ".";
  unpackCmd = ''
    curTrg=$(basename $(stripHash $curSrc))
    cp $curSrc $curTrg
    chmod +x $curTrg
  '';
  installPhase = ''
    mkdir -p $out/bin
    cp -r * .* $out/bin/
    mv $out/bin/aztec-run $out/bin/.aztec-run
  '';
  meta.mainProgram = "aztec";
}
