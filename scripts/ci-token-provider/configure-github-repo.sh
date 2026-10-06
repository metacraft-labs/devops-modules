#!/usr/bin/env bash
# Configure one repo with the CI-token-provider App secrets.
#
# Usage: CTP_APP_ID=<id> CTP_KEY_AGE=<file> CTP_AGE_IDENTITY=<key> \
#          configure-github-repo.sh <owner/repo>
#
# The company-specific values (App ID, key file, identity, and the repo
# list) come from the calling infra repo. See ./lib.sh for the knobs.

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

if [[ $# -ne 1 ]]; then
  echo "usage: CTP_APP_ID=.. CTP_KEY_AGE=.. CTP_AGE_IDENTITY=.. $0 <owner/repo>" >&2
  exit 2
fi

pem=$(ctp_decrypt_private_key)
printf '%s' "$pem" | ctp_apply_to_repo "$1"
