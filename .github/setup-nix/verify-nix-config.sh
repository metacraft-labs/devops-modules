#!/usr/bin/env bash
# Prove that the Nix configuration this action just wrote actually TOOK EFFECT.
#
# WHY THIS EXISTS
# ---------------
# The `eph-*` runner images ship Nix pre-installed. `cachix/install-nix-action`
# detects that, prints "Aborting: Nix is already installed", and exits 0 — a
# reported success that never applied `extra_nix_config`. Every later `nix`
# call in the job then dies with:
#
#     error: experimental Nix feature 'nix-command' is disabled;
#            add '--extra-experimental-features nix-command' to enable it
#
# An installer that no-ops into a broken configuration and calls it success is
# a check reporting accurately about the wrong thing. This action does not have
# that particular bug — its `Configure Nix` step writes nix.conf unconditionally,
# whether or not it installed Nix. But "we wrote a file" is not "the setting is
# in effect", and the gap between those two is exactly where the original defect
# lived. The file can silently fail to apply when:
#
#   * `XDG_CONFIG_HOME` or `NIX_CONF_DIR` points somewhere other than
#     `$HOME/.config/nix`, so the write lands where Nix will not read it;
#   * `NIX_CONFIG` is set in the environment and overrides the file;
#   * a system-level `/etc/nix/nix.conf` or the daemon rejects the setting;
#   * `nix` is not on PATH at all in the steps that follow.
#
# In every one of those cases the write "succeeds" and the job still dies later.
# So this script verifies the ENVIRONMENT, not the write.
#
# HOW IT VERIFIES
# ---------------
# Deliberately by FUNCTIONAL PROBE first, and deliberately WITHOUT passing
# `--extra-experimental-features` on the probe command line. Asking Nix to
# report its own config is circular here: `nix config show` is itself gated on
# `nix-command`, so any invocation able to answer the question has already been
# handed the feature it was asked to check for. The probes below therefore run
# a plain `nix` command that simply cannot work unless configuration alone
# enabled the feature — the same way a real later step would fail.
#
# Both probes are offline: they evaluate a literal and a zero-input local flake,
# so this never depends on a substituter, the network, or a lock file.
#
# Only after `nix-command` is proven to work from configuration alone do we call
# `nix config show` — at that point it is legitimately callable — to check the
# remaining requested features individually. That catches the partial case
# (e.g. `nix-command flakes` applied but `pipe-operators` dropped), which a
# coarse "does any nix command run" probe would wave through.
#
# SECRETS: this script never prints the contents of nix.conf, netrc, or
# NIX_CONFIG. Those carry `access-tokens` and netrc credentials. It reports only
# whether such an override is *present*, and the paths involved.

set -euo pipefail

# BEGIN portable system utility PATH bootstrap
# GitHub runner services do not necessarily inherit the same PATH as an
# interactive login shell. In particular, the native Darwin services expose
# the Nix and Bash store paths but can omit /usr/bin, where macOS provides grep,
# sed, and the other POSIX utilities used below. Preserve the runner's existing
# PATH (and therefore its selected Nix), then add the conventional immutable or
# operating-system profiles that can supply missing base utilities.
setup_nix_system_paths=(
  /usr/bin
  /bin
  /usr/sbin
  /sbin
  /run/current-system/sw/bin
  /nix/var/nix/profiles/default/bin
)
# `${a[@]+"${a[@]}"}` rather than a plain `"${a[@]}"`: on bash < 4.4 — which is
# what macOS ships as /bin/bash, and therefore what the aarch64-darwin runner
# executes this with — expanding an EMPTY array under `set -u` is a fatal
# "unbound variable" error. The contract test builds a mutation of this script
# with the path entries deleted, so the empty case is real and must stay
# runnable. The outer expansion is unquoted on purpose: that is what makes it
# vanish entirely when the array is empty, while the inner "${a[@]}" keeps every
# element individually quoted so paths containing spaces still survive.
for setup_nix_system_dir in ${setup_nix_system_paths[@]+"${setup_nix_system_paths[@]}"}; do
  if [ -d "$setup_nix_system_dir" ]; then
    case ":${PATH:-}:" in
      *":$setup_nix_system_dir:"*) ;;
      *) PATH="${PATH:+$PATH:}$setup_nix_system_dir" ;;
    esac
  fi
done
export PATH

