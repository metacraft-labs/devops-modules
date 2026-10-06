top@{ ... }:
{
  # Runner-Fleet-M3-ARM-Wave MA11 — gate `t_garm_macos_pools_supported`
  # (the nixos-modules half; the infra half is
  # infra/checks/t_garm_macos_pools_supported.sh).
  #
  # WHAT IS UNDER TEST
  #
  #   GARM's OWN pool-creation parameter gate,
  #   `Runner.appendTagsToCreatePoolParams()` — the function that produced the
  #   live `error fetching pool params: invalid OS type macos` on
  #   high-mem-server. The real `params.CreatePoolParams` goes into the real
  #   method; nothing about the allow-list is re-implemented. The method is
  #   unexported, so the test is an INTERNAL one (package runner), which is
  #   what makes it a test of the real refusal rather than of a re-derived
  #   predicate: an external test could only reach `IsSupportedOSType`, a map
  #   lookup that would keep passing even if the caller stopped consulting it.
  #
  #   No mocks. `appendTagsToCreatePoolParams` touches no store, no forge and
  #   no provider behaviour, so there is no boundary worth faking; the only
  #   hand-built value is the provider map, whose keys are all the method reads.
  #
  # THE NEGATIVE CONTROL
  #
  #   The same test file runs against two trees built from the SAME upstream
  #   source: the one this repo ships, and one identical except that
  #   `packages/garm/patches/allow-macos-pools.patch` is left out. The two
  #   macOS assertions must FAIL on the control — and fail with the defect's
  #   own words, `invalid OS type macos` — while the four assertions guarding
  #   properties the patch must NOT change (linux/windows still accepted, an
  #   unknown OS still rejected, the architecture allow-list undisturbed, the
  #   provider check still reached) pass on BOTH. That last set is what proves
  #   the control run fails because the pool path refuses macOS rather than
  #   because the file did not build.
  #
  # WHY THE TWO RUNS ARE `garm.overrideAttrs` AND NOT A BARE `runCommand`
  #
  #   The `runner` package links cgo (go-sqlite3 pulls in libresolv and, on
  #   Darwin, CoreFoundation/Security). Only the package's OWN build
  #   environment has those wired up — a `runCommand` with `stdenv.cc` fails to
  #   link with `ld: library not found for -lresolv` on aarch64-darwin. Running
  #   inside `garm.overrideAttrs` is also the shape this repo's existing macOS
  #   gate uses (checks/garm-macos-runner-install-wrapper.nix).
  #
  #   The two derivations only PRODUCE logs — neither asserts, and the control
  #   deliberately tolerates a failing `go test`. Every assertion lives in
  #   t_garm_macos_pools_supported.sh, so there is exactly one place to read.
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    {
      checks = {
        t_garm_macos_pools_supported =
          let
            garm = self'.packages.garm;

            patchUnderTest = ../packages/garm/patches/allow-macos-pools.patch;

            # The control's patch list: the same tree with ONLY the patch under
            # test removed. If that list ever stops containing the patch,
            # `builtins.filter` silently yields the same tree and the control
            # stops controlling — so assert the removal removed something.
            controlPatches = builtins.filter (p: p != patchUnderTest) garm.patches;
            assertedControlPatches =
              assert lib.assertMsg (builtins.length controlPatches == builtins.length garm.patches - 1)
                "garm-macos-pools-supported: allow-macos-pools.patch is not in packages/garm/default.nix `patches`, so the negative control would be identical to the patched tree";
              controlPatches;

            # The tags packages/garm/default.nix builds the daemon with, plus
            # `testing`, which is what gates GARM's own test files.
            goTags = "testing osusergo netgo sqlite_omit_load_extension";

            testFile = ./garm/macos_pool_ostype_test.go;

            runFilter =
              "^("
              + lib.concatStringsSep "|" [
                "TestMacOSPoolOSTypeAccepted"
                "TestMacOSIsSupportedOSType"
                "TestLinuxAndWindowsPoolsStillAccepted"
                "TestUnknownOSTypeStillRejected"
                "TestUnsupportedArchStillRejected"
                "TestUnknownProviderStillRejected"
              ]
              + ")$";

            # One `go test` run over the package, in garm's own build
            # environment. `|| true` is what lets the CONTROL derivation build
            # at all: its job is to record how the unpatched tree behaves, and
            # the shell gate decides whether that is the expected failure.
            mkRun =
              { name, patches }:
              garm.overrideAttrs (_old: {
                pname = name;
                inherit patches;
                doCheck = true;
                checkPhase = ''
                  runHook preCheck
                  cp ${testFile} runner/macos_pool_ostype_test.go
                  go test -tags "${goTags}" -count=1 -timeout 600s -v \
                    -run '${runFilter}' ./runner/ >"$NIX_BUILD_TOP/gate.log" 2>&1 || true
                  cat "$NIX_BUILD_TOP/gate.log"
                  runHook postCheck
                '';
                # Carry the log and the source-level evidence out of the build.
                postInstall = ''
                  mkdir -p "$out/share/${name}"
                  cp "$NIX_BUILD_TOP/gate.log" "$out/share/${name}/gate.log"
                  cp runner/types.go "$out/share/${name}/types.go"
                  cp vendor/github.com/cloudbase/garm-provider-common/params/params.go \
                     "$out/share/${name}/provider-common-params.go"
                '';
              });

            patchedRun = mkRun {
              name = "garm-macos-pool-gate-patched";
              patches = garm.patches;
            };
            controlRun = mkRun {
              name = "garm-macos-pool-gate-control";
              patches = assertedControlPatches;
            };
          in
          pkgs.runCommand "t_garm_macos_pools_supported"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
                pkgs.gnugrep
              ];

              GATE_PATCHED_DIR = "${patchedRun}/share/garm-macos-pool-gate-patched";
              GATE_CONTROL_DIR = "${controlRun}/share/garm-macos-pool-gate-control";

              meta.description = "MA11 gate: GARM's pool path accepts os_type=macos (with negative control)";
            }
            ''
              set -o pipefail
              bash ${./t_garm_macos_pools_supported.sh} 2>&1 | tee gate.log
              mkdir -p "$out"
              cp gate.log "$out/result"
            '';
      };
    };
}
