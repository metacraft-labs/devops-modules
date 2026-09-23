# Upstream Patches

This directory collects fixes for upstream projects that we carry as a
local patch in this repo and intend to contribute back upstream. It is the
patch analog of `codetracer-native-backend/upstream-bugs/` (which collects
_bug reports_); here each entry is a ready-to-submit _fix_.

Each subdirectory is named `<project>-<short-description>` and contains:

- `fix.patch` — a `git format-patch`/`git am`-able patch against the
  **upstream** repository (not this Nix build tree). It carries a real
  commit message (subject + body + `Signed-off-by:`).
- `PR.md` — the prepared pull-request title and body, written for a public
  upstream audience (no private infra details).
- `open-pr.sh` — a documented, ready-to-run script that forks the upstream
  repo (or reuses your fork), creates a branch, applies `fix.patch` with
  `git am`, pushes to your fork, and opens the PR with `gh`.

## Workflow

1. We hit a bug in an upstream dependency and land a local patch for it
   (for garm, that lives in `packages/<project>/patches/`).
2. Create a subdirectory here named `<project>-<short-description>`.
3. Regenerate `fix.patch` against a clean upstream checkout at the pinned
   revision so it applies to upstream `HEAD`, with a proper commit message
   and `Signed-off-by:` (use this repo's git identity —
   `git config user.name` / `git config user.email`).
4. Draft `PR.md` (Summary / The bug / Impact / The fix / How it was found).
5. Verify: `git apply --check fix.patch` (and `git am fix.patch`) against a
   fresh upstream clone, and that it still compiles.
6. Write `open-pr.sh`; set your fork slug at the top.
7. After review, run `open-pr.sh` to open the PR, then note the PR URL in
   `PR.md`.

## Relationship to the local patch

The local Nix patch and the upstream `fix.patch` should be the same change.
When upstream merges the fix and we bump the pin past it, drop the local
patch from `packages/<project>/default.nix` and mark the entry here as
landed (record the merged commit / release).
