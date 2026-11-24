{ inputs, ... }:
{
  # Every input this flake locks is fetched from GitHub/GitLab or from a host
  # in scripts/ci/flake-lock-allowed-hosts.txt, and never from spectrum-os.org.
  #
  # microvm.nix locks `spectrum` from spectrum-os.org. That host stopped
  # answering on 2026-11-19, and every consumer that fetches the whole lock
  # (`nix flake archive`, a cold CI store) failed with it even though nothing
  # evaluates the input. flake.nix drops it with `follows = ""`; this keeps a
  # lock update from bringing it, or another single-point host, back.
  #
  # It also checks the lock of the pinned Reprobuild. flake.nix reaches that
  # flake with `builtins.getFlake` (metacraft-github-actions
  # `pins/reprobuild.json`), so it resolves under reprobuild's own lock and no
  # `follows` from here can prune it: whatever that lock names is part of our
  # closure. The lock is read from the pinned source in the store, so the check
  # needs no network.
  #
  # Negative controls: a lock carrying the spectrum node, the same lock with
  # spectrum-os.org added to the allowlist (the deny list must still win), a
  # lock with an unlisted tarball host and a self-hosted GitLab, and, for the
  # pinned-lock exception below, another node and another host in the excepted
  # lock, the spectrum node in a lock the exception does not name, and a stale
  # exception.
  perSystem =
    { pkgs, ... }:
    let
      checker = ../scripts/ci/check_flake_lock_sources.py;
      allowlist = ../scripts/ci/flake-lock-allowed-hosts.txt;
      fixtures = ../scripts/tests/fixtures/flake-lock-sources;
      lock = ../flake.lock;
      reprobuildLock = "${inputs.reprobuild}/flake.lock";

      # The pinned reprobuild (d1bf1f065ac) predates reprobuild PR #526, "fix(flake):
      # drop microvm's spectrum input from the devops-modules closure" (merge
      # commit df1df9e276a8f6b916efaa29552c6f27a9c26e6c on `agents`), so its
      # lock still names microvm's `spectrum` input from spectrum-os.org. Nothing
      # evaluates that input, and `getFlake` fetches inputs lazily, so it is
      # fetched only by a whole-closure `nix flake archive` of reprobuild.
      #
      # REMOVE this exception when `pins/reprobuild.json` moves to a revision
      # that contains df1df9e. The checker reports it as stale once the pinned
      # lock no longer has the node, so this check fails until it is deleted.
      pinnedLockException = "${reprobuildLock}:spectrum:spectrum-os.org";
    in
    {
      checks.flake-lock-sources =
        pkgs.runCommand "flake-lock-sources" { nativeBuildInputs = [ pkgs.python3 ]; }
          ''
            set -euo pipefail
            fail() { echo "[flake-lock-sources][FAIL] $1" >&2; exit 1; }

            echo "[flake-lock-sources] this repo's flake.lock and the pinned reprobuild's"
            python3 ${checker} --allowlist ${allowlist} \
              --exception ${pinnedLockException} ${lock} ${reprobuildLock}

            echo "[flake-lock-sources] negative control: spectrum-os.org is refused"
            if python3 ${checker} --allowlist ${allowlist} ${fixtures}/spectrum.lock 2>err; then
              fail "a lock fetching from spectrum-os.org passed"
            fi
            grep -q "node 'spectrum' (locked) fetches from spectrum-os.org, which is denied" err \
              || { cat err >&2; fail "the spectrum node was not named"; }

            echo "[flake-lock-sources] negative control: listing spectrum-os.org does not admit it"
            { cat ${allowlist}; echo spectrum-os.org; } > widened.txt
            if python3 ${checker} --allowlist widened.txt ${fixtures}/spectrum.lock 2>err; then
              fail "an allowlist entry overrode the spectrum-os.org denial"
            fi

            echo "[flake-lock-sources] negative control: unlisted hosts are refused"
            if python3 ${checker} --allowlist ${allowlist} ${fixtures}/unlisted-host.lock 2>err; then
              fail "a lock fetching from unlisted hosts passed"
            fi
            grep -q "example.org, which is not allowlisted" err || { cat err >&2; fail "example.org not named"; }
            grep -q "gitlab.example.org, which is not allowlisted" err || { cat err >&2; fail "self-hosted GitLab not named"; }

            echo "[flake-lock-sources] positive control: listing the hosts admits them"
            { cat ${allowlist}; echo example.org; echo gitlab.example.org; } > widened.txt
            python3 ${checker} --allowlist widened.txt ${fixtures}/unlisted-host.lock \
              || fail "allowlisted hosts were refused"

            echo "[flake-lock-sources] negative control: the exception admits one node from one host"
            cp ${fixtures}/pinned-extra-sources.lock pinned.lock
            if python3 ${checker} --allowlist ${allowlist} \
                --exception pinned.lock:spectrum:spectrum-os.org pinned.lock 2>err; then
              fail "an excepted lock with another denied node and an unlisted host passed"
            fi
            grep -q "node 'spectrum-mirror' (locked) fetches from spectrum-os.org, which is denied" err \
              || { cat err >&2; fail "a second spectrum-os.org node was admitted by the exception"; }
            grep -q "example.org, which is not allowlisted" err \
              || { cat err >&2; fail "an unlisted host in the excepted lock was admitted"; }
            if grep -q "node 'spectrum' " err; then
              cat err >&2; fail "the excepted node was reported"
            fi

            echo "[flake-lock-sources] negative control: the exception does not reach another lock"
            cp ${fixtures}/spectrum.lock pinned-spectrum-only.lock
            if python3 ${checker} --allowlist ${allowlist} \
                --exception pinned-spectrum-only.lock:spectrum:spectrum-os.org \
                pinned-spectrum-only.lock ${fixtures}/spectrum.lock 2>err; then
              fail "spectrum in a lock the exception does not name passed"
            fi
            grep -q "^${fixtures}/spectrum.lock: node 'spectrum' (locked) fetches from spectrum-os.org, which is denied" err \
              || { cat err >&2; fail "spectrum in this repo's lock was admitted"; }
            if grep -q "^pinned-spectrum-only.lock:" err; then
              cat err >&2; fail "the excepted lock was reported"
            fi

            echo "[flake-lock-sources] negative control: an unused exception is stale"
            if python3 ${checker} --allowlist ${allowlist} \
                --exception ${lock}:spectrum:spectrum-os.org ${lock} 2>err; then
              fail "an exception matching nothing passed"
            fi
            grep -q "exception for node 'spectrum' from spectrum-os.org is stale" err \
              || { cat err >&2; fail "the stale exception was not named"; }
            if grep -q "Pin the input to GitHub/GitLab" err; then
              cat err >&2; fail "a stale exception alone printed the remedy for a bad source"
            fi

            echo "[flake-lock-sources][PASS]"
            touch $out
          '';
    };
}
