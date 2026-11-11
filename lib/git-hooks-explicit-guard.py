"""Preflight an explicit native-hook install; preserve managed and inactive files.

The caller owns the same-repository check and runs the existing native installer
and Repro handoff between the before/after calls. This module never renders or
writes a Git hook and does not assign provenance to disabled sample files.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve(strict=True)
native = Path(sys.argv[2]).resolve(strict=True)
mode = sys.argv[3]
receipt = Path(sys.argv[4])
config_path = root / sys.argv[5]
config_target = sys.argv[6]


def git(*args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def identity(path):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode):
        return {'mode': stat.S_IMODE(info.st_mode), 'link': os.readlink(path)}
    if not stat.S_ISREG(info.st_mode):
        raise RuntimeError('Nonregular hook entry: ' + path.name)
    return {'mode': stat.S_IMODE(info.st_mode),
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}


if Path(git('rev-parse', '--show-toplevel')).resolve(strict=True) != root:
    raise RuntimeError('Foreign source repository')
common = Path(git('rev-parse', '--path-format=absolute', '--git-common-dir'))
hooks = common / 'hooks'
if common.is_symlink() or hooks.is_symlink() or not hooks.is_dir():
    raise RuntimeError('Unknown hooks-directory ownership')
effective = subprocess.run(['git', '-C', str(root), 'config', '--get', 'core.hooksPath'], text=True, capture_output=True)
local = subprocess.run(['git', '-C', str(root), 'config', '--local', '--get', 'core.hooksPath'], text=True, capture_output=True)
if effective.returncode not in (0, 1) or local.returncode not in (0, 1):
    raise RuntimeError('Cannot resolve effective hooksPath')
if effective.stdout.strip() and local.returncode != 0:
    raise RuntimeError('Inherited hooksPath is not local installation authority')
resolved_hooks = Path(git('rev-parse', '--path-format=absolute', '--git-path', 'hooks'))
if resolved_hooks.resolve(strict=True) != hooks.resolve(strict=True):
    raise RuntimeError('Foreign effective hooksPath')
if config_path.exists() or config_path.is_symlink():
    if not config_path.is_symlink() or os.readlink(config_path) != config_target:
        raise RuntimeError('Unknown native hook configuration')
if mode == 'after' and not config_path.is_symlink():
    raise RuntimeError('Native hook config missing after installation')

# Nix makes output files read-only; the real native installer emits mode 0755.
expected = {p.name: {'mode': 0o755, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
            for p in native.iterdir()}
entries = {p.name: identity(p) for p in hooks.iterdir()}
# The existing public constructor is the authority for dispatcher bytes.
# Managed bodies are deliberately ignored: they embed repository-local paths.
# Copy the exact declared lock solely to preserve the public certificate-policy
# selector used by Repro; do not interpret, normalize or downgrade that policy.
canonical_dispatchers = {}
if any(name.endswith('.repro-managed') for name in entries):
    selected = os.environ.get('REPROBUILD_REPRO')
    if not selected or not Path(selected).is_absolute() or not os.access(selected, os.X_OK):
        raise RuntimeError('Explicit matching managed constructor is absent')
    lock = root / 'repro.lock'
    if lock.is_symlink():
        raise RuntimeError('Symlinked certificate-policy lock is unresolved')
    lock_bytes = lock.read_bytes() if lock.exists() else None
    with tempfile.TemporaryDirectory(prefix='mcl-dispatcher-') as directory:
        # Git reports physical worktree paths, including with an aliased TMPDIR.
        fixture = Path(directory).resolve(strict=True)
        env = os.environ.copy()
        for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS', 'GIT_CONFIG'):
            env.pop(key, None)
        env['GIT_CONFIG_NOSYSTEM'] = '1'
        env['GIT_CONFIG_GLOBAL'] = str(fixture / 'gitconfig')
        (fixture / 'gitconfig').write_text('')
        subprocess.run(['git', 'init', '--template=', str(fixture)], env=env,
                       check=True, stdout=subprocess.DEVNULL)
        actual = subprocess.check_output(['git', '-C', str(fixture), 'rev-parse',
                                          '--path-format=absolute', '--git-path', 'hooks'],
                                         env=env, text=True).strip()
        if Path(actual) != fixture / '.git/hooks':
            raise RuntimeError('Constructor fixture hooks escaped owned directory')
        if lock_bytes is not None:
            (fixture / 'repro.lock').write_bytes(lock_bytes)
        subprocess.run([selected, 'hooks', 'ensure', '--vcs', str(fixture)],
                       cwd=fixture, env=env, check=True, stdout=subprocess.DEVNULL)
        generated = fixture / '.git/hooks'
        for path in generated.iterdir():
            if (generated / (path.name + '.repro-managed')).is_file():
                canonical_dispatchers[path.name] = path.read_bytes()
    if (lock.read_bytes() if lock.exists() else None) != lock_bytes:
        raise RuntimeError('Certificate-policy input changed during construction')
managed = {}
for name, value in entries.items():
    if name.endswith('.sample'):
        continue
    path = hooks / name
    if value.get('mode') != 0o755 or 'link' in value:
        raise RuntimeError('Unknown active hook mode: ' + name)
    if name in expected and name + '.repro-managed' not in entries and value == expected[name]:
        continue
    if (name.endswith('.repro-local') and name[:-12] + '.repro-managed' in entries
            and value == expected.get(name[:-12])):
        continue
    if name.endswith('.repro-managed'):
        body = path.read_text()
        tokens = set(re.findall(r'reprobuild\.managed-hook\.v1\.[a-z-]+\.[0-9a-f]+', body))
        selected = os.environ.get('REPROBUILD_REPRO')
        if len(tokens) != 1 or not selected:
            raise RuntimeError('Unresolved managed hook protocol: ' + name)
        subprocess.run([selected, 'hooks', 'protocol', '--require=2',
                        '--hook-contract=' + tokens.pop()], check=True,
                       stdout=subprocess.DEVNULL)
        managed[name] = value
        continue
    if (name in canonical_dispatchers and path.read_bytes() == canonical_dispatchers[name]
            and name + '.repro-managed' in entries):
        managed[name] = value
        continue
    raise RuntimeError('Unknown active hook or incompatible dispatcher: ' + name)

if mode == 'before':
    receipt.write_text(json.dumps({'entries': entries, 'managed': managed}, sort_keys=True) + '\n')
elif mode == 'after':
    before = json.loads(receipt.read_text())
    if set(managed) != set(before['managed']):
        raise RuntimeError('Installer changed managed hook inventory')
    samples = {name for name in entries if name.endswith('.sample')}
    if samples != {name for name in before['entries'] if name.endswith('.sample')}:
        raise RuntimeError('Installer changed inactive sample inventory')
    for name, value in before['entries'].items():
        if name.endswith('.sample') or name in before['managed']:
            if entries.get(name) != value:
                raise RuntimeError('Installer changed preserved entry: ' + name)
    for name, value in expected.items():
        selected = name + '.repro-local' if name in before['managed'] else name
        if entries.get(selected) != value:
            raise RuntimeError('Expected native hook is not installed: ' + selected)
else:
    raise RuntimeError('Unknown guard phase')
