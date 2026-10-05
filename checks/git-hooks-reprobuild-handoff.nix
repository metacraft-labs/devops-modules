# The git-hooks installer hands hook slots back to Reprobuild's dispatchers.
#
# See lib/git-hooks-reprobuild-handoff.nix for the problem. This check drives
# the REAL prek through the same `uninstall -t <every hook>` / `install -t
# <stage>` sequence upstream git-hooks.nix runs on every devShell entry, then
# the handoff, in a real git repository, and asserts on the resulting files and
# on real `git commit`s:
#
#   1. with a Reprobuild dispatcher present: the dispatcher is back in the slot,
#      prek's shim is chained as `<hook>.repro-local`, no `.legacy` remains, and
#      a commit runs BOTH prek's hook and the managed hook;
#   2. a second shell entry (prek re-installs over the restored dispatcher)
#      converges to the same layout, replacing the previously chained shim;
#   3. a hand-written `.repro-local` is never overwritten by the generated shim;
#   4. without Reprobuild the handoff changes nothing: prek's shim stays in the
#      slot and a commit runs it;
#   5. upstream's relative `core.hooksPath` (`.git/hooks`) is rewritten as the
#      absolute common hooks directory, and hooks then run in a LINKED
#      worktree, where the relative value resolved to nothing;
#   6. a generated shim chained for a stage the config no longer installs
#      (a stale `pre-push.repro-local`) is removed, so a push runs only the
#      managed hook; a hand-written one is kept; and an entry where the
#      installer did not run prunes nothing.
#
# TEST DOUBLE, JUSTIFIED: the Reprobuild dispatcher is a fixture, not the real
# `repro hooks ensure` output. Reprobuild is not an input of this flake, and
# building it for this check would put a multi-minute compile of an unrelated
# repository on every CI run. The handoff's contract with Reprobuild is
# textual — it recognises a dispatcher by its `reprobuild hook dispatcher`
# marker line and never executes it — so the fixture carries that exact line
# and the same chain (`.repro-local`, then `.repro-managed`) the real
# dispatcher runs. Reprobuild's own integration test
# (t_hooks_ensure_restores_dispatcher_displaced_by_prek) covers the real
# dispatcher against real prek. prek and git are the real tools.
_: {
  perSystem =
    {
      pkgs,
      lib,
      ...
    }:
    let
      handoff = import ../lib/git-hooks-reprobuild-handoff.nix {
        git = lib.getExe pkgs.git;
      };
    in
    {
      checks.git-hooks-reprobuild-handoff =
        pkgs.runCommand "git-hooks-reprobuild-handoff"
          {
            nativeBuildInputs = [
              pkgs.git
              pkgs.prek
              pkgs.gnugrep
              pkgs.coreutils
            ];
          }
          ''
            set -euo pipefail
            export HOME="$TMPDIR/home" PREK_HOME="$TMPDIR/prek-home"
            mkdir -p "$HOME"
            git config --global user.email check@example.invalid
            git config --global user.name check
            git config --global init.defaultBranch main
            RAN="$TMPDIR/ran"
            fail() { echo "FAIL: $*" >&2; exit 1; }

            ${handoff}

            # upstream git-hooks.nix installation, minus the config symlink
            shell_entry() {
              for h in pre-commit pre-push commit-msg post-commit post-checkout post-merge; do
                prek uninstall -t "$h" >/dev/null 2>&1 || true
              done
              git config --local --unset-all core.hooksPath || true
              prek install -c .pre-commit-config.yaml -t pre-commit
              # The sandbox has no /usr/bin/env, which prek's shim names in
              # its `#!` line; the rest of the generated file is untouched.
              patchShebangs .git/hooks/pre-commit >/dev/null
              git config --local core.hooksPath .git/hooks
              _mcl_hooks_reprobuild_handoff
            }

            new_repo() {
              rm -rf "$1"; mkdir -p "$1"; cd "$1"
              git init -q .
              cat > .pre-commit-config.yaml <<EOF
            repos:
            - repo: local
              hooks:
              - id: record
                name: record
                entry: sh -c 'echo prek >> $RAN'
                language: system
                pass_filenames: false
                always_run: true
            EOF
              git add .pre-commit-config.yaml
              git commit -q --no-verify -m init
            }

            install_dispatcher() {
              cat > .git/hooks/pre-commit <<'EOF'
            #!/bin/sh
            # reprobuild hook dispatcher protocol=2
            # (fixture: see the header of checks/git-hooks-reprobuild-handoff.nix)
            set -eu
            HOOK_DIR=$(cd "$(dirname "$0")" && pwd)
            if [ -x "$HOOK_DIR/pre-commit.repro-local" ]; then
              (unset PRE_COMMIT_RUNNING_LEGACY PREK_RUNNING_LEGACY; exec "$HOOK_DIR/pre-commit.repro-local" "$@")
            fi
            exec "$HOOK_DIR/pre-commit.repro-managed" "$@"
            EOF
              printf '#!/bin/sh\necho managed >> %s\n' "$RAN" > .git/hooks/pre-commit.repro-managed
              chmod +x .git/hooks/pre-commit .git/hooks/pre-commit.repro-managed
            }

            is_dispatcher() { grep -q 'reprobuild hook dispatcher' "$1" 2>/dev/null; }
            is_prek() { grep -q '^# File generated by prek:' "$1" 2>/dev/null; }

            commit_runs() {
              : > "$RAN"
              echo "$1" > f.txt; git add f.txt
              git commit -q -m "$1" || fail "commit '$1' failed"
              [ "$(sort "$RAN" | tr '\n' ' ')" = "$2" ] || fail "commit '$1' ran [$(tr '\n' ' ' < "$RAN")], expected [$2]"
            }

            echo "== 1. dispatcher present: handoff restores it and chains prek"
            new_repo "$TMPDIR/ws"
            install_dispatcher
            shell_entry
            is_dispatcher .git/hooks/pre-commit || fail "slot is not the dispatcher"
            is_prek .git/hooks/pre-commit.repro-local || fail "prek not chained as .repro-local"
            [ ! -e .git/hooks/pre-commit.legacy ] || fail ".legacy left behind"
            [ -x .git/hooks/pre-commit.repro-local ] || fail ".repro-local not executable"
            commit_runs one "managed prek "

            echo "== 2. second shell entry converges"
            printf '# stale marker\n' >> .git/hooks/pre-commit.repro-local
            shell_entry
            is_dispatcher .git/hooks/pre-commit || fail "slot is not the dispatcher (2nd entry)"
            is_prek .git/hooks/pre-commit.repro-local || fail "prek not chained (2nd entry)"
            ! grep -q 'stale marker' .git/hooks/pre-commit.repro-local || fail "stale chained shim not replaced"
            [ ! -e .git/hooks/pre-commit.legacy ] || fail ".legacy left behind (2nd entry)"
            commit_runs two "managed prek "

            echo "== 3. a hand-written .repro-local is never overwritten"
            printf '#!/bin/sh\necho mine >> %s\n' "$RAN" > .git/hooks/pre-commit.repro-local
            shell_entry 2>"$TMPDIR/err3"
            grep -q 'holds your own hook' "$TMPDIR/err3" || fail "no warning for hand-written .repro-local"
            grep -q 'echo mine' .git/hooks/pre-commit.repro-local || fail "hand-written .repro-local was overwritten"
            is_dispatcher .git/hooks/pre-commit.legacy || fail "dispatcher lost"

            echo "== 4. no Reprobuild: prek installs and runs as upstream leaves it"
            new_repo "$TMPDIR/plain"
            shell_entry
            is_prek .git/hooks/pre-commit || fail "prek shim not in the slot"
            [ ! -e .git/hooks/pre-commit.repro-local ] || fail "unexpected .repro-local"
            commit_runs plain "prek "

            echo "== 5. core.hooksPath is absolute; hooks run in a linked worktree"
            cd "$TMPDIR/ws"
            rm -f .git/hooks/pre-commit.repro-local .git/hooks/pre-commit.legacy
            install_dispatcher
            shell_entry
            hp="$(git config --local --get core.hooksPath)"
            [ "$hp" = "$(git rev-parse --path-format=absolute --git-common-dir)/hooks" ] \
              || fail "core.hooksPath is '$hp', expected the absolute common hooks dir"
            git worktree add -q "$TMPDIR/ws-linked" -b linked
            cd "$TMPDIR/ws-linked"
            commit_runs linked "managed prek "

            echo "== 6. a stale chained shim for an uninstalled stage is pruned"
            new_repo "$TMPDIR/stale"
            install_dispatcher
            cat > .git/hooks/pre-push <<'EOF'
            #!/bin/sh
            # reprobuild hook dispatcher protocol=2
            # (fixture: see the header of checks/git-hooks-reprobuild-handoff.nix)
            EOF
            chmod +x .git/hooks/pre-push
            # what an earlier config with a pre-push stage left chained
            prek install -c .pre-commit-config.yaml -t pre-push >/dev/null 2>&1
            mv .git/hooks/pre-push .git/hooks/pre-push.repro-local
            mv .git/hooks/pre-push.legacy .git/hooks/pre-push
            is_prek .git/hooks/pre-push.repro-local || fail "fixture: no stale prek pre-push shim"
            # an entry where the installer did not run prunes nothing
            _mcl_hooks_reprobuild_handoff
            [ -e .git/hooks/pre-push.repro-local ] || fail "pruned without an installer run"
            shell_entry 2>"$TMPDIR/err6"
            [ ! -e .git/hooks/pre-push.repro-local ] || fail "stale pre-push.repro-local kept"
            grep -q 'removed .git/hooks/pre-push.repro-local' "$TMPDIR/err6" || fail "no report of the pruned shim"
            is_dispatcher .git/hooks/pre-push || fail "pre-push dispatcher lost"
            is_prek .git/hooks/pre-commit.repro-local || fail "current pre-commit shim pruned"
            printf '#!/bin/sh\necho mine\n' > .git/hooks/pre-push.repro-local
            shell_entry 2>/dev/null
            grep -q 'echo mine' .git/hooks/pre-push.repro-local || fail "hand-written pre-push.repro-local removed"

            echo "all git-hooks handoff cases passed"
            touch "$out"
          '';
    };
}
