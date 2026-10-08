{ ... }:
{
  # t_garm_install_script_template_fixtures: the provider's cached-runner
  # version guard is tested against GARM's REAL runner-install templates, kept
  # as fixtures in garm-provider-vmharness (internal/provider/testdata/
  # garm-upstream). Those are the install-script wrappers GARM >= 0.2 hands the
  # provider as `runner_install_template`, and the `github_linux` /
  # `github_windows` system templates GARM serves at
  # "$METADATA_URL/install-script/". The guard is spliced in at anchors in that
  # text, so a GARM bump that changes it must refresh the fixtures and re-run
  # the guard tests (t_garm_provider_vmharness_windows_toolchain). This check
  # fails when any fixture is no longer byte-identical to the packaged GARM
  # source (patches applied; a missing final newline aside).
  perSystem =
    { self', pkgs, ... }:
    {
      checks.t_garm_install_script_template_fixtures =
        let
          garmSource = pkgs.applyPatches {
            name = "garm-source-patched";
            inherit (self'.packages.garm) src patches;
          };
          fixtures = ../packages/garm-provider-vmharness/src/internal/provider/testdata/garm-upstream;
        in
        pkgs.runCommand "t_garm_install_script_template_fixtures" { } ''
          status=0
          for f in linux_wrapper.tmpl windows_wrapper.tmpl github_linux_userdata.tmpl github_windows_userdata.tmpl; do
            # Compared up to a final newline: GARM's github_windows template
            # ends without one, which the repo's end-of-file-fixer hook adds to
            # the fixture. Every other byte must match.
            if cmp -s <(sed -e '$a\' "${garmSource}/internal/templates/userdata/$f") <(sed -e '$a\' "${fixtures}/$f"); then
              echo "ok: $f matches the packaged GARM source"
            else
              echo "DRIFT: $f differs from the packaged GARM source; refresh" >&2
              echo "  packages/garm-provider-vmharness/src/internal/provider/testdata/garm-upstream/$f" >&2
              echo "  and re-check the cached-runner version guard anchors against it" >&2
              status=1
            fi
          done
          [ "$status" -eq 0 ]
          touch "$out"
        '';
    };
}
