# Explicit counterpart to the shared dev-shell installer. Importing this
# function does not install hooks or change a shellHook.
{
  pkgs,
  preCommit,
  expectedFlakeNixHash,
  # The matching Repro CLI (a package, or null). When given, the installer
  # exports REPROBUILD_REPRO to it. When null, it exports the caller's
  # REPROBUILD_REPRO, or else the `repro` found on PATH, as an absolute path.
  # The guard refuses to run without an absolute constructor, so an empty
  # lookup fails the installation closed.
  repro ? null,
}:
let
  # Consume git-hooks.nix's declared installation stages, including its legacy
  # aliases and default. Manual is not a Git hook. There is no parallel
  # consumer-maintained list that could silently omit a configured stage.
  stages = preCommit.config.installStages;
  normalizeStage =
    stage:
    if stage == "commit" then
      "pre-commit"
    else if stage == "merge-commit" then
      "pre-merge-commit"
    else if stage == "push" then
      "pre-push"
    else
      stage;
  nativeHookTypes =
    if stages == [ ] then
      [ "pre-commit" ]
    else
      pkgs.lib.unique (map normalizeStage (builtins.filter (stage: stage != "manual") stages));
  repoGuard = import ./git-hooks-repo-guard.nix { inherit expectedFlakeNixHash; };
  handoff = import ./git-hooks-reprobuild-handoff.nix { git = "${pkgs.git}/bin/git"; };
  nativeHooks = pkgs.runCommand "mcl-native-hooks" { nativeBuildInputs = [ pkgs.git ]; } ''
    export HOME="$TMPDIR/home" PRE_COMMIT_HOME="$TMPDIR/pre-commit"
    export GIT_CONFIG_GLOBAL="$TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
    mkdir -p "$HOME" "$PRE_COMMIT_HOME" fixture
    : > "$GIT_CONFIG_GLOBAL"
    cd fixture
    git init --template= >/dev/null
    mkdir -p .git/hooks "$out"
    ln -s ${preCommit.config.configFile} ${preCommit.config.configPath}
    ${pkgs.lib.concatMapStringsSep "\n" (name: ''
      ${pkgs.lib.getExe preCommit.config.package} install -c ${preCommit.config.configPath} -t ${pkgs.lib.escapeShellArg name}
      install -m 0755 .git/hooks/${name} "$out/${name}"
    '') nativeHookTypes}
  '';
  installer = pkgs.writeShellScript "mcl-native-hook-installer" preCommit.shellHook;
in
assert builtins.all (
  name:
  builtins.elem name [
    "commit-msg"
    "post-checkout"
    "post-commit"
    "post-merge"
    "post-rewrite"
    "pre-commit"
    "pre-merge-commit"
    "pre-push"
    "pre-rebase"
    "prepare-commit-msg"
  ]
) nativeHookTypes;
pkgs.writeShellApplication {
  name = "mcl-install-own-hooks";
  runtimeInputs = [
    pkgs.git
    pkgs.coreutils
    pkgs.python3
    pkgs.nix
    preCommit.config.package
  ];
  text = ''
    ${
      if repro == null then
        ''
          REPROBUILD_REPRO="''${REPROBUILD_REPRO:-$(command -v repro || true)}"
        ''
      else
        ''
          REPROBUILD_REPRO=${pkgs.lib.escapeShellArg "${repro}/bin/repro"}
        ''
    }
    export REPROBUILD_REPRO
    ${repoGuard}
    ${handoff}
    if ! _mcl_hooks_same_repo; then
      _mcl_hooks_explain_skip
      exit 1
    fi
    root="$(git rev-parse --show-toplevel)"
    receipt="$(mktemp)"
    trap 'rm -f "$receipt"' EXIT
    python3 ${./git-hooks-explicit-guard.py} "$root" ${nativeHooks} before "$receipt" \
      ${pkgs.lib.escapeShellArg preCommit.config.configPath} ${preCommit.config.configFile}
    ${pkgs.bash}/bin/bash ${installer}
    _mcl_hooks_reprobuild_handoff
    python3 ${./git-hooks-explicit-guard.py} "$root" ${nativeHooks} after "$receipt" \
      ${pkgs.lib.escapeShellArg preCommit.config.configPath} ${preCommit.config.configFile}
  '';
}
