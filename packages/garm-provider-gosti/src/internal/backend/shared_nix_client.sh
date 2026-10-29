#!/bin/sh
# Render the existing daemon-client wrapper contract for each available tool.
# Both arguments are supplied by the producer, never by a workflow or guest.
set -eu
nix_bin_dir="$1"
wrapper_dir="$2"
for tool in nix nix-build nix-channel nix-collect-garbage nix-copy-closure nix-env nix-hash nix-instantiate nix-prefetch-url nix-shell nix-store; do
  target="$nix_bin_dir/$tool"
  [ -x "$target" ] || continue
  rm -f "$wrapper_dir/$tool"
  printf '#!/bin/sh\nexport NIX_REMOTE=daemon\nexec "%s" "$@"\n' "$target" > "$wrapper_dir/$tool"
  chmod 0755 "$wrapper_dir/$tool"
done
