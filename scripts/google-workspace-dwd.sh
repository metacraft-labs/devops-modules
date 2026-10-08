#!/usr/bin/env bash
# Google Workspace Admin API access through a service account with domain-wide
# delegation (DWD): every gcloud step of docs/Google-Workspace-Admin-API-Access.md
# as one tool, so the only manual step left is the delegation approval in the
# Admin console (Google publishes no API for it).
#
#   google-workspace-dwd setup     --project ID [--organization ORG | --folder F] [--sa NAME] [--scopes S,...]
#   google-workspace-dwd seal-key  --project ID [--sa NAME] --recipients FILE --out PATH.age
#   google-workspace-dwd verify    --key FILE --subject USER [--scope S]
#   google-workspace-dwd keys      --project ID [--sa NAME]
#   google-workspace-dwd delete-key --project ID [--sa NAME] KEY_ID
#
# Run `gcloud auth login` first, as someone who may create projects in the
# organisation (or use an existing project) and administer its service accounts.
#
# setup is idempotent: it creates the project only if it does not exist, enables
# the Admin SDK and Gmail APIs, creates the service account only if missing,
# reports whether the organisation policy that blocks key creation applies, and
# prints the numeric client id, the full scope list and the console page where a
# super admin approves them.
#
# seal-key keeps the plaintext key only on tmpfs, in a 0700 directory, for the
# moment between gcloud writing it and age sealing it to the recipients file (one
# age or SSH public key per line); it is shredded on every exit path. It prints
# the new key's id for the operator's record, never its content.
#
# Scopes are short names (admin.directory.user) or full URLs. The default list
# is the least a Workspace user/group automation needs; pass --scopes to change it.
set -euo pipefail

die() {
  echo "google-workspace-dwd: $*" >&2
  exit 1
}

default_scopes="admin.directory.user,admin.directory.group,admin.directory.domain.readonly"
sa_name="workspace-admin"

full_scope() {
  case "$1" in
    https://*) printf '%s' "$1" ;;
    *) printf 'https://www.googleapis.com/auth/%s' "$1" ;;
  esac
}

full_scopes() {
  local IFS=, out="" s
  for s in $1; do
    [ -n "$s" ] || continue
    out="${out:+$out,}$(full_scope "$s")"
  done
  printf '%s' "$out"
}

sa_email() { printf '%s@%s.iam.gserviceaccount.com' "$sa_name" "$project"; }

cmd="${1:-}"
[ -n "$cmd" ] || die "usage: google-workspace-dwd setup|seal-key|verify|keys|delete-key ... (see the header of this script)"
shift

project="" organization="" folder="" scopes="$default_scopes" recipients="" out="" key="" subject="" scope=""
positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) project="${2:?}"; shift 2 ;;
    --organization) organization="${2:?}"; shift 2 ;;
    --folder) folder="${2:?}"; shift 2 ;;
    --sa) sa_name="${2:?}"; shift 2 ;;
    --scopes) scopes="${2:?}"; shift 2 ;;
    --recipients) recipients="${2:?}"; shift 2 ;;
    --out) out="${2:?}"; shift 2 ;;
    --key) key="${2:?}"; shift 2 ;;
    --subject) subject="${2:?}"; shift 2 ;;
    --scope) scope="${2:?}"; shift 2 ;;
    --*) die "unknown option $1" ;;
    *) positional+=("$1"); shift ;;
  esac
done

need_project() { [ -n "$project" ] || die "--project is required"; }

case "$cmd" in
  setup)
    need_project
    if gcloud projects describe "$project" --format='value(projectId)' >/dev/null 2>&1; then
      echo "project $project exists"
    else
      parent=()
      if [ -n "$organization" ]; then
        parent=(--organization "$organization")
      elif [ -n "$folder" ]; then
        parent=(--folder "$folder")
      else
        die "project $project does not exist; pass --organization or --folder to create it under the organisation (not a personal project)"
      fi
      gcloud projects create "$project" "${parent[@]}" --name "Workspace Admin API" >/dev/null
      echo "created project $project"
    fi
    gcloud services enable admin.googleapis.com gmail.googleapis.com --project "$project" >/dev/null
    echo "enabled admin.googleapis.com, gmail.googleapis.com"
    if gcloud iam service-accounts describe "$(sa_email)" --project "$project" >/dev/null 2>&1; then
      echo "service account $(sa_email) exists"
    else
      gcloud iam service-accounts create "$sa_name" --project "$project" \
        --display-name "Workspace Admin API (domain-wide delegation)" >/dev/null
      echo "created service account $(sa_email)"
    fi
    client_id="$(gcloud iam service-accounts describe "$(sa_email)" --project "$project" --format='value(uniqueId)')"
    enforced="$(gcloud resource-manager org-policies describe iam.disableServiceAccountKeyCreation \
      --project "$project" --effective --format='value(booleanPolicy.enforced)' 2>/dev/null || true)"
    if [ "$enforced" = True ]; then
      echo "NOTE: iam.disableServiceAccountKeyCreation is enforced for $project; seal-key will be refused"
      echo "      until an organisation policy admin exempts this project, or use the keyless route."
    fi
    cat <<EOF

