# API-M1 — the enforcement half of the `mcl` -> `mcl-devops` rename.
#
# metacraft-specs/infrastructure/metacraft-cli.md §2.5 rules that the
# deprecation shim FAILS rather than forwards, and names three rules that make
# the transition safe.  Two of them are declarations elsewhere (the throwing
# `packages.mcl` alias in packages/default.nix, and the failing `bin/mcl` stub
# inside `mcl-devops`); the third is this file:
#
#   "That ordering is enforced, not remembered.  A repository check asserts
#    that exactly one package in the estate provides `bin/mcl`, and that
#    during the window it is the stub.  A check makes the ordering structural;
#    a note in a milestone does not."
#
# Plus the milestone's own falsifier, `test_no_stale_mcl_references`, which is
# an ABSENCE assertion and therefore worthless on its own: a search that has
# never found anything has not been shown to be capable of finding anything.
# Both checks below plant a hit -- a stale reference, and a second provider of
# `bin/mcl` -- and assert that the SAME code path which produced the green
# result finds it, in the same run.
{ lib, ... }:
{
  perSystem =
    {
      pkgs,
      self',
      ...
    }:
    let
      repoRoot = ../.;

      # `packages.mcl` is the deliberate throwing alias; forcing it would abort
      # evaluation, which is exactly what it exists to do.
      scannedPackages = lib.filterAttrs (_: lib.isDerivation) (
        builtins.removeAttrs self'.packages [ "mcl" ]
      );

      # `name<TAB>storePath` per package.  Interpolating each derivation makes
      # this check depend on (and therefore realise) every package in the
      # estate, which is what "exactly one package provides bin/mcl" requires:
      # the property cannot be decided from evaluation alone.  Every one of
      # these is already a member of `checks`, so CI realises them regardless.
      packageInventory = lib.concatMapStringsSep "\n" (name: "${name}\t${scannedPackages.${name}}") (
        lib.attrNames scannedPackages
      );

      # A synthetic SECOND provider of `bin/mcl`, used only as the positive
      # control for the provider counter.  It is installed nowhere.
      controlSecondProvider = pkgs.writeShellScriptBin "mcl" "exit 0";
    in
    {
      checks = {
        # test_no_stale_mcl_references
        mcl-devops-no-stale-references =
          pkgs.runCommand "mcl-devops-no-stale-references"
            {
              nativeBuildInputs = [ pkgs.python3 ];
              repoRoot = "${repoRoot}";
            }
            ''
              python3 <<'PY'
              import os, re, tempfile
              from pathlib import Path

              REPO = Path(os.environ["repoRoot"])

              # The 18 registered subcommands (see
              # packages/mcl-devops/src/mcl/commands/package.d), the two command
              # modules that exist but are not registered, and the help forms.
              VERBS = [
                  "deploy-apply", "deploy-agent", "deploy-plan", "deploy-reconcile",
                  "deploy-spec", "deploy-status", "deploy-ssh", "cache", "ci-matrix",
                  "print-table", "merge-ci-matrices", "shard-matrix", "ci",
                  "host-info", "machine", "config", "hosts", "secret",
                  "get-fstab", "match-invoices",
                  "--help", "-h", "--version",
              ]
              VERB_RE = "|".join(re.escape(v) for v in sorted(VERBS, key=len, reverse=True))

              # What counts as a stale reference to the DEVOPS tool.  Precision
              # matters as much as recall: `mcl` is also the organisation prefix
              # (`mcl-disko`, `services.mcl-deploy-agent`), a NixOS option
              # namespace (`mcl.secrets`), an on-disk state root (`/var/lib/mcl`)
              # and a Prometheus metric prefix (`mcl_deployment_*`).  None of
              # those is renamed (metacraft-cli.md 2.4), and a pattern that
              # matched them would bury the hits that matter.
              PATTERNS = [
                  ("command invocation",
                   re.compile(r'(?<![\w./$-])mcl(?=[ \t]+(?:' + VERB_RE + r')(?![\w-]))')),
                  # The trailing guard excludes `-` only, NOT `.`.  A lookahead
                  # that also excluded `.` would miss `pkgs.mcl.override` and
                  # `self'.packages.mcl.overrideAttrs` -- and the latter is the
                  # single reference this rename actually tripped over.  A
                  # pattern blind to the exact class that has already bitten us
                  # is not a falsifier.
                  ("package attribute",
                   re.compile(r'(?<![\w-])(?:pkgs|packages(?:\.\$\{[^}]+\})?)\.mcl(?![\w-])')),
                  # `mcl` as a quoted argv element -- `["mcl", "deploy-apply"]`.
                  # The tool emits its own argv into the deployment event log in
                  # exactly this shape, and no other pattern here can see it.
                  # \x22 / \x27 are the quote characters, spelled in hex so this
                  # pattern survives being embedded in a Nix indented string.
                  ("quoted argv element",
                   re.compile(r'(?<![\w-])([\x22\x27])mcl\1\s*[,\]\)]')),
                  # Deliberately stops at `.`: `#mcl.shard-matrix` is the
                  # `flake.mcl.shard-matrix` OUTPUT namespace that every consumer
                  # flake declares (see flake.nix and infra/flake.nix), i.e. a
                  # machine-declared name that 2.4 keeps, not the package
                  # attribute.  `#mcl` with nothing after it is the package.
                  ("flake attribute",
                   re.compile(r'#mcl(?![\w.-])')),
                  ("binary path",
                   re.compile(r'(?<![\w.-])bin/mcl(?![\w-])')),
                  ("source tree path",
                   re.compile(r'(?<![\w.-])packages/mcl(?![\w-])')),
                  ("tool named in prose",
                   re.compile(r'`mcl`|(?<![\w=])=mcl=(?![\w=])|(?<![\w~])~mcl~(?![\w~])')),
              ]

              # The deliberate deprecation path -- the only place the old name
              # may still appear.  Delete these entries together with the stub.
              ALLOWED = {
                  "packages/default.nix",              # the throwing `mcl` alias
                  "packages/mcl-devops/default.nix",   # the failing `bin/mcl` stub
                  "checks/packages-ci-matrix.nix",     # keeps the alias out of CI
                  "checks/mcl-devops-rename.nix",      # this file
              }

              SKIP_SUFFIXES = (".png", ".jpg", ".jpeg", ".gz", ".xz", ".zst",
                               ".age", ".lock", ".qcow2", ".img")

              def search(root):
                  """[(relpath, kind, lineno, line)] for every stale hit under `root`."""
                  hits = []
                  scanned = 0
                  for path in sorted(root.rglob("*")):
                      if path.is_symlink() or not path.is_file():
                          continue
                      rel = str(path.relative_to(root))
                      if rel in ALLOWED or path.name.endswith(SKIP_SUFFIXES):
                          continue
                      try:
                          text = path.read_text(encoding="utf-8")
                      except (UnicodeDecodeError, OSError):
                          continue
                      scanned += 1
                      for lineno, line in enumerate(text.splitlines(), 1):
                          for kind, rx in PATTERNS:
                              if rx.search(line):
                                  hits.append((rel, kind, lineno, line.strip()))
                  return hits, scanned

              # ---- the assertion, computed first, reported last -----------
              clean, scanned = search(REPO)

              # An absence assertion is also satisfied by a walk that never
              # happened.  `search()` returns ([], 0) just as happily for a
              # mis-rooted, empty or unreadable tree as for a clean one, and
              # the planted control below runs against a temporary directory,
              # so it cannot tell the difference either.  This floor is what
              # makes "0 stale references" a statement about THIS repository:
              # nixos-modules has ~760 scannable text files, and any run that
              # sees fewer than half of them is reporting on something else.
              MIN_SCANNED = 400
              if scanned < MIN_SCANNED:
                  raise SystemExit(
                      f"the stale-reference search scanned only {scanned} files "
                      f"under {REPO} (expected at least {MIN_SCANNED}). The tree "
                      "it was pointed at is not this repository, so a clean "
                      "result would mean nothing."
                  )

              # ---- the POSITIVE CONTROL, in the same run, through the same
              # ---- `search()` that produced `clean`.  One planted reference
              # ---- per pattern, so a single pattern rotting is caught rather
              # ---- than masked by its neighbours.
              planted = {
                  "planted-command.sh":    "mcl deploy-apply --manifest -\n",
                  "planted-attribute.nix": "{ x = pkgs.mcl; }\n",
                  # The dotted form gets its own control because it is the one
                  # a naive lookahead silently drops, and the one that actually
                  # survived this rename's first pass.
                  "planted-attribute-dotted.nix":
                                           "y = self'.packages.mcl.overrideAttrs (_: { });\n",
                  "planted-argv.d":        'auto argv = ["mcl", "deploy-apply"];\n',
                  "planted-flakeref.sh":   "nix run .#mcl -- hosts scan\n",
                  "planted-binpath.nix":   "exec /run/current-system/sw/bin/mcl\n",
                  "planted-srcpath.md":    "see packages/mcl/AGENTS.md\n",
                  "planted-prose.md":      "the `mcl` tool is a swiss knife\n",
              }
              expected_kinds = {
                  "planted-command.sh":    "command invocation",
                  "planted-attribute.nix": "package attribute",
                  "planted-attribute-dotted.nix": "package attribute",
                  "planted-argv.d":        "quoted argv element",
                  "planted-flakeref.sh":   "flake attribute",
                  "planted-binpath.nix":   "binary path",
                  "planted-srcpath.md":    "source tree path",
                  "planted-prose.md":      "tool named in prose",
              }

              with tempfile.TemporaryDirectory() as tmp:
                  control_root = Path(tmp)
                  for name, body in planted.items():
                      (control_root / name).write_text(body)
                  control_hits, _ = search(control_root)

              by_file = {}
              for rel, kind, _n, _l in control_hits:
                  by_file.setdefault(rel, set()).add(kind)

              for name, kind in expected_kinds.items():
                  if name not in by_file:
                      raise SystemExit(
                          "POSITIVE CONTROL FAILED: the stale-reference search did "
                          f"not find the deliberately planted reference in {name!r} "
                          f"({planted[name]!r}). The result below therefore proves "
                          "nothing: an absence assertion with a dead search always "
                          "passes."
                      )
                  if kind not in by_file[name]:
                      raise SystemExit(
                          f"POSITIVE CONTROL FAILED: {name!r} was matched, but not "
                          f"by the {kind!r} pattern (matched {sorted(by_file[name])}); "
                          "that pattern has rotted."
                      )

              # ---- now, and only now, report the real result ---------------
              if clean:
                  report = "\n".join(
                      f"  {rel}:{n}: [{kind}] {line}" for rel, kind, n, line in clean
                  )
                  raise SystemExit(
                      "stale references to the devops tool as bare `mcl` survive "
                      f"outside the deliberate deprecation path:\n{report}"
                  )

              print(
                  f"scanned {scanned} text files with {len(PATTERNS)} patterns, "
                  "each proven live by its own planted control in this run; "
                  "0 stale references"
              )
              PY
              touch $out
            '';

        # metacraft-cli.md 2.5, supporting rule 3.
        mcl-devops-single-bin-mcl-provider =
          pkgs.runCommand "mcl-devops-single-bin-mcl-provider"
            {
              nativeBuildInputs = [ pkgs.python3 ];
              inherit packageInventory;
              controlSecondProvider = "${controlSecondProvider}";
              passAsFile = [ "packageInventory" ];
            }
            ''
              python3 <<'PY'
              import os, subprocess
              from pathlib import Path

              inventory = [
                  tuple(line.split("\t", 1))
                  for line in Path(os.environ["packageInventoryPath"]).read_text().split("\n")
                  if line.strip()
              ]
              if len(inventory) < 2:
                  raise SystemExit(
                      f"package inventory looks empty ({inventory!r}); the check "
                      "would be vacuous"
                  )

              def providers(entries):
                  """Every (name, path) in `entries` whose output contains bin/mcl."""
                  return [
                      (name, store)
                      for (name, store) in entries
                      if (Path(store) / "bin" / "mcl").is_file()
                  ]

              # ---- POSITIVE CONTROL, first, so that a broken detector cannot
              # ---- make the real assertion pass for the wrong reason.  Two
              # ---- providers is exactly the state 2.5 rule 2 forbids; prove
              # ---- the counter can see it.
              control = os.environ["controlSecondProvider"]
              baseline = providers(inventory)
              controlled = providers(inventory + [("positive-control", control)])
              if len(controlled) != len(baseline) + 1 or "positive-control" not in dict(controlled):
                  raise SystemExit(
                      "POSITIVE CONTROL FAILED: adding a package that provides "
                      f"bin/mcl ({control}) did not register as an extra provider "
                      f"({len(baseline)} -> {len(controlled)}). The detector is "
                      "broken and the assertion below proves nothing."
                  )

              # ---- the assertion -------------------------------------------
              if len(baseline) != 1:
                  raise SystemExit(
                      "expected EXACTLY ONE package providing bin/mcl across the "
                      f"{len(inventory)} packages in this estate, found "
                      f"{len(baseline)}: {[n for n, _ in baseline]} "
                      "(metacraft-cli.md 2.5 rule 2: at no instant may two "
                      "packages both provide bin/mcl)"
                  )
              name, store = baseline[0]
              if name != "mcl-devops":
                  raise SystemExit(
                      f"bin/mcl is provided by `{name}`; during the deprecation "
                      "window it must be the `mcl-devops` stub"
                  )

              # ---- and during the window it must be the FAILING stub: not a
              # ---- forwarder, not the real tool.
              stub = str(Path(store) / "bin" / "mcl")
              run = subprocess.run([stub, "deploy-apply", "--dry-run"],
                                   capture_output=True, text=True)
              if run.returncode == 0:
                  raise SystemExit(
                      "bin/mcl exited 0: the deprecation shim must FAIL, not "
                      "forward (metacraft-cli.md 2.5)"
                  )
              if "mcl-devops" not in run.stderr:
                  raise SystemExit(
                      f"bin/mcl did not name `mcl-devops` on stderr: {run.stderr!r}"
                  )
              if "deploy-apply --dry-run" not in run.stderr:
                  raise SystemExit(
                      "bin/mcl did not echo the subcommand it was invoked with: "
                      f"{run.stderr!r}"
                  )
              if run.stdout != "":
                  raise SystemExit(
                      "bin/mcl wrote to stdout; the message belongs on stderr: "
                      f"{run.stdout!r}"
                  )

              real = Path(store) / "bin" / "mcl-devops"
              if not real.is_file():
                  raise SystemExit("mcl-devops does not provide bin/mcl-devops")

              print(
                  f"{len(inventory)} packages inspected; exactly one provides "
                  f"bin/mcl ({name}), and it is the failing stub (exit "
                  f"{run.returncode})"
              )
              PY
              touch $out
            '';
      };
    };
}
