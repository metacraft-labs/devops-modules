# LAYER 1 — the individual hooks, each usable on its own.
#
# This file is a FUNCTION from configuration to a set of git-hooks.nix hook
# definitions, one attribute per hook. Nothing here assembles a list; that is
# `standard-hooks.nix` (layer 2, `mclStandardGitHooks`). The split exists so a
# consumer can take ONE hook without taking all of them:
#
#     let
#       mclHooks = import (inputs.nixos-modules + "/git-hooks/hooks.nix") {
#         inherit pkgs lib;
#         src = inputs.nixos-modules;
#       };
#     in
#     {
#       pre-commit.settings.hooks = {
#         inherit (mclHooks) ban-added-ct-recordings;   # just this one
#       };
#     }
#
# Every hook is returned at DEFAULT priority (`lib.mkDefault`) for the fields a
# consumer is likely to want to override. See the `args` note on
# `check-added-large-files` for why that is not optional.
{
  pkgs,
  lib,
  # The devops-modules (nixos-modules) source tree, so hook entries can name
  # the portable scripts that live beside this file.
  src,
  # Size ceiling, in KB, for files a commit ADDS.
  maxKB ? 1024,
  # Regexes exempted from the size ceiling.
  largeFileExceptions ? [ ],
  # Paths `editorconfig-checker` should not look at. Defaulted to the empty
  # list: an exclusion list is a property of the repo being checked, not of
  # the shared hook, so a consumer that needs one says so.
  editorconfigExcludes ? [ ],
}:
let
  python = "${pkgs.python3}/bin/python3";
  banAddedPaths = "${src}/git-hooks/mcl_git_hooks/ban_added_paths.py";
in
{
  # ---------------------------------------------------------------------
  # No large binaries added by a commit.
  # ---------------------------------------------------------------------
  #
  # `--enforce-all` is deliberately NOT passed. Upstream intersects its
  # candidate set with `git diff --staged --diff-filter=A` (verified in
  # pre-commit-hooks 6.0.0, check_added_large_files.py + util.added_files), so
  # turning this on in a repo that already carries large blobs does NOT
  # retroactively fail it — it only blocks new ones. That property is what
  # makes a 147-repo rollout safe, so do not add `--enforce-all` to "tighten"
  # it.
  #
  # `mkDefault` on `args`, not a bare list: git-hooks.nix types `args` as
  # `listOf str`, whose merge is CONCATENATION. A plain list here would append
  # to a consumer's own `--maxkb=1200` and leave argparse to take whichever
  # came last — a silently repo-dependent threshold. At default priority the
  # consumer's definition wins outright instead, which is the intended
  # "declared exception" semantics. (Measured: 6 consumers already pass their
  # own --maxkb.)
  check-added-large-files = {
    enable = lib.mkDefault true;
    args = lib.mkDefault [ "--maxkb=${toString maxKB}" ];
    excludes = largeFileExceptions;
  };

  # ---------------------------------------------------------------------
  # No CodeTracer recordings added by a commit.
  # ---------------------------------------------------------------------
  #
  # CodeTracer is used in all three workspaces this repo serves (metacraft,
  # agent-harbor, blocksense-network), so every one of them can produce `.ct`
  # files and the ban is house practice rather than a CodeTracer-repo
  # peculiarity. That is why it sits in the standard list rather than in an
  # opt-in product tier.
  #
  # The entry is `python3 <script>`, not a /nix/store shell application, so the
  # SAME implementation backs the flake path and the committed-YAML path that
  # Windows repos use. See the script's docstring for why that matters.
  #
  # `--preset ct-recordings` rather than an inline message: the refusal wording
  # and the 19-of-20 measurement that justifies the rule live in ONE place (the
  # Python module's PRESETS table), so the flake entry and the committed YAML
  # entry cannot disagree about what the rule says.
  ban-added-ct-recordings = {
    enable = lib.mkDefault true;
    name = "ban added .ct recordings";
    description = "Refuse CodeTracer recordings added by a commit";
    entry = "${python} ${banAddedPaths} --preset ct-recordings --";
    # Both shapes: a single-file container (`foo.ct`) and a directory one
    # (`foo.ct/payload`). Measured, these are not interchangeable — every
    # `.ct` in codetracer is a FILE, so codetracer's own `"\\.ct/"` exclude
    # pattern matches zero of its 20 recordings. A rule written with only one
    # shape in mind is a rule that does not fire.
    files = "\\.ct($|/)";
    types = [ "file" ];
  };

  # ---------------------------------------------------------------------
  # Whitespace / encoding hygiene.
  # ---------------------------------------------------------------------
  end-of-file-fixer.enable = lib.mkDefault true;

  editorconfig-checker = {
    enable = lib.mkDefault true;
    excludes = editorconfigExcludes;
  };

  # ---------------------------------------------------------------------
  # `*.nix` formatting.
  # ---------------------------------------------------------------------
  nixfmt.enable = lib.mkDefault true;

  # ---------------------------------------------------------------------
  # `*.tf` / `*.tftest.hcl` formatting (skips Terranix-generated `.tf.json`).
  # ---------------------------------------------------------------------
  terraform-format = {
    enable = lib.mkDefault true;
    name = "terraform-format";
    description = "Format Terraform/OpenTofu HCL files";
    entry = "${pkgs.opentofu}/bin/tofu fmt";
    types = [ "file" ];
    files = "\\.(tf|tftest\\.hcl)$";
  };

  # ---------------------------------------------------------------------
  # `*.{js,jsx,ts,tsx,css,html,md,json}` formatting.
  # ---------------------------------------------------------------------
  prettier = {
    enable = lib.mkDefault true;
    args = lib.mkDefault [
      "--check"
      "--list-different=false"
      "--log-level=warn"
      "--ignore-unknown"
      "--write"
    ];
  };
}
