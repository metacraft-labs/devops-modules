# Google Workspace Admin API access

Company-agnostic procedure for giving automation — Terraform, scripts, an agent
working in a developer's session — programmatic access to a Google Workspace
tenant, without a person signing in. Each infra repo keeps a thin overlay
runbook with its own facts: which tenant, which project, which scopes, where the
key is sealed.

The mechanism is a **Google Cloud service account with domain-wide delegation
(DWD)**: the service account is allowed to mint tokens _as_ a named Workspace
user, for a fixed list of OAuth scopes that a super admin approves once in the
Admin console.

Time: about fifteen minutes, all of it in two consoles.

## 1. What this gives you, and what it does not

**Covered by the APIs** (with the matching scope approved; a short scope name
`x` stands for `https://www.googleapis.com/auth/x`):

| Task                                                        | API                      | Scope                                                        |
| ----------------------------------------------------------- | ------------------------ | ------------------------------------------------------------ |
| Create, suspend and update users; aliases; reset passwords  | Admin SDK Directory      | `admin.directory.user`                                       |
| Groups and memberships                                      | Admin SDK Directory      | `admin.directory.group`                                      |
| Read domains, org units                                     | Admin SDK Directory      | `admin.directory.domain.readonly`, `admin.directory.orgunit` |
| Per-user Gmail settings: send-as, filters, forwarding, IMAP | Gmail API (as that user) | `gmail.settings.basic`, `gmail.settings.sharing`             |
| Insert a message into a user's mailbox                      | Gmail API (as that user) | `gmail.insert`                                               |
| The `googleworkspace` Terraform provider                    | the above                | whatever its resources need                                  |

**Not covered — console-only at the time of writing.** Google publishes no API
for these; they need a person, or browser automation signed in as an admin:

- approving the delegation itself (§4 below);
- generating a domain's Gmail DKIM key and starting authentication
  ([Google-Workspace-DKIM.md](./Google-Workspace-DKIM.md));
- a user's 2-Step Verification enrolment and app passwords.

Re-check this list before automating around it: Google adds Admin SDK surface
over time, and a console step that has gained an API should move into code.

## 2. Decide before you start

- **The impersonated user.** Every DWD call names a user (`sub`) the token acts
  as; the call can do at most what that user may do, intersected with the
  approved scopes. Use a **dedicated automation admin** (for example
  `automation-admin@<domain>`) holding a **custom admin role** with only the
  privileges the automation needs — not a person's account, and not a super
  admin. Gmail-API calls act as the mailbox owner instead, so they name that
  user.
- **The scopes.** Approve the smallest list that covers the tasks (§1). The
  approval is per client ID; widening it later is a one-line console edit.
- **Key or no key.** A JSON key is a long-lived bearer secret. Prefer
  **keyless** where the caller can hold a Google identity of its own: a CI job
  with Workload Identity Federation can call the IAM Credentials `signJwt`
  method on the service account and build the DWD assertion without any key
  file (it needs `roles/iam.serviceAccountTokenCreator` on the service account).
  A developer workstation or an agent session usually cannot, so it needs a key —
  sealed, and decrypted only for a session.

## 3. Create the service account (Google Cloud console)

1. Pick or create a project owned by the organisation (not a personal project):
   <https://console.cloud.google.com/projectcreate>.
2. Enable the APIs the scopes belong to — at least **Admin SDK API**
   (`admin.googleapis.com`), plus **Gmail API** (`gmail.googleapis.com`) for
   Gmail scopes:
   ```sh
   gcloud services enable admin.googleapis.com gmail.googleapis.com --project <project>
   ```
3. Create the service account. It needs **no** IAM role on the project for DWD:
   ```sh
   gcloud iam service-accounts create workspace-admin \
     --project <project> --display-name "Workspace Admin API (DWD)"
   ```
4. Read its **numeric unique ID** — the "OAuth 2 client ID" the Admin console
   asks for. It is not the email address:
   ```sh
   gcloud iam service-accounts describe \
     workspace-admin@<project>.iam.gserviceaccount.com --format 'value(uniqueId)'
   ```
