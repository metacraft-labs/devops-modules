{
  stdenv,
  fetchurl,
  lib,
}:
let
  # The Aztec CLI wrapper scripts, fetched from an IMMUTABLE source: the
  # aztec-up/bin/ directory of AztecProtocol/aztec-packages at a fixed commit.
  #
  # https://install.aztec.network/<script> is unversioned and is re-published
  # in place, so fixed-output hashes against it drift (seen 2026-10-28: aztec and
  # aztec-up changed under the same URL). Commit 418f875a ("fix: shebang in aztec
  # wrapper", 2025-09-08) serves byte-for-byte the scripts this package was
  # written against: all five hashes below are the original ones, so the
  # fetched store paths are unchanged.
  # Source: https://github.com/AztecProtocol/aztec-packages/tree/418f875aae492b45f85fa799b2ce75511ffcd832/aztec-up/bin
  rev = "418f875aae492b45f85fa799b2ce75511ffcd832";
  script =
    name: hash:
    fetchurl {
      url = "https://raw.githubusercontent.com/AztecProtocol/aztec-packages/${rev}/aztec-up/bin/${name}";
      inherit hash;
    };
in
stdenv.mkDerivation {
  name = "aztec";
  srcs = [
    (script ".aztec-run" "sha256-hLLneMb+RE/+btcIz/pK54Diz5N8i4tsKz+1zZatlPQ=")
    (script "aztec" "sha256-Z3tst1Fn5dQibZzaSnXzPz3DPwY6bkiRSeilM5DZbro=")
    (script "aztec-up" "sha256-9mJWn+cj8loFkw/RhpV/y1rGapMYYTmiCiDmUJqeqdc=")
    (script "aztec-nargo" "sha256-9T9m/Ops1O/uYKNIaBxZ9RC+q7ADQnMjRDU4oTbSORA=")
    (script "aztec-wallet" "sha256-WZvmrVWEnxVRh/zwhaTk6PWSHBD8ElgX8ivODFUUZzU=")
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