# Check every non-shell utility this script assumes before a missing helper can
# be misreported as a missing Nix feature. `nix` has its own check below so its
# established diagnostics remain intact.
missing_setup_nix_utilities=""
for setup_nix_utility in mktemp rm cat grep sed sort tr; do
  if ! command -v "$setup_nix_utility" >/dev/null 2>&1; then
    missing_setup_nix_utilities="$missing_setup_nix_utilities $setup_nix_utility"
  fi
done
if [ -n "$missing_setup_nix_utilities" ]; then
  echo "setup-nix: FAIL: required verification utilities are not on PATH:${missing_setup_nix_utilities}" >&2
  exit 1
fi
# END portable system utility PATH bootstrap

# The feature list the caller asked for. `Configure Nix` passes the very same
# value it wrote into nix.conf, so this asserts what was REQUESTED rather than
# a second, independently drifting copy of the list.
required_features="${SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES:-nix-command flakes pipe-operators}"

diagnostics() {
  # Paths and presence flags only — never values. See the SECRETS note above.
  echo "--- setup-nix verification diagnostics ---" >&2
  echo "nix binary:        $(command -v nix 2>/dev/null || echo '<not on PATH>')" >&2
  echo "nix version:       $(nix --version 2>/dev/null || echo '<unavailable>')" >&2
  echo "HOME:              ${HOME:-<unset>}" >&2
  echo "XDG_CONFIG_HOME:   ${XDG_CONFIG_HOME:-<unset>}" >&2
  echo "NIX_CONF_DIR:      ${NIX_CONF_DIR:-<unset>}" >&2
  # Presence, not content: NIX_CONFIG may carry access-tokens.
  if [ -n "${NIX_CONFIG:-}" ]; then
    echo "NIX_CONFIG:        <set — overrides nix.conf; value withheld>" >&2
  else
    echo "NIX_CONFIG:        <unset>" >&2
  fi
  local user_conf="${XDG_CONFIG_HOME:-${HOME:-}/.config}/nix/nix.conf"
  if [ -f "$user_conf" ]; then
    # The experimental-features line carries no credentials; the rest of the
    # file does, so print only that line.
    echo "user nix.conf:     $user_conf (exists)" >&2
    echo "  experimental-features line: $(grep -E '^[[:space:]]*experimental-features' "$user_conf" 2>/dev/null || echo '<absent>')" >&2
  else
    echo "user nix.conf:     $user_conf (MISSING)" >&2
  fi
  if [ -f /etc/nix/nix.conf ]; then
    echo "system nix.conf:   /etc/nix/nix.conf (exists)" >&2
    echo "  experimental-features line: $(grep -E '^[[:space:]]*experimental-features' /etc/nix/nix.conf 2>/dev/null || echo '<absent>')" >&2
  else
    echo "system nix.conf:   /etc/nix/nix.conf (absent)" >&2
  fi
  echo "-----------------------------------------" >&2
}

fail() {
  echo "setup-nix: FAIL: $*" >&2
  diagnostics
  cat >&2 <<'EOF'

This is the "installer silently no-opped" failure class. Nix is present, this
action reported that it configured it, but the requested experimental features
are NOT in effect — so the next `nix` call in this job would have died with an
unrelated-looking error, far from the real cause.

Do NOT work around this by adding `--extra-experimental-features` to individual
nix invocations; that hides the same defect one call at a time. Fix the reason
the configuration did not apply (see the diagnostics above — most often
XDG_CONFIG_HOME/NIX_CONF_DIR pointing away from the file this action wrote, or
a NIX_CONFIG environment override).
EOF
  exit 1
}

if ! command -v nix >/dev/null 2>&1; then
  fail "nix is not on PATH after the install/configure steps"
fi

# ---------------------------------------------------------------------------
# Probe 1 — `nix-command`, from configuration alone.
#
# No `--extra-experimental-features` here, on purpose: that flag would grant
# the feature being tested and turn this into a tautology.
# ---------------------------------------------------------------------------
# stderr is captured SEPARATELY, never merged into the value. Nix writes
# warnings there routinely -- on these runners the CI user is not a trusted
# Nix user, so every restricted setting in nix.conf produces one -- and folding
# them into stdout would make the literal comparison below fail on a perfectly
# healthy runner. That mistake turns this guard into the false-alarm half of
# the very problem it exists to solve.
probe_stderr="$(mktemp)"
probe_dir=""
cleanup_setup_nix_probes() {
  if [ -n "$probe_dir" ]; then
    rm -rf "$probe_dir"
  fi
  rm -f "$probe_stderr"
}
trap cleanup_setup_nix_probes EXIT