5. Only if you need a key (§2): create it, seal it straight away (§5) and delete
   the plaintext.
   ```sh
   gcloud iam service-accounts keys create key.json \
     --iam-account workspace-admin@<project>.iam.gserviceaccount.com
   ```
   **If this is refused** with a constraint violation, the organisation enforces
   `iam.disableServiceAccountKeyCreation` (Google turns it on by default for
   organisations created since 2024). Either go keyless (§2) or have an
   organisation policy admin exempt this one project, and record the exemption
   in the overlay.

## 4. Approve the delegation (Admin console, super admin)

1. Admin console → **Security → Access and data control → API controls →
   Manage Domain Wide Delegation** (<https://admin.google.com/ac/owl/domainwidedelegation>).
2. **Add new**: Client ID = the numeric unique ID from §3.4; OAuth scopes = the
   comma-separated full scope URLs from §2. **Authorise.**
3. If the impersonated user is a dedicated automation admin, create it now:
   **Account → Admin roles → Create new role** with only the needed privileges,
   assign it to the user, and enrol the user in 2-Step Verification (it never
   signs in interactively for API work, but the tenant may require it).

The approval takes effect within minutes, occasionally up to 24 hours.

## 5. Keep the key sealed

- Seal the key to the people (user keys) and, where needed, CI identities that
  must use it — never to a host that does not run the automation. With
  agenix/age:
  ```sh
  age -R recipients.txt -o <secrets-dir>/service-account.json.age < key.json
  shred -u key.json
  ```
- Decrypt it only for a session or a job, onto tmpfs, with mode 0600, and remove
  it afterwards. Do not leave it in a working tree, even a gitignored one.
- Record the key ID (`gcloud iam service-accounts keys list`) in the overlay, so
  a rotation knows which key to delete.

## 6. Verify

Mint a token as the impersonated user and make one read call. Request a scope
that is **exactly** in the approved list: `admin.directory.user` does not imply
`admin.directory.user.readonly`, and asking for an unapproved scope fails the
whole token request.

```sh
SA_KEY=/path/to/unlocked/service-account.json ADMIN_USER=automation-admin@example.com \
nix shell --impure --expr '(builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem}.python3.withPackages (p: [ p.google-auth p.requests ])' \
  --command python3 - <<'PY'
import os
from google.oauth2 import service_account
from google.auth.transport.requests import AuthorizedSession
creds = service_account.Credentials.from_service_account_file(
    os.environ["SA_KEY"],
    scopes=["https://www.googleapis.com/auth/admin.directory.user"],
).with_subject(os.environ["ADMIN_USER"])
r = AuthorizedSession(creds).get(
    "https://admin.googleapis.com/admin/directory/v1/users",
    params={"customer": "my_customer", "maxResults": 1})
print(r.status_code, "users" in r.json())
PY
```

Expected: `200 True`. The usual failures:

| Error                                            | Cause                                                                                                                             |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| `unauthorized_client`                            | Delegation not approved yet, wrong client ID (email instead of numeric ID), or a scope requested that is not in the approved list |
| `403 Not Authorized to access this resource/api` | The impersonated user lacks the admin privilege for the call                                                                      |
| `invalid_grant: Invalid email or User ID`        | `sub` is not a user in the tenant                                                                                                 |
| `accessNotConfigured`                            | The API is not enabled in the service account's project                                                                           |

## 7. Rotate and revoke

- **Rotate the key:** create a new key, seal it, switch every consumer, then
  `gcloud iam service-accounts keys delete <old-key-id>`. Deleting the key is
  what revokes it; removing the sealed file does not.
- **Revoke everything:** delete the delegation entry in the Admin console (all
  tokens for every user stop working within minutes), then delete or disable the
  service account.
- Audit: Admin console → **Reporting → Audit and investigation** shows the
  impersonated user as the actor for every change made through delegation.
