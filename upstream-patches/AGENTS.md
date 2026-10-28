# Upstream Patches

This directory collects fixes for upstream projects that we carry as a
local patch in this repo and intend to contribute back upstream. It is the
patch analog of `codetracer-native-backend/upstream-bugs/` (which collects
_bug reports_); here each entry is a ready-to-submit _fix_.

Each subdirectory is named `<project>-<short-description>` and is a
_prepared PR bundle_ (metacraft-dev-guidelines
`policies/preparing-prs-for-internal-review.md`). It contains:

- `bundle.toml` — the manifest: upstream repo, pinned `base_sha`, fork
  placeholder, branch, title, body, patches, optional `prepare` hook and
  `inputs`, and the `[review] forbid` list of private identifiers.
- `fix.patch` — a `git format-patch`/`git am`-able patch against the
  **upstream** repository (not this Nix build tree). It carries a real
  commit message (subject + body + `Signed-off-by:`).
- `PR.md` — the prepared pull-request title and body, written for a public
  upstream audience (no private infra details).
- `prepare.sh` (optional) — run in the PR tree after the patches. The bundles
  whose test is a gate file in `../checks/garm/` (the single source of truth
  for the patched and unpatched gate runs) use it to copy that file in as a
  second commit, scrubbed.
- `open-pr.sh` — a thin wrapper around `scripts/submit-prepared-pr`. It
  **dry-runs by default**; `--verify --against-head` checks the patches on the
  pinned base and the current upstream head; `--submit` refuses until a
  reviewer's `--approve` (a content digest in `REVIEW-APPROVED`) matches.
  Set `MDG` to a metacraft-dev-guidelines checkout if it is not the workspace
  sibling.

## Workflow

1. We hit a bug in an upstream dependency and land a local patch for it
   (for garm, that lives in `packages/<project>/patches/`).
2. Create a subdirectory here named `<project>-<short-description>`.
3. Cut `fix.patch` on a clean upstream checkout at the current upstream head,
   record that commit as `base_sha`, with a proper commit message and
   `Signed-off-by:`. Put the tests in the series (or, for a gate test file,
   in a `prepare.sh` hook declared with `inputs`).
4. Draft `PR.md` (Summary / The bug / Impact / The fix / Tests).
5. Write `bundle.toml` and copy the thin `open-pr.sh` from a sibling.
6. Check: `./open-pr.sh --verify --against-head` and `./open-pr.sh` (dry run).
7. Commit, ask for review; the reviewer runs `./open-pr.sh --approve
--reviewer NAME`. Submit with `./open-pr.sh --submit --fork <you>/<repo>`,
   then note the PR URL in `PR.md` and as `submitted` under `[pr]`.

## Status

`--verify --against-head` against cloudbase/garm `main` 33ec0921 and
cloudbase/garm-provider-common `main` ec82f622 (2026-10-27). None has been
submitted or approved.

| Bundle                                          | Base     | On base | On head | Status                                                             |
| ----------------------------------------------- | -------- | ------- | ------- | ------------------------------------------------------------------ |
| `garm-busy-runner-reap`                         | aa830b59 | ✓       | ✓       | ready for review                                                   |
| `garm-job-cache-stale-lock`                     | aa830b59 | ✓       | ✓       | ready for review                                                   |
| `garm-deleting-instances-hold-capacity`         | aa830b59 | ✓       | ✓       | ready for review                                                   |
| `garm-instance-lifecycle-leaks`                 | 33ec0921 | ✓       | ✓       | re-cut 2026-10-27; ready for review                                |
| `garm-allow-macos-pools` (`bundle-common.toml`) | ec82f622 | ✓       | ✓       | ready for review; submit first                                     |
| `garm-allow-macos-pools` (`bundle.toml`)        | 0a9a939c | ✓       | ✓       | ready for review; needs the provider-common PR merged and vendored |
| `garm-listinstances-inverted-error-check`       | 0a9a939c | ✓       | ❌      | **landed**: fixed upstream in 488cf98b; local patch dropped        |
| `garm-stale-scaleset-job-reaper`                | 0a9a939c | ✓       | ❌      | **landed**: superseded by 8c64910f; local patch + gate dropped     |

A retired bundle is kept as the record of what was prepared; its wrapper
refuses `--submit` and `--approve`, and `bundle.toml` carries a `[status]`
table. `packages/garm` now pins `33ec0921`, past both upstream fixes, so the
two retired bundles' local Nix patches are gone (as is the
`backport-watcher-lossless-delivery` backport, which 0d6acdea made redundant).
The remaining local patches in `packages/garm/patches/` were re-cut on
`33ec0921` from these bundles, minus the gate-owned test files.

## Relationship to the local patch

The local Nix patch and the upstream `fix.patch` should be the same change.
When upstream merges the fix and we bump the pin past it, drop the local
patch from `packages/<project>/default.nix` and mark the entry here as
landed (record the merged commit / release).
