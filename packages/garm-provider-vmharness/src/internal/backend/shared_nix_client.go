package backend

import _ "embed"

// sharedNixClientSetupScript is the single producer-owned wrapper renderer.
// Its arguments are the selected immutable Nix bin directory and an existing
// output directory. The local backend binds the latter to /usr/local/bin;
// the Nix package binds it to its isolated output, never to the build host.
//
//go:embed shared_nix_client.sh
var sharedNixClientSetupScript string
