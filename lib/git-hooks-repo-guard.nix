# Shell snippet: "am I standing in the repository this flake belongs to?"
#
# WHY THIS EXISTS.
#
# Entering repo A's devShell while standing in repo B installs A's hook config
# into B. Upstream git-hooks.nix resolves its install target as
#
#   GIT_WC=`git rev-parse --show-toplevel`      # the CWD's repo, not the flake's
#
# and then, if `.pre-commit-config.yaml` there is a SYMLINK pointing somewhere
# else, `unlink`s it and installs its own. It refuses only for a regular file
# ("Refusing to install because of an existing config"), on the assumption that a
# symlink must be its own stale one. Cross-repo is not in its model.
#
# That cost a full day in metacraft-labs/infra, whose checkout carried
#
#   .pre-commit-config.yaml -> /nix/store/...-pre-commit-config.json
#       hooks: just-lint, suite-case-counts, vacuous-test-cases
#
# i.e. REPROBUILD's hooks. Every local commit in infra was therefore gated by
# another repo's checks and never by prettier/nixfmt/editorconfig. Six
# formatting-drift escapes to `live` followed across four rounds, each one
# stopping fleet deployment, since the deploy publish is gated on `lint`.
#
# THE SIGNAL. A flake knows its own `flake.nix`; compare it against the one in
# the checkout we are standing in. Equal means same repo. It needs no per-repo
# configuration and it fails SAFE: anything it cannot establish (no git, no
# flake.nix, unreadable file) counts as "not my repo", so the worst case is
# skipping installation rather than hijacking someone else's.
#
# It is a plain function rather than a `flake.lib` export on purpose:
# checks/pre-commit.nix is imported by more than one module, and two
# equal-priority definitions of the same flake output collide
# ("Use `lib.mkForce`..."). A function has no such problem.
#
# KNOWN FALSE NEGATIVE, stated so the message is not mystifying when it happens:
# the hash is taken from the flake source Nix evaluated, so if you edit
# `flake.nix` and re-enter the shell in the same breath, the worktree copy can
# briefly differ from the evaluated one and the guard will say "different
# repository" about your own repo. Re-entering resolves it. The alternative —
# trusting the CWD — is what caused the incident, so erring this way is
# deliberate: a confusing message costs a minute, a hijacked hook config cost a
# day.
{ expectedFlakeNixHash }:
''
  _mcl_hooks_same_repo() {
    command -v git >/dev/null 2>&1 || return 1
    local wc
    wc="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ -n "$wc" ] || return 1
    # A checkout with no flake.nix is not one we can identify; do not claim it.
    [ -f "$wc/flake.nix" ] || return 1
    local actual
    actual="$(sha256sum "$wc/flake.nix" 2>/dev/null | cut -d' ' -f1)" || return 1
    [ "$actual" = "${expectedFlakeNixHash}" ]
  }
  _mcl_hooks_explain_skip() {
    echo 1>&2 "git-hooks: NOT installing hooks here — this devShell belongs to a different repository."
    echo 1>&2 "           cwd repo:  $(git rev-parse --show-toplevel 2>/dev/null || echo '<not a git repo>')"
    echo 1>&2 "           To work on THAT repo, cd into it and enter its own devShell."
    echo 1>&2 "           (Installing would replace its .pre-commit-config.yaml with this flake's,"
    echo 1>&2 "            silently swapping which checks gate its commits.)"
  }
''
