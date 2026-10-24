# Exercise the explicit installer with real Git, the real native hook manager
# and the already-declared Repro package for construction/protocol checks.
# Pure builders cannot execute canonical /usr/bin/env managed hooks. The
# separate host integration below is enrolled in this repo's native gate.
{ inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      fixtureFlake = "fixture\n";
      repro = inputs.reprobuild.packages.${system}.default;
      preCommitFor =
        addGcRoot:
        inputs.git-hooks-nix.lib.${system}.run {
          inherit addGcRoot;
          src = ./.;
          package = pkgs.pre-commit;
          hooks.record = {
            enable = true;
            name = "record actual native execution";
            entry = "sh -c 'echo native >> \"$HOOK_TEST_RAN\"'";
            language = "system";
            pass_filenames = false;
            always_run = true;
          };
        };
      preCommit = preCommitFor true;
      purePreCommit = preCommitFor false;
      installerFor =
        preCommit:
        import ../lib/git-hooks-explicit-install.nix {
          inherit pkgs preCommit;
          expectedFlakeNixHash = builtins.hashString "sha256" fixtureFlake;
        };
      installer = installerFor preCommit;
      # Pure builders cannot register roots in the host store. Upstream uses
      # this supported option in its own installation tests; the separate host
      # installer retains true and its integration verifies the real root.
      pureInstaller = installerFor purePreCommit;
      hostTest = pkgs.writeShellApplication {
        name = "test-git-hooks-explicit-integration";
        runtimeInputs = [
          pkgs.git
          pkgs.python3
          pkgs.coreutils
          pkgs.nix
          repro
        ];
        text = ''
          exec python3 ${../tests/git-hooks-explicit-integration.py} \
            --installer ${installer}/bin/mcl-install-own-hooks \
            --creator-git ${pkgs.git}/bin/git --repro ${repro}/bin/repro \
            --nix-store ${pkgs.nix}/bin/nix-store "$@"
        '';
      };
    in
    {
      packages.git-hooks-explicit-integration = hostTest;
      checks.git-hooks-explicit-install =
        pkgs.runCommand "git-hooks-explicit-install"
          {
            nativeBuildInputs = [
              pkgs.git
              pkgs.python3
              pkgs.coreutils
            ];
          }
          ''
            set -euo pipefail
            export HOME="$TMPDIR/home" PRE_COMMIT_HOME="$TMPDIR/pre-commit"
            export HOOK_TEST_RAN="$TMPDIR/ran"
            mkdir -p "$HOME"
            git config --global user.name fixture
            git config --global user.email fixture@example.invalid
            git config --global init.defaultBranch main
            fail() { echo "FAIL: $*" >&2; exit 1; }
            new_repo() {
              mkdir "$1"; cd "$1"; git init -q
              printf 'fixture\n' > flake.nix
              git add flake.nix; git commit -qm seed
            }
            inventory() {
              python3 - "$PWD" <<'PY'
            import hashlib,json,os,pathlib,stat,subprocess,sys
            root=pathlib.Path(sys.argv[1])
            common=subprocess.check_output(['git','rev-parse','--path-format=absolute','--git-common-dir'],text=True).strip()
            hooks=pathlib.Path(common)/'hooks'
            out={}
            for p in hooks.iterdir():
                s=p.lstat()
                out[p.name]=[stat.S_IMODE(s.st_mode),os.readlink(p) if p.is_symlink() else hashlib.sha256(p.read_bytes()).hexdigest()]
            cfg=root/'.pre-commit-config.yaml'
            out['CONFIG']=os.readlink(cfg) if cfg.is_symlink() else cfg.read_text() if cfg.exists() else None
            out['LOCAL_CONFIG']=subprocess.check_output(['git','config','--local','--list'],text=True)
            print(json.dumps(out,sort_keys=True))
            PY
            }
            refuse_unchanged() {
              inventory > "$TMPDIR/before"
              if ${pureInstaller}/bin/mcl-install-own-hooks >"$TMPDIR/out" 2>"$TMPDIR/err"; then fail "unexpected install success"; fi
              inventory > "$TMPDIR/after"
              cmp "$TMPDIR/before" "$TMPDIR/after" || fail "refusal mutated hooks/config"
            }

            new_repo "$TMPDIR/native"
            # Disabled samples need not match the installer's own Git template.
            # Keep an intentionally different inactive body, and prove no rewriting.
            printf '#!/different/packaged/bash\n# inactive sample\n' > .git/hooks/applypatch-msg.sample
            sha256sum .git/hooks/*.sample > "$TMPDIR/samples"
            ${pureInstaller}/bin/mcl-install-own-hooks
            sha256sum -c "$TMPDIR/samples"
            : > "$HOOK_TEST_RAN"
            echo one > f; git add f; git commit -qm one
            test "$(cat "$HOOK_TEST_RAN")" = native
            inventory > "$TMPDIR/once"
            ${pureInstaller}/bin/mcl-install-own-hooks
            inventory > "$TMPDIR/twice"
            cmp "$TMPDIR/once" "$TMPDIR/twice"

            new_repo "$TMPDIR/managed"
            export REPROBUILD_REPRO=${repro}/bin/repro
            "$REPROBUILD_REPRO" hooks ensure --vcs "$PWD"
            sha256sum .git/hooks/pre-commit .git/hooks/pre-commit.repro-managed > "$TMPDIR/managed-before"
            ${pureInstaller}/bin/mcl-install-own-hooks
            sha256sum -c "$TMPDIR/managed-before"
            # Runtime managed execution is the host-native regression's duty.
            ${pureInstaller}/bin/mcl-install-own-hooks
            sha256sum -c "$TMPDIR/managed-before"
            # The REAL matching CLI must reject an unsupported managed token
            # before native mutation, independently of constructor availability.
            cp .git/hooks/pre-commit.repro-managed "$TMPDIR/original-managed"
            python3 - <<'PYTOKEN'
            from pathlib import Path
            import re
            p=Path('.git/hooks/pre-commit.repro-managed')
            s=p.read_text()
            s,n=re.subn(r'reprobuild\.managed-hook\.v1\.pre-commit\.[0-9a-f]+',
                        'reprobuild.managed-hook.v1.pre-commit.0000000000000000',s)
            assert n > 0
            p.write_text(s)
            PYTOKEN
            refuse_unchanged
            cp "$TMPDIR/original-managed" .git/hooks/pre-commit.repro-managed
            cp .git/hooks/pre-commit "$TMPDIR/original-dispatcher"
            printf '# modified dispatcher\n' >> .git/hooks/pre-commit
            refuse_unchanged
            cp "$TMPDIR/original-dispatcher" .git/hooks/pre-commit
            printf '#!/bin/sh\n# reprobuild hook dispatcher protocol=2\nexit 0\n' > .git/hooks/pre-commit
            refuse_unchanged
            cp "$TMPDIR/original-dispatcher" .git/hooks/pre-commit
            printf '#!/bin/sh\necho unresolved\n' > .git/hooks/pre-commit.legacy
            chmod +x .git/hooks/pre-commit.legacy
            refuse_unchanged
            rm .git/hooks/pre-commit.legacy
            printf '#!/bin/sh\necho user\n' > .git/hooks/pre-commit.repro-local
            chmod +x .git/hooks/pre-commit.repro-local
            refuse_unchanged

            new_repo "$TMPDIR/linked-primary"
            # Prepare the linked worktree before installing any managed hooks:
            # worktree add itself fires post-checkout, which names /usr/bin/env.
            git worktree add -q -b linked "$TMPDIR/linked"
            "$REPROBUILD_REPRO" hooks ensure --vcs "$PWD"
            ${pureInstaller}/bin/mcl-install-own-hooks
            cd "$TMPDIR/linked"
            ${pureInstaller}/bin/mcl-install-own-hooks
            test "$(git rev-parse --path-format=absolute --git-path hooks)" = "$(git rev-parse --path-format=absolute --git-common-dir)/hooks"

            new_repo "$TMPDIR/certificate-policy"
            # Malformed declared policy deliberately still selects the certificate
            # phase. Installation must retain it, never downgrade to an empty
            # factory's non-certificate dispatcher or turn its refusal into a pass.
            printf '[certificate_policy]\n' > repro.lock
            "$REPROBUILD_REPRO" hooks ensure --vcs "$PWD"
            sha256sum .git/hooks/pre-commit > "$TMPDIR/policy-dispatcher"
            ${pureInstaller}/bin/mcl-install-own-hooks
            sha256sum -c "$TMPDIR/policy-dispatcher"
            # The host-native regression proves the certificate refusal actually
            # fires through real Git; here its canonical phase stays byte-exact.

            new_repo "$TMPDIR/different-native-stage"
            ln -s ${preCommit.config.configFile} .pre-commit-config.yaml
            ${pkgs.lib.getExe preCommit.config.package} install -c .pre-commit-config.yaml -t pre-push
            refuse_unchanged
            new_repo "$TMPDIR/unknown-active"
            printf '#!/bin/sh\necho user\n' > .git/hooks/pre-commit
            chmod +x .git/hooks/pre-commit
            refuse_unchanged
            new_repo "$TMPDIR/foreign-hookspath"
            mkdir "$TMPDIR/foreign-hooks"
            printf '#!/bin/sh\necho foreign\n' > "$TMPDIR/foreign-hooks/pre-commit"
            chmod +x "$TMPDIR/foreign-hooks/pre-commit"
            sha256sum "$TMPDIR/foreign-hooks/pre-commit" > "$TMPDIR/foreign-before"
            git config --local core.hooksPath "$TMPDIR/foreign-hooks"
            refuse_unchanged
            sha256sum -c "$TMPDIR/foreign-before"
            new_repo "$TMPDIR/unknown-config"
            printf 'user configuration\n' > .pre-commit-config.yaml
            refuse_unchanged
            new_repo "$TMPDIR/foreign"
            printf 'foreign\n' > flake.nix
            refuse_unchanged
            touch "$out"
          '';
    };
}
