{ inputs, ... }:
{
  flake.modules.flake.git-hooks =
    {
      self,
      config,
      lib,
      ...
    }:
    let
      # Entering repo A's devShell while standing in repo B installs A's hook
      # config into B: upstream resolves its target as
      # `git rev-parse --show-toplevel` (the CWD's repo, not the flake's) and
      # replaces an existing `.pre-commit-config.yaml` SYMLINK without question.
      # It cost metacraft-labs/infra a day of silently running REPROBUILD's hooks
      # instead of prettier/nixfmt/editorconfig. See lib/git-hooks-repo-guard.nix.
      repoGuard = import ../lib/git-hooks-repo-guard.nix {
        expectedFlakeNixHash = builtins.hashFile "sha256" (self + "/flake.nix");
      };

      binCfg = config.mcl.gitHooks.committedBinaries;
    in
    {
      imports = [
        # Import git-hooks flake-parts module
        # docs: https://flake.parts/options/git-hooks-nix
        inputs.git-hooks-nix.flakeModule
      ];

      # THE OPT-OUT MECHANISM IS NAMED `mcl.gitHooks.committedBinaries`.
      #
      # Large binaries and `.ct` recordings are banned everywhere by DEFAULT.
      # A repo that needs an exception must SAY SO, in its own flake, by setting
      # an option below. Silence yields the strict behaviour — that is the whole
      # point of expressing this as options with strict defaults rather than as
      # hooks a repo opts *into*: the previous arrangement made the ban a thing
      # you had to remember, and 6 of 147 repos ended up committing `.ct`.
      #
      # Declared, not achieved by omission. A reader of a consuming flake can
      # see the exception and ask why; there is no way to get the exception by
      # simply failing to mention the subject.
      options.mcl.gitHooks.committedBinaries = {
        maxKB = lib.mkOption {
          type = lib.types.ints.positive;
          default = 1024;
          description = ''
            Size ceiling, in KB, for files NEWLY ADDED by a commit.

            THIS IS THE ONE PLACE THE THRESHOLD IS WRITTEN. codetracer-specs'
            Repo-Requirements.md §1.4 deliberately names this option instead of
            restating a number, so the requirement and the enforcement cannot
            drift apart.

            Note that upstream `check-added-large-files` defaults to 500 KB, so
            this is a deliberate loosening to the 1 MB the requirements doc
            asks for, not a restatement of the tool's own default.
          '';
        };

        largeFileExceptions = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "^fixtures/mainnet-blocks/" ];
          description = ''
            Regexes exempted from the size ceiling.

            THE INTENDED USE IS IMMUTABLE BLOCKCHAIN *INPUT* DATA in a
            dedicated fixtures repo. Chain data is genuinely large and genuinely
            immutable, which is the one concession the policy makes.

            Recordings DERIVED from that data do not belong here: a derived
            artefact goes stale against the code that produced it, and the
            remedy is to record it on the fly in the test, not to exempt it.
          '';
        };

        allowCommittedCtRecordings = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Permit `*.ct` / `*.ct/` recordings to be added by a commit.

            EXACTLY ONE REPO IS SUPPOSED TO SET THIS:
            `codetracer-example-recordings`, whose entire purpose is to be the
            curated home for example recordings.

            Everywhere else a test that needs a recording RECORDS IT ON THE FLY,
            so it cannot go stale against the recorder that produced it. A
            committed recording is a snapshot of a recorder version nobody is
            tracking; when it drifts, the failure surfaces as a confusing
            content mismatch rather than as "the recorder changed".
          '';
        };
      };

      config = {
        perSystem =
          { config, pkgs, ... }:
          let
            # Refuse `.ct` recordings that a commit ADDS.
            #
            # WHY THIS HOOK EXISTS SEPARATELY FROM THE SIZE CEILING.
            # `check-added-large-files` cannot express this rule. Measured in
            # codetracer at 547497aa: of its 20 tracked `.ct` files, 19 are
            # between 36 KB and 516 KB, i.e. UNDER the 1 MB ceiling, and only
            # `nginx.ct` (2.09 MB) exceeds it. A size gate would wave through 19
            # of 20. The objection to a committed recording is not that it is
            # big, it is that it is DERIVED and therefore goes stale; size is a
            # proxy that happens not to correlate.
            #
            # WHY IT CHECKS ADDED FILES ONLY, exactly like the size ceiling.
            # `git diff --staged --diff-filter=A` is the same set
            # `check-added-large-files` intersects against, and for the same
            # reason: this ban has to be switchable on in repos that ALREADY
            # carry committed recordings (measured: blocktracer 55,
            # codetracer-wasm-recorder 26, codetracer 20) without making their
            # every subsequent commit unlandable. New recordings are refused;
            # the existing ones are a separate cleanup with its own sequencing.
            # If this hook fired on modifications it would be a flag day, and a
            # flag day across 147 repos does not get rolled out, it gets
            # reverted.
            banAddedCtRecordings = pkgs.writeShellApplication {
              name = "ban-added-ct-recordings";
              runtimeInputs = [ pkgs.git ];
              text = ''
                # Files this commit ADDS (status A). Anything else that the hook
                # was handed is a pre-existing recording being modified, which is
                # out of scope — see the Nix comment above this script.
                added_list="$(git diff --staged --name-only --diff-filter=A || true)"

                offenders=()
                for candidate in "$@"; do
                  while IFS= read -r added; do
                    [ -n "$added" ] || continue
                    if [ "$added" = "$candidate" ]; then
                      offenders+=("$candidate")
                      break
                    fi
                  done <<< "$added_list"
                done

                if [ "''${#offenders[@]}" -eq 0 ]; then
                  exit 0
                fi

                echo 1>&2 "REFUSED: this commit adds CodeTracer recording(s):"
                for offender in "''${offenders[@]}"; do
                  echo 1>&2 "  $offender"
                done
                echo 1>&2 ""
                echo 1>&2 "Recordings are DERIVED artefacts and may not be committed here."
                echo 1>&2 "A committed recording pins a recorder version that nothing tracks,"
                echo 1>&2 "so it silently goes stale and then fails as a content mismatch"
                echo 1>&2 'rather than as "the recorder changed".'
                echo 1>&2 ""
                echo 1>&2 "Instead: have the test RECORD IT ON THE FLY."
                echo 1>&2 ""
                echo 1>&2 "Exactly one repository is allowed to commit recordings —"
                echo 1>&2 "codetracer-example-recordings — and it declares that by setting"
                echo 1>&2 ""
                echo 1>&2 "  mcl.gitHooks.committedBinaries.allowCommittedCtRecordings = true;"
                echo 1>&2 ""
                echo 1>&2 "Do not set that here to make this message go away."
                exit 1
              '';
            };
          in
          {
            devShells.pre-commit =
              let
                inherit (config.pre-commit.settings) enabledPackages package configFile;
              in
              pkgs.mkShell {
                packages = enabledPackages ++ [ package ];
                # Was an unconditional `ln -fvs` into $PWD — the same hijack
                # as upstream's, but without even its regular-file check.
                shellHook = ''
                  ${repoGuard}
                  if _mcl_hooks_same_repo; then
                    ln -fvs ${configFile} .pre-commit-config.yaml
                  else
                    _mcl_hooks_explain_skip
                  fi
                  echo "Running Pre-commit checks"
                  echo "========================="
                '';
              };

            # impl: https://github.com/cachix/git-hooks.nix/blob/master/flake-module.nix
            pre-commit = {
              # Disable `checks` flake output
              check.enable = false;

              # Enable commonly used formatters
              settings = {
                # Use Rust-based alternative to pre-commit:
                # https://github.com/j178/prek
                package = pkgs.prek;

                excludes = [ "^.*\.age$" ];

                hooks = {
                  # MANDATORY, WORKSPACE-WIDE: no large binaries, no recordings.
                  # Configured through `mcl.gitHooks.committedBinaries` — see the
                  # options block near the top of this file for what each knob
                  # means and which single repo is supposed to use which.
                  #
                  # `enforce-all` is deliberately NOT passed. Upstream
                  # intersects its candidate set with
                  # `git diff --staged --diff-filter=A` (verified in
                  # pre-commit-hooks 6.0.0, check_added_large_files.py +
                  # util.added_files), so turning this on in a repo that already
                  # carries large blobs does NOT retroactively fail — it only
                  # blocks new ones. That property is what makes a 147-repo
                  # rollout safe, so do not add `--enforce-all` to "tighten" it.
                  #
                  # `mkDefault` on `args`, not a bare list: git-hooks.nix types
                  # `args` as `listOf str`, whose merge is CONCATENATION. A
                  # plain list here would append to a consumer's own
                  # `--maxkb=1200` and leave argparse to take whichever came
                  # last — a silently repo-dependent threshold. At default
                  # priority the consumer's definition wins outright instead,
                  # which is the intended "declared exception" semantics.
                  # (Measured: 6 consumers already pass their own --maxkb.)
                  check-added-large-files = {
                    enable = lib.mkDefault true;
                    args = lib.mkDefault [ "--maxkb=${toString binCfg.maxKB}" ];
                    excludes = binCfg.largeFileExceptions;
                  };

                  ban-added-ct-recordings = {
                    enable = lib.mkDefault (!binCfg.allowCommittedCtRecordings);
                    name = "ban added .ct recordings";
                    description = "Refuse CodeTracer recordings added by a commit";
                    entry = "${banAddedCtRecordings}/bin/ban-added-ct-recordings";
                    # Both shapes: a single-file container (`foo.ct`) and a
                    # directory one (`foo.ct/payload`). Measured, these are not
                    # interchangeable — every `.ct` in codetracer is a FILE, so
                    # codetracer's own `"\\.ct/"` exclude pattern matches zero
                    # of its 20 recordings. A rule written with only one shape in
                    # mind is a rule that does not fire.
                    files = "\\.ct($|/)";
                    types = [ "file" ];
                  };

                  # Basic whitespace formatting
                  end-of-file-fixer.enable = true;
                  editorconfig-checker = {
                    enable = true;
                    excludes = [
                      "^checks/garm-provider-vmharness-protocol\.nix$"
                      "^checks/garm-provider-remote\.nix$"
                      "^checks/t_ephemeral_runner_security_and_metrics\.sh$"
                      "^checks/t_incus_linux_autoscale_and_harden\.sh$"
                      "^packages/garm-provider-vmharness/src/"
                    ];
                  };

                  # *.nix formatting
                  nixfmt.enable = true;

                  # *.tf and *.tftest.hcl formatting (skips Terranix-generated .tf.json)
                  terraform-format = {
                    enable = true;
                    name = "terraform-format";
                    description = "Format Terraform/OpenTofu HCL files";
                    entry = "${pkgs.opentofu}/bin/tofu fmt";
                    types = [ "file" ];
                    files = "\\.(tf|tftest\\.hcl)$";
                  };

                  # *.{js,jsx,ts,tsx,css,html,md,json} formatting
                  prettier = {
                    enable = true;
                    args = [
                      "--check"
                      "--list-different=false"
                      "--log-level=warn"
                      "--ignore-unknown"
                      "--write"
                    ];
                  };
                };
              };
            };
          };
      };
    };
}
