{ ... }:
{
  # Runner-Fleet-M3-ARM-Wave MA0 gates:
  #   t_vmharness_image_is_honoured
  #   t_vmharness_create_fails_on_dead_guest
  #
  # WHY THESE ARE SEPARATE FROM t_garm_provider_vmharness_backend
  #
  #   `checks/garm-provider-vmharness-backend.nix` runs the WHOLE
  #   `./internal/backend` suite, so these tests already execute there. That is
  #   coverage, not a gate: a campaign gate has to name the regression it
  #   guards so a failure in CI says which defect came back, and so an operator
  #   who greps the milestone's gate name lands on the assertions rather than on
  #   a directory-wide `go test`. Both checks below select exactly the tests the
  #   gate text describes, and both are cheap (no hypervisor, no network — the
  #   provider is driven against a shell-script mock vm-harness).
  #
  # WHAT THE GATE TEXT ASKS FOR, AND WHERE EACH ASSERTION LIVES
  #
  #   t_vmharness_image_is_honoured has three assertions, and they do not all
  #   live in one language — the defect spanned the Go provider and the Nim
  #   harness, so a single test binary covering all three does not exist:
  #
  #     (a) the local-exec provider passes the configured image on the flag
  #         vm-harness actually resolves from
  #           -> internal/backend/vmharness_test.go,
  #              TestVMHarnessImageIsHonouredLocalExec*
  #     (b) the remote RPC recipe does the same for every non-incus target
  #           -> internal/backend/remote_test.go,
  #              TestVMHarnessImageIsHonouredRemoteRecipe*
  #     (c) a registry-constructed tart backend with no image configured RAISES
  #         rather than substituting a default
  #           -> vm-harness (Nim), tests/unit/t_vmharness_image_is_honoured.nim,
  #              run by `just test` there.
  #
  #   (a) and (b) are what this check runs. (c) is deliberately NOT restated
  #   here: asserting the Nim behaviour from Go would only re-encode an
  #   assumption. The checkPhase prints where (c) is proven so a reader of CI
  #   output is never left believing this check covered all three.
  #
  # t_vmharness_create_fails_on_dead_guest is entirely provider-side: a
  # vm-harness that exits during baseline validation must make Create fail with
  # the child's exit status and log tail, and persist no instance state. Before
  # the fix, Create returned success as soon as cmd.Start() did, so a guest that
  # died on arrival was recorded as healthy; GARM then waited out the 30-minute
  # bootstrap timeout, reaped it and created another, ~3.5 times an hour, with
  # `garm_runner_errors_total` never incrementing. That silence is the property
  # this gate exists to prevent, so it is named separately from the image gate
  # even though both tests sit in the same Go package.
  #
  # `go test -run <re>` EXITS 0 WHEN THE REGEX MATCHES NOTHING. A gate that
  # selects tests by name therefore has to prove it selected some, or a rename
  # turns it into a permanent silent pass — the exact failure mode MA6 is about,
  # one layer down. Both checkPhases below assert a minimum number of top-level
  # PASS lines, so dropping or renaming a covered test breaks the gate loudly.
  perSystem =
    { self', ... }:
    let
      goTestGate =
        {
          name,
          pattern,
          minTests,
          preamble ? "",
        }:
        self'.packages.garm-provider-vmharness.overrideAttrs (_old: {
          doCheck = true;
          checkPhase = ''
            runHook preCheck
            ${preamble}
            # Redirect rather than pipe into tee: a pipeline reports tee's
            # status, so a FAILING go test would be swallowed on any stdenv
            # that does not set `pipefail`.
            if ! go test -v ./internal/backend -run ${pattern} > gate.log 2>&1; then
              cat gate.log >&2
              echo "${name}: FAIL — go test reported a failure (above)." >&2
              exit 1
            fi
            cat gate.log
            passed=$(grep -c '^--- PASS: ' gate.log || true)
            echo "${name}: ''${passed} top-level test(s) matched ${pattern}"
            if [ "''${passed}" -lt ${toString minTests} ]; then
              echo "${name}: FAIL — expected at least ${toString minTests} matching tests," >&2
              echo "  got ''${passed}. \`go test -run\` exits 0 when it matches nothing," >&2
              echo "  so a renamed or deleted test would otherwise pass this gate silently." >&2
              exit 1
            fi
            runHook postCheck
          '';
        });
    in
    {
      checks.t_vmharness_image_is_honoured = goTestGate {
        name = "t_vmharness_image_is_honoured";
        pattern = "'TestVMHarnessImageIsHonoured'";
        # (a) local-exec passes / local-exec refuses empty;
        # (b) remote carries / remote keeps the incus alias / remote orders the
        #     image pair ahead of the Incus capability grants / remote omits.
        minTests = 6;
        preamble = ''
          echo "t_vmharness_image_is_honoured: assertions (a) local-exec and (b) remote recipe."
          echo "  Assertion (c) — a registry-constructed tart backend with no image RAISES —"
          echo "  is Nim-side and is proven by vm-harness"
          echo "  tests/unit/t_vmharness_image_is_honoured.nim (\`just test\` in that repo)."
        '';
      };

      checks.t_vmharness_create_fails_on_dead_guest = goTestGate {
        name = "t_vmharness_create_fails_on_dead_guest";
        pattern = "'TestVMHarnessCreateFailsOnDeadGuest'";
        minTests = 1;
      };
    };
}
