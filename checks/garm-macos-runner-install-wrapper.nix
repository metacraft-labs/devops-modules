{ ... }:
let
  macOSWrapperExternalTest = builtins.toFile "macos_wrapper_external_test.go" ''
    package templates

    import (
        "context"
        "strings"
        "testing"

        commonParams "github.com/cloudbase/garm-provider-common/params"
    )

    func TestExternalMacOSRunnerInstallWrapper(t *testing.T) {
        wrapper, err := RenderRunnerInstallWrapper(
            context.Background(),
            commonParams.OSType("macos"),
            "http://garm.example.test/api/v1/metadata",
            "http://garm.example.test/api/v1/callbacks/status",
            "instance-token",
        )
        if err != nil {
            t.Fatalf("RenderRunnerInstallWrapper(macos) returned error: %v", err)
        }

        body := string(wrapper)
        for _, want := range []string{
            "#!/bin/sh",
            "BEARER_TOKEN=\"instance-token\"",
            "http://garm.example.test/api/v1/metadata",
            "$METADATA_URL/install-script/",
            "/tmp/real-install.sh",
        } {
            if !strings.Contains(body, want) {
                t.Fatalf("macOS wrapper missing %q:\n%s", want, body)
            }
        }
    }
  '';
in
{
  # PM4 macOS runner gate: GARM must be able to render the managed runner
  # install wrapper for os_type=macos. The live failure mode was accepting a
  # macOS runner-install template but then parsing only linux/windows wrapper
  # files, causing ExecuteTemplate("macos_wrapper.tmpl") to fail at runner boot.
  perSystem =
    { self', ... }:
    {
      checks.t_garm_macos_runner_install_wrapper = self'.packages.garm.overrideAttrs (_old: {
        doCheck = true;
        checkPhase = ''
          runHook preCheck
          cp ${macOSWrapperExternalTest} internal/templates/macos_wrapper_external_test.go
          go test ./internal/templates
          runHook postCheck
        '';
      });
    };
}
