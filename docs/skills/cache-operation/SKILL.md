---
name: cache-operation
description: Use when inspecting Attic or Cachix deployment cache health, proving closure substitute coverage, repairing cache misses, or handling cache token and signing-key boundaries.
---

# Cache Operation

## Prerequisites

- Know the backend, cache name, substituter URL, trusted public key, target, and
  system path.
- Treat cache tokens and signing material as secrets. Never paste bearer tokens
  into logs, issues, summaries, or skill output.
- Keep cache repair separate from target activation unless the deploy plan
  explicitly requires substitute coverage before activation.
- During M8, treat Cachix as legacy fallback. Prove Attic substitute coverage
  before approving the new cutover path.

## Commands

```sh
mcl-devops cache push-closure --backend attic --cache "$CACHE" --target "$TARGET" \
  --transport ssh --substituter "$ATTIC_SUBSTITUTER" \
  --trusted-public-key "$ATTIC_TRUSTED_PUBLIC_KEY" --require-substitute "$SYSTEM_PATH"
nix path-info --store "$ATTIC_SUBSTITUTER" --recursive "$SYSTEM_PATH" \
  --option trusted-public-keys "$ATTIC_TRUSTED_PUBLIC_KEY"
just attic-verify-host-substituters --check-env
just attic-verify-host-substituters --dry-run
just attic-verify-host-substituters --dry-run --resolve-netbird-peers
```

Use the host substituter verifier for target-side trust and netrc checks. Use
`mcl-devops cache push-closure` for controller-side cache push and closure substitute
proof.

## Workflow

1. Validate local cache variables and trusted public key.
2. Check whether the exact system path is recursively visible from the
   substituter.
3. If missing, push the closure with the expected backend and target metadata.
4. Re-run the substitute query before approving activation.
5. For target failures, run the host substituter verifier in check-env and
   dry-run modes before contacting targets.

## Evidence

- Cache backend, cache name, substituter URL, public key fingerprint or exact
  key value from the deployment manifest.
- Recursive `nix path-info --store` success for the desired system path.
- Cache push event with bytes and closure path count.
- Host verifier result with each target classified as passed, unreachable, or
  missing permissions.

## Stop And Ask

Stop before rotating cache keys, minting broad tokens, granting write access to
targets, bypassing trusted public keys, continuing after incomplete closure
coverage when the manifest requires availability, or editing encrypted secrets.

## Rollback

Cache repair rollback is usually a deploy rollback, not deletion from the
cache. If a cache key or token was rotated incorrectly, restore the previous
secret material through the repository secret workflow and redeploy trust
configuration before retrying activation.
Keep the Cachix fallback callable until the cutover gate records two successful
live canary cycles and the rollback window is closed.
