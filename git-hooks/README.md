# Git hooks

The Metacraft Labs pre-commit hooks, in two layers and two forms.

## Two layers

**Layer 1 — the individual hooks**, each usable on its own. A consumer that
wants exactly one hook takes exactly one hook.

- `hooks.nix` — for flake consumers. A function from configuration to a set of
  `git-hooks.nix` hook definitions, one attribute per hook.
- `../.pre-commit-hooks.yaml` — the same layer, portable. It makes this
  repository a **pre-commit hook repository**, so any repo on any OS can name a
  hook by id with no flake and no `/nix/store`.

**Layer 2 — the MCL Standard Hook Set, named `mcl-standard-hooks`**: the
opinionated set our repos run in every project. A repo adopts it **by naming
it**, never by copying the membership, so adding a hook to the set reaches every
repo without an edit in any of them.

- `standard-hooks.nix` — for flake consumers. Installed by
  `../checks/pre-commit.nix`, which is what
  `nixos-modules.modules.flake.git-hooks` exports.
- `mcl-standard-hooks.yaml` — the same set, portable.

`metacraft-dev-guidelines/policies/repo-requirements.md` § 4 requires layer 2 by
name, for all three workspaces these modules serve.

## Two forms, and why both exist

**Pre-commit configuration is generally managed outside flakes here, because
flakes are not supported on Windows.** A hook set that exists only as a Nix
module is unavailable to every Windows developer, which makes it not actually
mandatory. Measured over the 159 directories of the reference workspace: 99
repos carry a `flake.nix`; **4** carry a real committed
`.pre-commit-config.yaml` (`agent-harbor`, `codetracer-engine-godot`,
`reprobuild-cmake`, `reprobuild-specs`); **15** carry one as a **symlink into
`/nix/store`** generated at devShell entry, which on Windows produces nothing at
all.

`agent-harbor` is the reference pattern and its config header states the design:
**the flake provides the tools, the committed config provides the rules**.

**Membership must be identical between the two forms.** Two expressions of one
list that disagree are worse than one expression that is awkward for half the
fleet, because neither reader can tell which is the rule. If you add a hook to
one, add it to the other in the same commit.

## The hook implementations

`mcl_git_hooks/ban_added_paths.py` is the mechanism behind
`ban-added-ct-recordings`: standard library only, no bash, no `/nix/store`, so
the _same_ implementation backs both forms. Read its docstring before changing
it — it documents why the rule is scoped to files a commit **adds** and why it
is Python rather than a shell one-liner.

`check-added-large-files` is not reimplemented. It already exists, maintained,
in `pre-commit/pre-commit-hooks`, and a second implementation of a rule is
exactly what we spend our time removing.

```bash
python3 git-hooks/test_ban_added_paths.py     # real git repos, no mocks
```

Every rule in that suite has both a planted defect that must be refused and a
legitimate case that must be accepted. A ban that never fires satisfies every
"must not commit" requirement ever written, so the pair is the test; either half
alone is not.
