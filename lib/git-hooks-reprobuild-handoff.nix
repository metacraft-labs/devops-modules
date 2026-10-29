# Shell snippet: run AFTER git-hooks.nix's installation script, so that
# installing pre-commit/prek hooks does not switch Reprobuild's hooks off.
#
# WHY THIS EXISTS.
#
# In a Reprobuild workspace each `.git/hooks/<hook>` is a Reprobuild DISPATCHER
# ("# reprobuild hook dispatcher protocol=2"). It runs the repo's own hooks,
# preserved as `<hook>.repro-local`, and then Reprobuild's managed hook,
# `<hook>.repro-managed` — for `pre-push` that is the publication gate
# (`repro check --mode=pre-push`).
#
# Upstream's installation script runs `prek uninstall -t <every hook type>` and
# then `prek install -t <each configured stage>`. `prek install` (and
# `pre-commit install`) finds the dispatcher in its way, MOVES it to
# `<hook>.legacy` ("migration mode") and writes its own shim in its place. The
# managed hook then runs only as a side effect of prek's migration chain, and
# `repro hooks ensure` has to repair the layout afterwards. Agents hit this
# repeatedly and restored the dispatchers by hand.
#
# THE HANDOFF. After the installer, for every `<hook>.legacy` that is a
# dispatcher:
#
#   * the slot holds a freshly generated pre-commit/prek shim -> chain that
#     shim as `<hook>.repro-local` (replacing a previously chained shim, which
#     is the same tool's output) and put the dispatcher back in the slot;
#   * the slot is empty -> put the dispatcher back;
#   * the slot already holds a dispatcher -> the `.legacy` copy is a stale
#     duplicate; drop it (a chained shim would otherwise run it and re-enter
#     the dispatcher);
#   * anything else (a hand-written hook in the slot, or a hand-written
#     `.repro-local` the shim would overwrite) -> touch nothing and say so;
#     `repro hooks ensure --vcs` reconciles or refuses with both paths named.
#
# STALE CHAINED SHIMS. When the installer ran in this shell entry (at least one
# dispatcher was handed back above), every hook type it installed has just been
# re-chained. A generated pre-commit/prek shim left at `<hook>.repro-local` for
# a hook type it did NOT install is the previous configuration's output: the
# stage was dropped from the config (e.g. check-added-large-files' upstream
# pre-push stage, which devops-modules removed). Kept, it runs prek for a stage
# the current config has no hooks for, and prek fails that hook ("No hooks
# found for stage") -- for pre-push, that blocked every push. Such a shim is
# removed. A hand-written `.repro-local` is never touched, and nothing is
# pruned on an entry where the installer did not run (unchanged config), since
# then nothing was re-chained and every shim is current.
#
# The result is exactly the layout `repro hooks ensure` produces, so the next
# `ensure` has nothing to do. A repository with no Reprobuild dispatcher has no
# dispatcher at `<hook>.legacy`, and this does nothing at all to it: prek's
# hooks install and run exactly as upstream leaves them.
#
# A DISPATCHER THE INSTALLER DESTROYS. The `.legacy` slot holds ONE file. When
# a second hook manager has already moved the dispatcher there -- e.g. a shell
# built from an older flake ran python `pre-commit install` -- the slot holds
# that manager's shim and `.legacy` the dispatcher. prek then moves the shim to
# `.legacy`, OVERWRITING the dispatcher, and nothing above can find it: the
# repository is left with prek in the slot, the dispatcher gone and a foreign
# shim at `.legacy` that every prek run executes in "migration mode" (python
# pre-commit then aborts every commit). Seen 2026-10-29 in devops-modules, and
# reproduced with pre-commit 4.5.1 + prek 0.3.11. So
# `_mcl_hooks_reprobuild_snapshot`, run BEFORE the installer, copies every
# dispatcher it finds (in the slot, or at `.legacy` behind a generated shim)
# aside, and the handoff restores from that copy any dispatcher the installer
# destroyed -- with the same chaining and the same refusals as above. Once the
# dispatcher is back, a generated pre-commit/prek shim left at `.legacy` is
# removed: it is regenerable, and chained it re-enters migration mode. A
# hand-written `.legacy` is never touched.
#
# core.hooksPath. Upstream finishes with
#   git config --local core.hooksPath "<common dir relative to the worktree>/hooks"
# which in a main checkout is `.git/hooks`: RELATIVE. Git resolves a relative
# hooksPath against the worktree it is running in, and in a linked worktree
# `.git` is a file, so `.git/hooks` does not exist there and Git runs NO hooks
# in any linked worktree of the repository — neither prek's nor Reprobuild's.
# The value names the common hooks directory, so it is rewritten as that
# absolute path, which every worktree resolves identically.
#
# Nothing here fails the shell: a devShell that refuses to open because a hook
# file could not be moved is worse than the drift, which `repro health`
# reports with its own remedy.
{ git }:
''
  _mcl_hooks_snapshot_dir=""

  _mcl_hooks_is_dispatcher() { grep -q 'reprobuild hook dispatcher' "$1" 2>/dev/null; }
  _mcl_hooks_is_generated() { grep -Eq '^# File generated by (pre-commit|prek):' "$1" 2>/dev/null; }

  # Before the installer: copy every Reprobuild dispatcher aside (see the
  # header, "A DISPATCHER THE INSTALLER DESTROYS").
  _mcl_hooks_reprobuild_snapshot() {
    local common hooks slot name
    _mcl_hooks_snapshot_dir=""
    common="$(${git} rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
    [ -n "$common" ] && [ -d "$common/hooks" ] || return 0
    hooks="$common/hooks"
    for slot in "$hooks"/*; do
      [ -f "$slot" ] || continue
      name="$(basename "$slot")"
      case "$name" in *.*) continue ;; esac
      if _mcl_hooks_is_dispatcher "$slot"; then
        :
      elif _mcl_hooks_is_generated "$slot" && _mcl_hooks_is_dispatcher "$slot.legacy"; then
        slot="$slot.legacy"
      else
        continue
      fi
      if [ -z "$_mcl_hooks_snapshot_dir" ]; then
        _mcl_hooks_snapshot_dir="$(mktemp -d "''${TMPDIR:-/tmp}/mcl-hooks-snapshot.XXXXXX" 2>/dev/null)" || return 0
      fi
      cp -p "$slot" "$_mcl_hooks_snapshot_dir/$name" 2>/dev/null || true
    done
    return 0
  }

  _mcl_hooks_reprobuild_handoff() {
    local common hooks hp top resolved legacy slot local_hook name rechained stale saved
    rechained=" "
    common="$(${git} rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
    [ -n "$common" ] || return 0
    hooks="$common/hooks"
    [ -d "$hooks" ] || return 0

    # A relative core.hooksPath that names the common hooks directory is
    # made absolute (see the header).
    hp="$(${git} config --local --get core.hooksPath 2>/dev/null || true)"
    if [ -n "$hp" ] && [ "''${hp#/}" = "$hp" ]; then
      top="$(${git} rev-parse --show-toplevel 2>/dev/null || true)"
      resolved="$(cd "$top" 2>/dev/null && cd "$hp" 2>/dev/null && pwd -P || true)"
      if [ "$hp" = ".git/hooks" ] || [ "$resolved" = "$(cd "$hooks" && pwd -P)" ]; then
        ${git} config --local core.hooksPath "$hooks" || true
      fi
    fi

    for legacy in "$hooks"/*.legacy; do
      [ -f "$legacy" ] || continue
      grep -q 'reprobuild hook dispatcher' "$legacy" 2>/dev/null || continue
      slot="''${legacy%.legacy}"
      name="$(basename "$slot")"
      local_hook="$slot.repro-local"
      if [ -f "$slot" ] && grep -q 'reprobuild hook dispatcher' "$slot" 2>/dev/null; then
        rm -f "$legacy"
        continue
      fi
      if [ -f "$slot" ]; then
        if ! grep -Eq '^# File generated by (pre-commit|prek):' "$slot" 2>/dev/null; then
          echo 1>&2 "git-hooks: $name is not a pre-commit/prek shim; leaving the Reprobuild dispatcher at $name.legacy."
          echo 1>&2 "           Run 'repro hooks ensure --vcs' to reconcile."
          continue
        fi
        if [ -f "$local_hook" ] && ! grep -Eq '^# File generated by (pre-commit|prek):' "$local_hook" 2>/dev/null; then
          echo 1>&2 "git-hooks: $name.repro-local holds your own hook; not replacing it with the generated shim."
          echo 1>&2 "           Run 'repro hooks ensure --vcs' to reconcile."
          continue
        fi
        mv -f "$slot" "$local_hook" || continue
        chmod +x "$local_hook" 2>/dev/null || true
      fi
      mv -f "$legacy" "$slot" || continue
      rechained="$rechained$name "
      echo 1>&2 "git-hooks: kept the Reprobuild dispatcher at .git/hooks/$name (hook manager chained as $name.repro-local)"
    done

    # Dispatchers the installer destroyed: restore them from the snapshot.
    if [ -n "$_mcl_hooks_snapshot_dir" ] && [ -d "$_mcl_hooks_snapshot_dir" ]; then
      for saved in "$_mcl_hooks_snapshot_dir"/*; do
        [ -f "$saved" ] || continue
        name="$(basename "$saved")"
        slot="$hooks/$name"
        local_hook="$slot.repro-local"
        _mcl_hooks_is_dispatcher "$slot" && continue
        _mcl_hooks_is_dispatcher "$slot.legacy" && continue
        if [ -f "$slot" ]; then
          if ! _mcl_hooks_is_generated "$slot"; then
            echo 1>&2 "git-hooks: $name was replaced by a hook that is not a pre-commit/prek shim; the Reprobuild dispatcher is gone."
            echo 1>&2 "           Run 'repro hooks ensure --vcs' to reconcile."
            continue
          fi
          if [ -f "$local_hook" ] && ! _mcl_hooks_is_generated "$local_hook"; then
            echo 1>&2 "git-hooks: $name.repro-local holds your own hook; not replacing it with the generated shim."
            echo 1>&2 "           Run 'repro hooks ensure --vcs' to reconcile."
            continue
          fi
          mv -f "$slot" "$local_hook" || continue
          chmod +x "$local_hook" 2>/dev/null || true
        fi
        cp -p "$saved" "$slot" || continue
        chmod +x "$slot" 2>/dev/null || true
        rechained="$rechained$name "
        echo 1>&2 "git-hooks: restored the Reprobuild dispatcher at .git/hooks/$name, which the hook installer had overwritten (hook manager chained as $name.repro-local)"
      done
      rm -rf -- "''${_mcl_hooks_snapshot_dir:?}"
      _mcl_hooks_snapshot_dir=""
    fi

    # A generated shim left at `.legacy` behind a dispatcher (see the header).
    for legacy in "$hooks"/*.legacy; do
      [ -f "$legacy" ] || continue
      slot="''${legacy%.legacy}"
      _mcl_hooks_is_dispatcher "$slot" || continue
      _mcl_hooks_is_generated "$legacy" || continue
      rm -f "$legacy" || continue
      echo 1>&2 "git-hooks: removed .git/hooks/$(basename "$legacy") (a hook manager shim displaced behind the Reprobuild dispatcher)"
    done

    # Stale chained shims (see the header). Only after an installer run.
    if [ "$rechained" != " " ]; then
      for stale in "$hooks"/*.repro-local; do
        [ -f "$stale" ] || continue
        name="$(basename "''${stale%.repro-local}")"
        case "$rechained" in *" $name "*) continue ;; esac
        grep -Eq '^# File generated by (pre-commit|prek):' "$stale" 2>/dev/null || continue
        grep -q 'reprobuild hook dispatcher' "$hooks/$name" 2>/dev/null || continue
        rm -f "$stale" || continue
        echo 1>&2 "git-hooks: removed .git/hooks/$name.repro-local (a hook manager shim for a stage the current config no longer installs)"
      done
    fi
    return 0
  }
''