probe_output=""
if ! probe_output="$(nix eval --raw --expr '"setup-nix-probe-ok"' 2>"$probe_stderr")"; then
  echo "setup-nix: the nix-command probe failed:" >&2
  cat "$probe_stderr" >&2
  fail "experimental feature 'nix-command' is not enabled by configuration"
fi
if [ "$probe_output" != "setup-nix-probe-ok" ]; then
  echo "setup-nix: unexpected probe output: '$probe_output'" >&2
  cat "$probe_stderr" >&2
  fail "the nix-command probe did not return its expected literal"
fi

# ---------------------------------------------------------------------------
# Probe 2 — `flakes`, from configuration alone, offline.
#
# A zero-input flake in a temp dir: no network, no substituter, no registry.
# ---------------------------------------------------------------------------
if printf '%s' "$required_features" | grep -qw flakes; then
  probe_dir="$(mktemp -d)"
  # On Darwin, mktemp commonly returns /var/folders/... even though /var is a
  # symlink to /private/var. Nix 2.31 rejects local path-flake references that
  # traverse a symlink, so canonicalize the directory before constructing the
  # path: URL. `cd` and `pwd` are Bash builtins, keeping the utility inventory
  # above complete.
  probe_dir="$(cd -- "$probe_dir" && pwd -P)"
  printf '{ outputs = _: { probe = "setup-nix-flake-ok"; }; }\n' >"$probe_dir/flake.nix"

  flake_output=""
  if ! flake_output="$(nix eval --raw --no-write-lock-file "path:$probe_dir#probe" 2>"$probe_stderr")"; then
    echo "setup-nix: the flakes probe failed:" >&2
    cat "$probe_stderr" >&2
    fail "experimental feature 'flakes' is not enabled by configuration"
  fi
  if [ "$flake_output" != "setup-nix-flake-ok" ]; then
    echo "setup-nix: unexpected flake probe output: '$flake_output'" >&2
    cat "$probe_stderr" >&2
    fail "the flakes probe did not return its expected literal"
  fi

  # Not a failure, but worth naming rather than leaving buried in stderr: when
  # the CI user is not in Nix's `trusted-users`, the daemon DISCARDS restricted
  # settings from the nix.conf this action just wrote -- `trusted-public-keys`
  # and `netrc-file` among them, which is what makes a private substituter
  # usable. That is the same "written but not in effect" gap as the one this
  # script guards, applied to a different class of setting. It is reported, not
  # enforced, because enforcing it here would fail every job on the current
  # images and that is an infrastructure decision, not this action's to make.
  if grep -q 'restricted setting and you are not a trusted user' "$probe_stderr" 2>/dev/null; then
    echo "setup-nix: NOTE — this runner's user is not a trusted Nix user, so the following"
    echo "setup-nix:        settings written to nix.conf were IGNORED by the daemon:"
    sed -n "s/.*ignoring the client-specified setting '\([^']*\)'.*/setup-nix:          - \1/p" "$probe_stderr" | sort -u
    echo "setup-nix:        Fix by adding the runner user to Nix's trusted-users on the image."
  fi
fi

# ---------------------------------------------------------------------------
# Granular check — every REQUESTED feature is actually in effect.
#
# Reached only once probe 1 proved `nix-command` works without help, so asking
# Nix to report its own configuration is no longer circular.
# ---------------------------------------------------------------------------
effective=""
if ! effective="$(nix config show experimental-features 2>/dev/null)"; then
  # `nix config show` replaced `nix show-config` in Nix 2.20; keep the older
  # spelling working so this guard does not itself become the thing that breaks
  # a pinned-older-Nix job.
  if ! effective="$(nix show-config experimental-features 2>/dev/null)"; then
    fail "could not read the effective experimental-features setting"
  fi
fi

echo "setup-nix: requested experimental-features: $required_features"
echo "setup-nix: effective experimental-features: $effective"

missing=""
for feature in $required_features; do
  if ! printf '%s' "$effective" | tr ' ' '\n' | grep -qxF "$feature"; then
    missing="$missing $feature"
  fi
done

if [ -n "$missing" ]; then
  fail "requested experimental features are not in effect:${missing}"
fi

echo "setup-nix: verified — every requested experimental feature is in effect."
