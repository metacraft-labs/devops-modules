"""Host-side hook composition regression with real Git/native/Repro execution.

This deliberately runs outside a pure Nix builder: canonical Repro hooks name
/usr/bin/env. A transparent argv witness forwards every request to the actual
selected Repro CLI; it supplies no protocol or execution result. The empty Git
fixtures test composition and policy preservation, not project publication.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

p = argparse.ArgumentParser()
p.add_argument('--installer', required=True)
p.add_argument('--creator-git', required=True)
p.add_argument('--repro', required=True)
p.add_argument('--nix-store', required=True)
a = p.parse_args()
repro = Path(a.repro).resolve(strict=True)
engine = repro.parent / 'reprobuild'
assert engine.is_file() and os.access(engine, os.X_OK), 'Matching Repro engine absent'
for name, value in [('git', a.creator_git), ('repro-thin', a.repro), ('engine-wrapper', str(engine)), ('python', sys.executable), ('installer', a.installer), ('nix-store', a.nix_store)]:
    path = Path(value).resolve(strict=True)
    assert path.is_file() and os.access(path, os.X_OK), (name, path)
    print(json.dumps({'principal': name, 'path': str(path),
                      'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}), flush=True)

print(json.dumps({'creatorGitVersion': subprocess.check_output([a.creator_git, '--version'], text=True).strip()}), flush=True)

with tempfile.TemporaryDirectory(prefix='mcl-explicit-hooks-host-') as temp:
    temp = Path(temp).resolve(strict=True)
    env = os.environ.copy()
    # Git's documented hook context belongs to the caller, not these owned
    # fixture repositories. Clear its named local variables before entering
    # another repository; retain the actual user/HOME and declared tools.
    local_keys = subprocess.check_output([a.creator_git, 'rev-parse', '--local-env-vars'], text=True).splitlines()
    for key in [*local_keys, 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG_COUNT']:
        env.pop(key, None)
    env['GIT_CONFIG_NOSYSTEM'] = '1'
    env['GIT_CONFIG_GLOBAL'] = str(temp / 'gitconfig')
    (temp / 'gitconfig').write_text('')
    env['PRE_COMMIT_HOME'] = str(temp / 'native-cache')
    # Exercise the real constructor through an owned temporary-directory alias.
    # Its strict ownership comparison must use the same physical path as Git.
    constructor_tmp = temp / 'constructor-tmp'
    constructor_tmp.mkdir()
    constructor_alias = temp / 'constructor-alias'
    constructor_alias.symlink_to(constructor_tmp, target_is_directory=True)
    env['TMPDIR'] = str(constructor_alias)
    env['PATH'] = str(Path(a.creator_git).resolve().parent) + os.pathsep + str(repro.parent) + os.pathsep + env['PATH']
    # The selected public wrapper initializes its own engine/self-spawn roles.
    # Never inherit a foreign SDK's role variables from the calling hook.
    env.pop('REPRO_FULL_CLI', None)
    env.pop('REPRO_PUBLIC_CLI_PATH', None)
    env['HOOK_TEST_RAN'] = str(temp / 'native-ran')
    log = temp / 'repro-argv'
    witness = temp / 'repro-witness'
    witness.write_text('#!' + sys.executable + '\nimport json,os,sys\n'
                       + 'with open(' + repr(str(log)) + ',"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n'
                       + 'os.execv(' + repr(str(repro)) + ',[' + repr(str(repro)) + ',*sys.argv[1:]])\n')
    witness.chmod(0o755)
    env['REPROBUILD_REPRO'] = str(witness)

    def run(argv, cwd, success=True):
        result = subprocess.run([str(x) for x in argv], cwd=cwd, env=env,
                                capture_output=True, text=True, timeout=30)
        if (result.returncode == 0) != success:
            raise AssertionError((argv, result.returncode, result.stdout, result.stderr))
        return result

    def git(cwd, *args, **kwargs):
        return run([a.creator_git, '-C', cwd, *args], cwd, **kwargs)

    def new_repo(name):
        root = temp / name
        root.mkdir()
        git(root, 'init', '-q')
        git(root, 'config', 'user.name', 'fixture')
        git(root, 'config', 'user.email', 'fixture@example.invalid')
        (root / 'flake.nix').write_text('fixture\n')
        git(root, 'add', 'flake.nix')
        # Seed before any managed hook exists; no automatic hook is disabled.
        git(root, 'commit', '-qm', 'seed')
        return root

    def hooks(root):
        return Path(git(root, 'rev-parse', '--path-format=absolute', '--git-common-dir').stdout.strip()) / 'hooks'

    def snapshot(root):
        return {x.name: (x.lstat().st_mode & 0o777, os.readlink(x) if x.is_symlink()
                        else hashlib.sha256(x.read_bytes()).hexdigest()) for x in hooks(root).iterdir()}

    def install(root):
        samples = {n: v for n, v in snapshot(root).items() if n.endswith('.sample')}
        run([a.installer], root)
        config = root / '.pre-commit-config.yaml'
        assert config.is_symlink(), 'Native config link absent'
        # Read only this registration. Nix's global root enumeration removes
        # stale entries; its addIndirectRoot key is SHA1(path) in Nix32.
        # https://github.com/NixOS/nix/blob/2.34.8/src/libstore/gc.cc#L38-L42
        nix_hash = Path(a.nix_store).with_name('nix-hash')
        # NIX_STATE_DIR is the documented override; this declared Nix package
        # otherwise uses /nix/var/nix (also witnessed by the pure-store refusal).
        # https://nix.dev/manual/nix/2.34/command-ref/env-common#env-NIX_STATE_DIR
        state_dir = Path(os.environ.get('NIX_STATE_DIR', '/nix/var/nix'))
        assert state_dir.is_absolute() and state_dir.is_dir(), state_dir
        root_input = temp / 'root-path'
        root_input.write_text(str(config))
        key = run([nix_hash, '--flat', '--type', 'sha1', '--base32', root_input], root).stdout.strip()
        assert len(key) == 32 and all(c in '0123456789abcdfghijklmnpqrsvwxyz' for c in key)
        registration = Path(state_dir) / 'gcroots/auto' / key
        assert registration.is_symlink() and os.readlink(registration) == str(config), registration
        assert registration.resolve(strict=True) == config.resolve(strict=True)
        print(json.dumps({'nativeConfigRoot': str(config), 'registered': True}), flush=True)
        assert samples == {n: v for n, v in snapshot(root).items() if n.endswith('.sample')}

    def commit_and_witness(root, name):
        Path(env['HOOK_TEST_RAN']).write_text('')
        log.write_text('')
        (root / name).write_text(name)
        git(root, 'add', name)
        git(root, 'commit', '-qm', name)
        assert Path(env['HOOK_TEST_RAN']).read_text().splitlines() == ['native']
        calls = [json.loads(x) for x in log.read_text().splitlines()]
        assert any(x[:3] == ['hooks', 'dispatch', 'pre-commit'] for x in calls), calls

    root = new_repo('primary')
    linked = temp / 'linked'
    git(root, 'worktree', 'add', '-q', '-b', 'linked', linked)
    run([witness, 'hooks', 'ensure', '--vcs', root], root)
    managed = {n: v for n, v in snapshot(root).items() if not n.endswith('.sample')}
    install(root)
    for n, v in managed.items():
        assert snapshot(root)[n] == v
    commit_and_witness(root, 'primary-file')
    install(linked)
    commit_and_witness(linked, 'linked-file')

    policy = new_repo('policy')
    (policy / 'repro.lock').write_text('[certificate_policy]\n')
    run([witness, 'hooks', 'ensure', '--vcs', policy], policy)
    original = (hooks(policy) / 'pre-commit').read_bytes()
    install(policy)
    assert (hooks(policy) / 'pre-commit').read_bytes() == original
    Path(env['HOOK_TEST_RAN']).write_text('')
    (policy / 'policy-file').write_text('policy')
    git(policy, 'add', 'repro.lock', 'policy-file')
    result = git(policy, 'commit', '-qm', 'policy', success=False)
    assert Path(env['HOOK_TEST_RAN']).read_text().splitlines() == ['native']
    assert 'certificate' in (result.stdout + result.stderr).lower(), (result.stdout, result.stderr)
    print('PASS: real Git native/managed primary+linked execution; unchanged samples; certificate refusal retained', flush=True)
