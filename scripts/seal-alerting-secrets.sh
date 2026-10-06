#!/usr/bin/env bash
# Seal the two fleet-alerting receiver secrets for a host, per the cross-company
# alerting methodology
# (metacraft-dev-guidelines/policies/alerting-methodology.md):
#
#   <service>/ntfy-config.age          — a YAML fragment carrying the ntfy topic
#                                        (+ optional Bearer access token), merged
#                                        into the alertmanager-ntfy bridge
#                                        settings via systemd LoadCredential.
#   <service>/healthchecks-ping-url.age — the off-host Healthchecks check ping
#                                        URL, read by Alertmanager via url_file.
#
# Lives in nixos-modules so every Metacraft infra repo (infra, and the blocksense
# / agent-harbor fleets) seals these the same way. It operates on the CURRENT
# repo's flake: recipients are resolved from `.#nixosConfigurations.<machine>`
# and the ciphertexts are written under that repo's secrets tree.
#
# Every value is read WITHOUT being echoed and piped straight into age — nothing
# is stored in a shell variable longer than the single pipeline, and no plaintext
# temp file is ever written.
#
# Env overrides:
#   MACHINE      target host           (default: high-mem-server)
#   SERVICE      mcl.secrets service   (default: alertmanager)
#   SECRETS_DIR  where the .age go     (default: machines/server/<MACHINE>/secrets/<SERVICE>)
#   FLAKE        flake ref to resolve  (default: .)
#   FORCE=1      overwrite existing ciphertexts (rotate)
set -euo pipefail

MACHINE="${MACHINE:-high-mem-server}"
SERVICE="${SERVICE:-alertmanager}"
FLAKE="${FLAKE:-.}"
SECRETS_DIR="${SECRETS_DIR:-machines/server/$MACHINE/secrets/$SERVICE}"

for cmd in age jq nix; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: $cmd not on PATH." >&2; exit 1; }
done

mkdir -p "$SECRETS_DIR"

recipients_file="$(mktemp)"
trap 'rm -f "$recipients_file"' EXIT
nix eval --json --apply "c: c.mcl.secrets.services.\"$SERVICE\".recipients" \
  "$FLAKE#nixosConfigurations.$MACHINE.config" | jq -r '.[]' > "$recipients_file"
if [ ! -s "$recipients_file" ]; then
  echo "error: no age recipients resolved for $FLAKE#nixosConfigurations.$MACHINE ($SERVICE)." >&2
  echo "       (is the nixos-modules pin bumped to a rev carrying the alerting module?)" >&2
  exit 1
fi
nrec="$(grep -c . "$recipients_file")"
echo "Recipients: $nrec (host key + admins) for $MACHINE/$SERVICE." >&2

seal_if_absent() {
  # $1 = target .age path ; reads its plaintext from stdin (a pipeline).
  local cipher="$1"
  if [ -s "$cipher" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "SKIP $cipher exists (FORCE=1 to rotate)." >&2
    return 1
  fi
  local tmp; tmp="$(mktemp "$cipher.tmp.XXXXXX")"
  age --encrypt --recipients-file "$recipients_file" --output "$tmp"
  chmod 0644 "$tmp"; mv "$tmp" "$cipher"
  echo "Minted $cipher for $nrec recipient(s)." >&2
  return 0
}

# ── ntfy-config: topic (required) + optional Bearer access token. The topic is
# overridden into the bridge's settings; the token (if given) becomes
# ntfy.auth.token -> `Authorization: Bearer <token>`. Assembled and encrypted in
# one pipeline so neither value lands in a plaintext file. ─────────────────────
cipher="$SECRETS_DIR/ntfy-config.age"
if [ -s "$cipher" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "SKIP $cipher exists (FORCE=1 to rotate)." >&2
else
  printf 'ntfy topic (input hidden): ' >&2
  read -rs NTFY_TOPIC; echo >&2
  [ -n "$NTFY_TOPIC" ] || { echo "error: empty topic." >&2; exit 1; }
  printf 'ntfy access token (tk_..., blank for an unprotected topic): ' >&2
  read -rs NTFY_TOKEN; echo >&2
  {
    printf 'ntfy:\n'
    if [ -n "$NTFY_TOKEN" ]; then
      printf '  auth:\n    token: %s\n' "$NTFY_TOKEN"
    fi
    printf '  notification:\n    topic: %s\n' "$NTFY_TOPIC"
  } | seal_if_absent "$cipher" || true
  unset NTFY_TOPIC NTFY_TOKEN
fi

# ── healthchecks-ping-url: the check's ping URL (contains the check UUID). ─────
cipher="$SECRETS_DIR/healthchecks-ping-url.age"
if [ -s "$cipher" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "SKIP $cipher exists (FORCE=1 to rotate)." >&2
else
  printf 'Healthchecks ping URL (input hidden): ' >&2
  read -rs HC_URL; echo >&2
  [ -n "$HC_URL" ] || { echo "error: empty URL." >&2; exit 1; }
  printf '%s' "$HC_URL" | seal_if_absent "$cipher" || true
  unset HC_URL
fi

echo >&2
echo "Next:" >&2
echo "  git add $SECRETS_DIR/*.age && git commit -m 'alertmanager: seal ntfy + Healthchecks receiver secrets'" >&2
echo "  # then deploy $MACHINE (the alerting host build is HELD until these exist)." >&2
