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

Time: about ten minutes. One command creates everything on the Google Cloud
side (§3); the delegation approval is the one console step (§4), because Google
publishes no API for it.

## 1. What this gives you, and what it does not

**Covered by the APIs** (with the matching scope approved; a short scope name
`x` stands for `https://www.googleapis.com/auth/x`):

| Task                                                                                | API                      | Scope                                                        |
| ----------------------------------------------------------------------------------- | ------------------------ | ------------------------------------------------------------ |
| Create, suspend and update users; aliases; reset passwords                          | Admin SDK Directory      | `admin.directory.user`                                       |
| Custom admin roles and their assignment (e.g. creating the automation admin itself) | Admin SDK Directory      | `admin.directory.rolemanagement`                             |
| Groups and memberships                                                              | Admin SDK Directory      | `admin.directory.group`                                      |
| Read domains, org units                                                             | Admin SDK Directory      | `admin.directory.domain.readonly`, `admin.directory.orgunit` |
| Per-user Gmail settings: send-as, filters, forwarding, IMAP                         | Gmail API (as that user) | `gmail.settings.basic`, `gmail.settings.sharing`             |
| Insert a message into a user's mailbox                                              | Gmail API (as that user) | `gmail.insert`                                               |
| The `googleworkspace` Terraform provider                                            | the above                | whatever its resources need                                  |

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

## 3. Create the project and the service account: `google-workspace-dwd setup`

Every Google Cloud step is one command from this repository's
`google-workspace-dwd` package. Sign in once as someone who may create projects
in the organisation and administer service accounts, then run it:

```sh
gcloud auth login
nix run github:metacraft-labs/devops-modules#google-workspace-dwd -- setup \
  --project <project-id> --organization <org-id> \
  --scopes admin.directory.user,admin.directory.group,admin.directory.domain.readonly
```

(An infra repo wraps this in a `just` recipe with its own values; `--folder`
instead of `--organization` puts the project in a folder. The organisation id is
`gcloud organizations list`.)

Add `--grant-policy-admin` the first time in an organisation that still has
Google's default key-creation policy (step 5). Behind the scenes, and safe to
re-run — each step is skipped when already done:

1. **Project.** `gcloud projects create <id> --organization <org>`, if
   `gcloud projects describe` does not find it. The project belongs to the
   organisation, not to the person running it. No billing account is needed: the
   Admin SDK and Gmail APIs are free.
2. **APIs.** `gcloud services enable admin.googleapis.com gmail.googleapis.com orgpolicy.googleapis.com`.
3. **Service account.** `gcloud iam service-accounts create workspace-admin`
   (`--sa` changes the name). It needs **no** IAM role on the project: domain-wide
   delegation is granted in the Workspace Admin console, not in IAM.
4. **Client id.** The service account's numeric `uniqueId` — the "Client ID" the
   Admin console asks for. It is not the service account's email address.
5. **Key-creation policy.** Organisations created since 2024 enforce
   `iam.disableServiceAccountKeyCreation` and its newer twin
   `iam.managed.disableServiceAccountKeyCreation` by default, and either one
   refuses `seal-key`. Unless `--keyless` is given, `setup` enables the
   Organization Policy API and writes a **project-level** policy with
   `enforce: false` for each enforced constraint, so the organisation's default
   stays in force everywhere else. Writing it needs `roles/orgpolicy.policyAdmin`
   on the organisation, which an organisation admin does **not** hold by default:
   with `--grant-policy-admin`, `setup` grants it to the signed-in account (an
   organisation admin may) and retries; without it, `setup` stops and prints the
   one `gcloud organizations add-iam-policy-binding` command to run. The grant
   stays on the account — remove it afterwards if your policy says so.
   Policy and IAM changes take a minute or more to reach the IAM API; `setup` and
   `seal-key` retry while they propagate.
6. **Client id and scopes.** It prints the numeric client id and the scope line
   for §4.

All gcloud calls run with prompts disabled, so a missing API fails with an
error instead of waiting for a "y/N" nobody sees.

## 4. Approve the delegation (Admin console, super admin)

1. Admin console → **Security → Access and data control → API controls →
   Manage Domain Wide Delegation** (<https://admin.google.com/ac/owl/domainwidedelegation>).
2. **Add new**: Client ID = the numeric id `setup` printed; OAuth scopes = the
   comma-separated full scope URLs from §2. **Authorise.**
3. If the impersonated user is a dedicated automation admin, create it now:
   **Account → Admin roles → Create new role** with only the needed privileges,
   assign it to the user, and enrol the user in 2-Step Verification (it never
   signs in interactively for API work, but the tenant may require it).

The approval takes effect within minutes, occasionally up to 24 hours.

## 5. Create and seal a key: `google-workspace-dwd seal-key`

Only when the caller needs a key (§2):

```sh
nix run github:metacraft-labs/devops-modules#google-workspace-dwd -- seal-key \
  --project <project-id> --recipients <recipients-file> --out <secrets-dir>/service-account.json.age
```

`<recipients-file>` holds one age or SSH public key per line — the people (user
keys) and, where needed, CI identities that must use the key; never a host that
does not run the automation. Behind the scenes:

1. It refuses to overwrite an existing `--out` unless `FORCE=1` (a rotation).
2. `gcloud iam service-accounts keys create` writes the new key into a 0700
   directory on tmpfs (`$XDG_RUNTIME_DIR`); `age -R <recipients-file>` seals it to
   `--out`; the plaintext is shredded immediately and on every exit path.
3. It prints the new **key id** (the difference between the key list before and
   after), never the key. Record the id in the overlay: rotation needs it.

Use the sealed key only decrypted for a session or a job, on tmpfs, mode 0600,
and remove it afterwards — never in a working tree, even a gitignored one.

## 6. Verify: `google-workspace-dwd verify`

With the key decrypted for the session:

```sh
nix run github:metacraft-labs/devops-modules#google-workspace-dwd -- verify \
  --key <decrypted service-account.json> --subject automation-admin@<domain>
```

Behind the scenes it mints a token **as** `--subject` for one scope
(`admin.directory.user` unless `--scope` says otherwise — it must be **exactly**
one of the approved scopes; `admin.directory.user` does not imply
`admin.directory.user.readonly`) and lists one user of the tenant. It prints
`ok: …` on success. The usual failures:

| Error                                            | Cause                                                                                                                             |
| ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| `unauthorized_client`                            | Delegation not approved yet, wrong client ID (email instead of numeric ID), or a scope requested that is not in the approved list |
| `403 Not Authorized to access this resource/api` | The impersonated user lacks the admin privilege for the call                                                                      |
| `invalid_grant: Invalid email or User ID`        | `sub` is not a user in the tenant                                                                                                 |
| `accessNotConfigured`                            | The API is not enabled in the service account's project                                                                           |

## 7. Rotate and revoke

- **Rotate the key:** `FORCE=1 google-workspace-dwd seal-key …` creates and
  seals a new key over the old sealed file; switch every consumer to it; then
  `google-workspace-dwd keys --project <id>` lists the keys and
  `google-workspace-dwd delete-key --project <id> <old-key-id>` deletes the old
  one. Deleting the key is what revokes it; removing a sealed file does not.
- **Revoke everything:** delete the delegation entry in the Admin console (all
  tokens for every user stop working within minutes), then delete or disable the
  service account.
- Audit: Admin console → **Reporting → Audit and investigation** shows the
  impersonated user as the actor for every change made through delegation.
