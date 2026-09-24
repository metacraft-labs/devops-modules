# LAYER 2 — the MCL STANDARD HOOK SET, named `mcl-standard-hooks`.
#
# This is the opinionated set Metacraft Labs repositories run in every project.
# It is house policy, not a universal truth, and a repo adopts it BY NAMING IT
# rather than by enumerating hooks:
#
#     pre-commit.settings.hooks = mclStandardHooks { inherit pkgs lib; src = …; };
#
# `metacraft-dev-guidelines/policies/repo-requirements.md` § 4 requires this
# set by this name. The name is the contract; the membership below can grow
# without every consuming repo having to be edited, which is the entire reason
# the list is named rather than copied.
#
# The same set is ALSO published as a portable pre-commit config fragment at
# `git-hooks/mcl-standard-hooks.yaml`, for the repos that cannot consume a
# flake — see that file's header for why both exist and which is canonical for
# whom.
{
  pkgs,
  lib,
  src,
  maxKB ? 1024,
  largeFileExceptions ? [ ],
  allowCommittedCtRecordings ? false,
  editorconfigExcludes ? [ ],
}:
let
  hooks = import ./hooks.nix {
    inherit
      pkgs
      lib
      src
      maxKB
      largeFileExceptions
      editorconfigExcludes
      ;
  };
in
{
  # --- The committed-binaries tier. Mandatory, strict by default. ---------
  #
  # Both of these act on files a commit ADDS, never on files already tracked,
  # so adopting the set in a repo that already carries large blobs or
  # recordings does not retroactively fail it. That is what makes this
  # adoptable repo-by-repo instead of needing a flag day.
  inherit (hooks) check-added-large-files;

  ban-added-ct-recordings = hooks.ban-added-ct-recordings // {
    # The ONLY way to get the exception is to declare it. Silence yields the
    # strict behaviour — that is the whole point of expressing this as an
    # option with a strict default rather than as a hook a repo opts *into*:
    # the previous arrangement made the ban a thing you had to remember, and
    # 6 of 147 repos ended up committing `.ct`.
    enable = lib.mkDefault (!allowCommittedCtRecordings);
  };

  # --- Hygiene ------------------------------------------------------------
  inherit (hooks)
    end-of-file-fixer
    editorconfig-checker
    nixfmt
    terraform-format
    prettier
    ;
}
