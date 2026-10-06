{ buildDubPackage, ... }:
buildDubPackage rec {
  pname = "random-alerts";
  version = "1.0.0";
  src = ./.;
  dubLock = {
    dependencies = { };
  };
  installPhase = ''
    mkdir -p $out/bin
    install -m755 ./build/${pname} $out/bin/${pname}
  '';
  meta.mainProgram = pname;
}
