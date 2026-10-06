{ ... }:
{
  # CIR-M1 gate: t_garm_provider_vmharness_backend.
  #
  # WHY THIS EXISTS
  #
  #   `packages/garm-provider-vmharness/default.nix` sets `doCheck = false`, and
  #   until now the ONLY package test wired into CI was
  #   `checks/garm-provider-vmharness-windows-toolchain.nix`, which runs
  #   `go test ./internal/provider`. The whole of `internal/backend` and
  #   `internal/config` — the incus container lifecycle, the teardown path, the
  #   IP-allocation lock, the config parser — had tests that NOTHING ran. That
  #   is the same class of defect the windows-toolchain gate was written to
  #   catch, one directory over: a suite that cannot report anything.
  #
  #   CIR-M1 changes both of those packages: a `limits.cpu` cap applied
  #   pre-start, and a stop-and-wait / detach / delete teardown replacing the
  #   one-shot `incus delete --force` that produced 8786 distinct delete
  #   failures over 16 days on high-mem-server, 96.7% of them
  #   `zfs destroy ...: dataset is busy`. Those changes need a gate that runs.
  #
  # HERMETIC. The backend tests drive a MOCK `incus` — a POSIX-sh emulation
  # that persists container state, devices and status on disk — so the
  # STATELESS provider has a real backend to recompute from. No incusd, no
  # containers, no network, no KVM. The teardown tests additionally inject the
  # host's real failure text (`zfs destroy ...: dataset is busy`) and a
  # multi-poll stop settle, so the ordering and the retry ladder are exercised
  # rather than assumed.
  #
  # THE TWO EXCLUSIONS, AND WHY THEY ARE NOT A WEAKENING
  #
  #   `TestIncusGpuPassthroughSharedUserspace` and
  #   `TestIncusSharedStoresAttachStoreDisks` exercise `ShareHostNixStore`,
  #   whose `Create` path calls `resolveHostNixBinDir`. That function
  #   EvalSymlinks `/run/current-system/sw/bin/nix` and REFUSES to create the
  #   container unless it resolves into `/nix/store` — a deliberate safety
  #   property (never hand a guest a nominally shared store it cannot execute
  #   from), and one this gate must not relax.
  #
  #   `/run/current-system/sw/bin/nix` does not exist in a Nix build sandbox,
  #   so `EvalSymlinks` fails, `Create` fails, and those two tests CANNOT pass
  #   here. Note precisely what the blocker is: a RESOLVABLE host Nix client,
  #   not a WRITABLE `/nix/store` — writability is irrelevant to both tests and
  #   an earlier revision of this comment said otherwise. Verified on a NixOS
  #   host, where `/run/current-system/sw/bin/nix` does resolve into
  #   `/nix/store`, both tests PASS, so this is environmental and not a masked
  #   failure.
  #
  #   They are excluded BY NAME rather than by loosening the assertions or by
  #   adding a `t.Skip` to the tests themselves. Note what is and is not lost:
  #   they are today run by NOTHING (`doCheck = false`, and no workflow invokes
  #   `go test` for this package), so this gate strictly increases coverage —
  #   from 0 of the backend tests to all but these two. Giving
  #   `resolveHostNixBinDir` an injectable path so they can run hermetically is
  #   a worthwhile follow-up and is deliberately NOT bundled into CIR-M1.
  #
  #   `go test -skip` filters the excluded tests OUT of the run: they are not
  #   reported as SKIP and the log names neither of them. A reader of CI output
  #   would therefore have no way to know two tests were dropped, so the
  #   checkPhase ECHOES the exclusion and its reason before running. An
  #   exclusion that is only loud in the source file is not loud.
  #
  # Kept SEPARATE from the windows-toolchain gate rather than folded into it so
  # a failure names which surface broke, and so neither gate's wall-clock
  # depends on the other's.
  perSystem =
    { self', ... }:
    {
      checks.t_garm_provider_vmharness_backend =
        self'.packages.garm-provider-vmharness.overrideAttrs
          (_old: {
            doCheck = true;
            checkPhase = ''
              runHook preCheck
              go test ./internal/config
              echo "t_garm_provider_vmharness_backend: EXCLUDING 2 tests from ./internal/backend --"
              echo "  TestIncusGpuPassthroughSharedUserspace"
              echo "  TestIncusSharedStoresAttachStoreDisks"
              echo "  reason: both drive ShareHostNixStore, whose Create path resolves"
              echo "  /run/current-system/sw/bin/nix and refuses to build a container unless it"
              echo "  resolves into /nix/store. That path does not exist in a build sandbox."
              echo "  go test -skip reports nothing about filtered tests, hence this notice."
              go test ./internal/backend \
                -skip 'TestIncusGpuPassthroughSharedUserspace|TestIncusSharedStoresAttachStoreDisks'
              runHook postCheck
            '';
          });
    };
}
