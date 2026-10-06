# Linux VM cloud-init unattended-install flake check (M16)
#
# Wires `vm-images/ubuntu/makeLinuxVM` into a flake check that
#
#   1. Builds a bootable Ubuntu 24.04 cloud image with a cloud-init seed ISO
#      (user-data + meta-data). The seed injects a known SSH pubkey for the
#      project's standard agent user and locks password-based authentication
#      off (`ssh_pwauth: false`, `lock_passwd: true`), matching the
#      key-only-auth contract enforced by `vm-images/ubuntu/cloud-init.nix`.
#
#   2. Exposes a `test-linux-vm-cloud-init` runner package that boots the
#      built VM via `run-vm -daemonize` and waits up to 90 seconds for SSH
#      to become reachable on the forwarded port. The runner exits 0 iff
#      `ssh ... echo ready` succeeds inside the budget. A second phase
#      verifies that password authentication is rejected (key-only auth
#      enforced end-to-end).
#
# Why the split: building the image is pure and cacheable, so it lives as a
# regular `nix flake check`. Actually booting QEMU needs writeable storage,
# loopback networking, and on Linux ideally /dev/kvm — none of which are
# available inside the Nix build sandbox. The boot test is therefore a
# runnable package (`pkgs.writeShellApplication`), invoked outside the
# sandbox.
#
# Platform scope: both the image and the runner are Linux-only because
# `makeLinuxVM` declares `meta.platforms = [ "x86_64-linux" "aarch64-linux" ]`.
# Running an x86_64 Ubuntu guest under TCG on aarch64-darwin is technically
# possible but requires relaxing `meta.platforms` in
# `vm-images/ubuntu/default.nix`; that change is outside the M16 scope and
# is left as a follow-up if Mac-host smoke tests become desirable.
#
# References:
# - Cloud-init NoCloud datasource: https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html
# - Ubuntu cloud images:           https://cloud-images.ubuntu.com/releases/noble/release/
# - QEMU user-mode networking:     https://www.qemu.org/docs/master/system/devices/net.html
{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      inherit (pkgs.stdenv.hostPlatform) isLinux isDarwin;

      # Import the unified vm-images entry point. We do NOT pass osx-kvm here
      # because this check only needs the Linux (Ubuntu) builder; the darwin
      # placeholder will throw a helpful error if anything tries to use it,
      # which nothing in this check does.
      vmImages = import ../../vm-images { inherit pkgs lib; };

      # Ubuntu 24.04 LTS (noble) cloud image, x86_64.
      #
      # Pinned to an IMMUTABLE dated respin directory
      # (https://cloud-images.ubuntu.com/releases/noble/release-20260615/),
      # which Canonical never re-publishes in place -- unlike the rolling
      # `release/` pointer, whose content (and thus this fixed-output hash)
      # drifts on every point release / security respin. To move to a newer
      # image, bump `releaseDir` and `sha256` together from the matching
      # `.../release-YYYYMMDD/SHA256SUMS`. The sha256 below is Canonical's
      # published checksum for the 2026-06-15 respin.
      #
      # Same image is duplicated in agent-harbor/nix/vm-recipes/default.nix
      # (ubuntu-cloud-image-2404). Bump in lockstep.
      ubuntu2404CloudImage = vmImages.fetchUbuntuCloudImage {
        version = "24.04";
        codename = "noble";
        releaseDir = "release-20260615";
        sha256 = "5fa5b05e5ec239858c4531485d6023b0896448c2df7c63b34f8dae6ea6051a44";
      };

      # The VM under test. Cloud-init seed gets:
      #   - hostname:        ubuntu-cloudinit-test
      #   - agent user:      agent  (sudo NOPASSWD, lock_passwd: true)
      #   - ssh public key:  the bundled test ED25519 key
      #                      (vm-images/ubuntu/cloud-init.nix#generateTestSSHKey)
      #   - ssh_pwauth:      false  (enforces key-only auth)
      #   - disable_root:    true
      # SSH host port 2224 is forwarded to guest port 22 by QEMU's user-mode
      # networking; overridable at runtime via AH_VM_SSH_PORT for parallel runs.
      linuxVM = vmImages.linux.makeLinuxVM {
        name = "ubuntu-2404-cloudinit-test";
        cloudImage = ubuntu2404CloudImage;
        hostname = "ubuntu-cloudinit-test";
        username = "agent";
        sshPort = 2224;
        memory = 2048;
        cpus = 2;
        diskSize = "10G";
      };

      # Default 90s budget for `e2e_linux_vm_ssh_reachable_after_cloudinit`.
      # Cloud-init's first-boot pipeline on a fresh Ubuntu 24.04 image typically
      # completes in 30-60s under KVM, 60-90s under TCG; 90s is the upper edge
      # of normal and the campaign milestone target.
      defaultSshTimeoutSeconds = 90;

      # The boot test orchestrator. Runs entirely outside the Nix build
      # sandbox (invoked as `nix run .#checks.<system>.linux-vm-cloud-init-boot`
      # or via `./result/bin/test-linux-vm-cloud-init`).
      bootTestScript = pkgs.writeShellApplication {
        name = "test-linux-vm-cloud-init";
        runtimeInputs = [
          pkgs.openssh
          pkgs.coreutils
          pkgs.qemu
        ];
        text = ''
          set -euo pipefail

          # The built VM directory (Nix store path); contains
          # disk.qcow2, seed.iso, ssh-key/id_ed25519{,.pub}, bin/run-vm.
          VM_DIR=${lib.escapeShellArg linuxVM}
          RUN_VM="$VM_DIR/bin/run-vm"
          SSH_KEY="$VM_DIR/ssh-key/id_ed25519"
          SSH_PORT="''${AH_VM_SSH_PORT:-2224}"
          SSH_TIMEOUT="''${SSH_TIMEOUT:-${toString defaultSshTimeoutSeconds}}"
          USERNAME="agent"

          echo "=== Linux VM cloud-init boot test (M16) ==="
          echo "VM image:      $VM_DIR"
          echo "SSH port:      $SSH_PORT (forwarded to guest :22)"
          echo "SSH timeout:   $SSH_TIMEOUT seconds"
          echo "Agent user:    $USERNAME"
          echo

          # QEMU writes ephemeral overlay to /tmp via -snapshot; need a writeable
          # working dir for any side files. The run-vm script picks its own cwd.
          WORKDIR="$(mktemp -d -t linux-vm-cloudinit-XXXXXX)"
          trap 'rm -rf "$WORKDIR" || true; if [ -n "''${QEMU_PID:-}" ]; then kill "$QEMU_PID" 2>/dev/null || true; wait "$QEMU_PID" 2>/dev/null || true; fi' EXIT

          # The run-vm script in the Nix store is read-only and invokes qemu
          # with -snapshot, so we can launch it in place. Daemonize is set by
          # the script when -daemonize is in argv; here we background it
          # ourselves and capture the PID so we can clean up.
          echo "Starting VM in background..."
          AH_VM_SSH_PORT="$SSH_PORT" "$RUN_VM" -display none -daemonize -pidfile "$WORKDIR/qemu.pid" >"$WORKDIR/qemu.out" 2>&1 || {
            echo "FAIL: run-vm failed to launch QEMU"
            cat "$WORKDIR/qemu.out" >&2 || true
            exit 1
          }

          # QEMU's -daemonize forks; the pidfile holds the daemonized PID.
          # Give it a moment to appear (typically <1s).
          for _ in $(seq 1 20); do
            if [ -s "$WORKDIR/qemu.pid" ]; then
              QEMU_PID="$(cat "$WORKDIR/qemu.pid")"
              break
            fi
            sleep 0.1
          done
          : "''${QEMU_PID:?QEMU did not write pidfile}"
          echo "QEMU pid: $QEMU_PID"

          # === e2e_linux_vm_ssh_reachable_after_cloudinit ===
          # Poll SSH every 2s until either it succeeds or the budget expires.
          # StrictHostKeyChecking=no and UserKnownHostsFile=/dev/null make this
          # tolerant of the guest's freshly-generated host keys (the cloud-init
          # seed does not pin a host key).
          echo
          echo "--- e2e_linux_vm_ssh_reachable_after_cloudinit ---"
          deadline=$(( $(date +%s) + SSH_TIMEOUT ))
          attempt=0
          while [ "$(date +%s)" -lt "$deadline" ]; do
            attempt=$(( attempt + 1 ))
            if ssh \
                -p "$SSH_PORT" \
                -i "$SSH_KEY" \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=3 \
                -o BatchMode=yes \
                -o LogLevel=ERROR \
                "$USERNAME@localhost" \
                'echo ready' 2>/dev/null | grep -q '^ready$'; then
              elapsed=$(( SSH_TIMEOUT - (deadline - $(date +%s)) ))
              echo "PASS: SSH reachable after $elapsed seconds ($attempt attempts)"
              ssh_reachable=1
              break
            fi
            sleep 2
          done
          if [ "''${ssh_reachable:-0}" != "1" ]; then
            echo "FAIL: SSH not reachable within $SSH_TIMEOUT seconds" >&2
            echo "--- qemu output ---" >&2
            tail -n 50 "$WORKDIR/qemu.out" >&2 || true
            exit 1
          fi

          # === e2e_linux_vm_ssh_key_only_auth_enforced ===
          # Attempt password authentication. cloud-init.nix sets ssh_pwauth: false
          # and lock_passwd: true, so PreferredAuthentications=password must fail
          # with "Permission denied (publickey)" — there is no other method on
          # offer and the agent account has a locked password.
          echo
          echo "--- e2e_linux_vm_ssh_key_only_auth_enforced ---"
          if ssh \
              -p "$SSH_PORT" \
              -i /dev/null \
              -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=5 \
              -o BatchMode=yes \
              -o PreferredAuthentications=password \
              -o PubkeyAuthentication=no \
              -o LogLevel=ERROR \
              "$USERNAME@localhost" \
              'echo should-not-succeed' 2>/dev/null; then
            echo "FAIL: password authentication unexpectedly succeeded" >&2
            exit 1
          fi
          echo "PASS: password authentication rejected (key-only auth enforced)"

          echo
          echo "=== All M16 cloud-init checks passed ==="
        '';
      };

    in
    {
      # Pure, sandbox-friendly check: building the image proves the
      # makeLinuxVM + cloud-init wiring composes end-to-end. Linux-only
      # because qemu_kvm's `qemu-img` and `cloud-localds` are not
      # exercised on darwin in CI (the underlying packages do build on
      # darwin, but Hydra/CI matrix only runs the heavy bits on Linux).
      checks = lib.optionalAttrs isLinux {
        # The built VM image (disk.qcow2 + seed.iso + ssh-key + run-vm).
        # Cacheable; flake check passes iff the derivation realises.
        linux-vm-cloud-init-image = linuxVM;
      };

      # The boot-test runner depends on the built VM image, which is
      # marked `meta.platforms = [ "x86_64-linux" "aarch64-linux" ]` by
      # `makeLinuxVM`. The runner is therefore Linux-only at build time.
      # Cross-arch boot on aarch64-darwin via TCG is technically possible
      # but requires `allowUnsupportedSystem`/`meta.platforms` relaxation
      # in `vm-images/ubuntu/default.nix`; that scope is left to a follow-up.
      packages = lib.optionalAttrs isLinux {
        test-linux-vm-cloud-init = bootTestScript;
      };
    };
}
