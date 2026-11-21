{ ... }:
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
  # Negative controls: a lock carrying the spectrum node, the same lock with
  # spectrum-os.org added to the allowlist (the deny list must still win), and
  # a lock with an unlisted tarball host and a self-hosted GitLab.
  perSystem =
    { pkgs, ... }:
    let
      checker = ../scripts/ci/check_flake_lock_sources.py;
      allowlist = ../scripts/ci/flake-lock-allowed-hosts.txt;
      fixtures = ../scripts/tests/fixtures/flake-lock-sources;
      lock = ../flake.lock;
    in
    {
      checks.flake-lock-sources =
        pkgs.runCommand "flake-lock-sources" { nativeBuildInputs = [ pkgs.python3 ]; }
          ''
            set -euo pipefail
            fail() { echo "[flake-lock-sources][FAIL] $1" >&2; exit 1; }

            echo "[flake-lock-sources] this repo's flake.lock"
            python3 ${checker} --allowlist ${allowlist} ${lock}

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

            echo "[flake-lock-sources][PASS]"
            touch $out
          '';
    };
}
