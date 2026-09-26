{ inputs, ... }:
let
  # THIS repo's source tree, captured while evaluating THIS flake.
  # `inputs.self`, not the `self` module argument: flake-parts does not pass a
  # `self` arg to modules imported from `./checks`, and asking for one makes
  # the whole flake fail to evaluate with "called without required argument".
  #
  # It must not be confused with the `self` the inner module receives: that one
  # is the CONSUMER's flake (which is the point — `repoGuard` hashes the
  # consumer's `flake.nix`). The portable hook scripts live here, in
  # devops-modules, so a consumer's `self` would point at the wrong tree and the
  # `.ct` hook's entry would name a file that does not exist there.
  mclSrc = inputs.self;
in
{
  # THE FLAKE-CONSUMER ENTRY POINT.
  #
  # This module no longer holds the hook definitions. It holds the OPTIONS and
  # wires them into the MCL Standard Hook Set:
  #
  #   layer 1  git-hooks/hooks.nix          individual hooks, each usable alone
  #   layer 2  git-hooks/standard-hooks.nix `mcl-standard-hooks`, the named set
  #   here     the flake-parts module that installs layer 2 for a consumer
  #
  # The same set is published portably at `git-hooks/mcl-standard-hooks.yaml`
  # for the repos and the Windows developers that cannot consume a flake. Read
  # that file's header before assuming the Nix path is the only one.
  flake.modules.flake.git-hooks =
    {
      self,
      config,
      lib,
      flake-parts-lib,
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
      # Bound out here on purpose: inside `perSystem` the argument named
      # `config` is the PER-SYSTEM config, which shadows this one and has no
      # `mcl` attribute at all.
      editorconfigExcludes = config.mcl.gitHooks.editorconfigExcludes;
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
      # THE INSTALLATION SCRIPT CONSUMERS PUT IN THEIR shellHook.
      #
      # Use `config.mcl.gitHooks.installationScript` (per-system), not
      # upstream's `config.pre-commit.installationScript`. It is upstream's
      # script plus the two things every consumer needs and none should
      # re-implement:
      #
      #   * the same-repository guard (lib/git-hooks-repo-guard.nix), so
      #     entering this shell from another checkout cannot swap that repo's
      #     hooks;
      #   * the Reprobuild handoff (lib/git-hooks-reprobuild-handoff.nix): prek
      #     installs ITS shim in place of a Reprobuild hook dispatcher and moves
      #     the dispatcher to `<hook>.legacy`, which leaves the pre-push
      #     publication gate running only by accident. The handoff puts the
      #     dispatcher back and chains prek's shim as `<hook>.repro-local` — and
      #     makes upstream's relative `core.hooksPath` absolute, without which
      #     Git runs no hooks at all in a linked worktree.
      #
      # Without Reprobuild in the repo the handoff finds no dispatcher and does
      # nothing; prek's hooks install and run exactly as upstream leaves them.
      options.perSystem = flake-parts-lib.mkPerSystemOption {
        options.mcl.gitHooks.installationScript = lib.mkOption {
          type = lib.types.str;
          readOnly = true;
          description = ''
            Bash snippet for a devShell `shellHook`: installs the configured
            git hooks (upstream git-hooks.nix) in THIS flake's repository only,
            and hands the hook slots back to Reprobuild's dispatchers where
            present. Prefer it to `pre-commit.installationScript`.
          '';
        };
      };

      options.mcl.gitHooks = {
        committedBinaries = {
          maxKB = lib.mkOption {
            type = lib.types.ints.positive;
            default = 1024;
            description = ''
              Size ceiling, in KB, for files NEWLY ADDED by a commit.

              THIS IS THE ONE PLACE THE THRESHOLD IS WRITTEN FOR FLAKE
              CONSUMERS. metacraft-dev-guidelines' repo-requirements.md § 4
              deliberately names this option instead of restating a number, so
              the requirement and the enforcement cannot drift apart. (The
              portable `git-hooks/mcl-standard-hooks.yaml` necessarily spells
              the number out, because a YAML file cannot read a Nix option; it
              carries a comment saying so.)

              Note that upstream `check-added-large-files` defaults to 500 KB,
              so this is a deliberate loosening to the 1 MB the requirements doc
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

        editorconfigExcludes = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = ''
            Paths `editorconfig-checker` should not look at.

            An exclusion list is a property of the repo being checked, not of
            the shared hook set, so it is an option rather than a constant. It
            used to be a hard-coded list of THIS repo's paths shipped to all 7
            consumers, which is why it is called out here.
          '';
        };
      };

      config = {
        # This repo's own exclusions, declared through the option like any
        # other consumer's would be, rather than baked into the shared set.
        mcl.gitHooks.editorconfigExcludes = [
          "^checks/garm-provider-vmharness-protocol\\.nix$"
          "^checks/garm-provider-remote\\.nix$"
          "^checks/t_ephemeral_runner_security_and_metrics\\.sh$"
          "^checks/t_incus_linux_autoscale_and_harden\\.sh$"
          "^packages/garm-provider-vmharness/src/"
        ];

        perSystem =
          { config, pkgs, ... }:
          {
            mcl.gitHooks.installationScript = ''
              ${repoGuard}
              ${import ../lib/git-hooks-reprobuild-handoff.nix {
                git = lib.getExe config.pre-commit.settings.gitPackage;
              }}
              if _mcl_hooks_same_repo; then
              ${config.pre-commit.installationScript}
                _mcl_hooks_reprobuild_handoff
              else
                _mcl_hooks_explain_skip
              fi
            '';

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

              settings = {
                # Use Rust-based alternative to pre-commit:
                # https://github.com/j178/prek
                package = pkgs.prek;

                excludes = [ "^.*\.age$" ];

                # A repo opts into the house set BY NAMING IT, not by
                # enumerating hooks. Adding a hook to `mcl-standard-hooks`
                # reaches every consumer without editing any of them — which is
                # the entire reason the list is named rather than copied.
                hooks = import ../git-hooks/standard-hooks.nix {
                  inherit pkgs lib;
                  src = mclSrc;
                  inherit (binCfg) maxKB largeFileExceptions allowCommittedCtRecordings;
                  inherit editorconfigExcludes;
                };
              };
            };
          };
      };
    };
}
