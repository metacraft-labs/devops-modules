# A `git` for git-hooks.nix's `settings.gitPackage` that makes UPSTREAM's
# installer stay out of other repositories.
#
# lib/git-hooks-repo-guard.nix explains the defect: upstream installs into
# `git rev-parse --show-toplevel` of the CURRENT DIRECTORY, so entering repo
# A's devShell from inside repo B installs A's hook config into B. The flake
# module's `mcl.gitHooks.installationScript` wraps upstream's script in that
# guard, but upstream also publishes the script UNWRAPPED, as
# `pre-commit.installationScript`, `pre-commit.shellHook` and inside
# `pre-commit.devShell`, and `inputsFrom = [ config.pre-commit.devShell ]` is
# the form most consumers copy. Those entry points are read-only options of the
# upstream module and cannot be redefined here.
#
# What every one of them DOES share is `settings.gitPackage`: upstream's
# installer starts with
#
#   if ! ${gitPackage}/bin/git rev-parse --git-dir &> /dev/null; then
#     echo "WARNING: git-hooks.nix: .git not found; skipping installation."
#
# so this `git` answers that exact question with "no" when the checkout is not
# the flake's own (same signal and same fail-safe as the repo guard). Upstream
# sends that probe's stderr to /dev/null, so what the user sees is upstream's
# ".git not found; skipping installation" warning, not the explanation printed
# here; the explanation does show when the wrapper is run by hand. Every other
# invocation, and that one inside the right repository, is the real git,
# unchanged. checks/git-hooks-same-repo-git.nix
{
  pkgs,
  git ? pkgs.gitMinimal,
  expectedFlakeNixHash,
}:
let
  repoGuard = import ./git-hooks-repo-guard.nix { inherit expectedFlakeNixHash; };
in
(pkgs.writeShellScriptBin "git" ''
  if [ "$#" -eq 2 ] && [ "$1" = rev-parse ] && [ "$2" = --git-dir ]; then
    # The guard calls `git`; it must reach the real one, not this wrapper.
    PATH="${git}/bin:${pkgs.coreutils}/bin:$PATH"
    ${repoGuard}
    if ! _mcl_hooks_same_repo; then
      _mcl_hooks_explain_skip
      exit 1
    fi
  fi
  exec ${git}/bin/git "$@"
'').overrideAttrs
  (old: {
    meta = (old.meta or { }) // {
      mainProgram = "git";
    };
  })