Approve the delegation (a super admin, once):
  1. open https://admin.google.com/ac/owl/domainwidedelegation and click "Add new"
  2. Client ID:   $client_id
  3. OAuth scopes (paste as one line):
     $(full_scopes "$scopes")
  4. Authorise. It takes effect within minutes, occasionally up to 24 hours.
EOF
    ;;

  seal-key)
    need_project
    [ -n "$recipients" ] && [ -s "$recipients" ] || die "--recipients FILE (one public key per line) is required"
    [ -n "$out" ] || die "--out PATH.age is required"
    [ ! -e "$out" ] || [ "${FORCE:-0}" = 1 ] || die "$out exists; FORCE=1 replaces it (then delete the old key, see 'keys')"
    mkdir -p "$(dirname -- "$out")"
    before="$(gcloud iam service-accounts keys list --iam-account "$(sa_email)" --project "$project" \
      --managed-by user --format='value(name.basename())' | sort)"
    work="$(mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/google-workspace-dwd.XXXXXX")"
    chmod 0700 "$work"
    trap 'shred -u "$work/key.json" 2>/dev/null; rm -rf -- "$work" "$out.tmp"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    gcloud iam service-accounts keys create "$work/key.json" --iam-account "$(sa_email)" \
      --project "$project" --quiet >/dev/null 2>&1 ||
      die "creating the key failed (is iam.disableServiceAccountKeyCreation enforced? see 'setup')"
    age -R "$recipients" -o "$out.tmp" "$work/key.json" || die "sealing the key failed"
    shred -u "$work/key.json"
    [ -s "$out.tmp" ] || die "gcloud produced no key"
    mv -f -- "$out.tmp" "$out"
    after="$(gcloud iam service-accounts keys list --iam-account "$(sa_email)" --project "$project" \
      --managed-by user --format='value(name.basename())' | sort)"
    new_id="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)"
    echo "sealed a new key for $(sa_email) to $(grep -c . "$recipients") recipient(s): $out"
    echo "key id: ${new_id:-<see 'keys'>}"
    ;;

  verify)
    [ -n "$key" ] && [ -r "$key" ] || die "--key FILE (the decrypted service-account JSON) is required"
    [ -n "$subject" ] || die "--subject USER (the impersonated admin) is required"
    SA_KEY="$key" ADMIN_USER="$subject" SCOPE="$(full_scope "${scope:-admin.directory.user}")" python3 - <<'PY'
import os, sys
from google.oauth2 import service_account
from google.auth.transport.requests import AuthorizedSession
from google.auth.exceptions import RefreshError
creds = service_account.Credentials.from_service_account_file(
    os.environ["SA_KEY"], scopes=[os.environ["SCOPE"]]).with_subject(os.environ["ADMIN_USER"])
try:
    r = AuthorizedSession(creds).get(
        "https://admin.googleapis.com/admin/directory/v1/users",
        params={"customer": "my_customer", "maxResults": 1})
except RefreshError as e:
    print(f"token refused: {e.args[0] if e.args else e}", file=sys.stderr)
    print("  unauthorized_client: delegation not approved yet, wrong client id, or a scope outside the approved list", file=sys.stderr)
    print("  invalid_grant: --subject is not a user of the tenant, or the key is not this service account's", file=sys.stderr)
    sys.exit(1)
if r.status_code == 200 and "users" in r.json():
    print(f"ok: listed users as {os.environ['ADMIN_USER']} with {os.environ['SCOPE']}")
else:
    print(f"HTTP {r.status_code}: {r.text[:300]}", file=sys.stderr)
    sys.exit(1)
PY
    ;;

  keys)
    need_project
    gcloud iam service-accounts keys list --iam-account "$(sa_email)" --project "$project" --managed-by user
    ;;

  delete-key)
    need_project
    [ ${#positional[@]} -eq 1 ] || die "usage: google-workspace-dwd delete-key --project ID KEY_ID"
    gcloud iam service-accounts keys delete "${positional[0]}" --iam-account "$(sa_email)" --project "$project" --quiet
    echo "deleted key ${positional[0]}"
    ;;

  *) die "unknown command $cmd" ;;
esac
