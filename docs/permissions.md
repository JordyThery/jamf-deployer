# Permissions

What each part of Jamf Deployer needs, so API clients can be scoped to least
privilege. Everything the app does runs under credentials you create — it
has no access of its own.

## Jamf Platform API client

Connecting a tenant takes one API client (client ID + secret) for the Jamf
Platform API gateway. The connect wizard's preflight probes the essentials
and names any missing privilege before you save; you can still add the tenant
and fix the integration's permissions later.

### Always needed

| Used for | Privileges |
| --- | --- |
| Connection check, Jamf Pro version | Read access to the Jamf Pro API (version endpoint) |
| Preflight | `categories:read`, `scripts:read`, `device-enrollment-program-instances:read`, `volume-purchasing-locations:read`, `applications:read` |
| Day 0 status (optional) | Read access for what each checklist row shows — server URL, Self Service branding, single sign-on, Jamf Protect integration, App Installers. Rows without access show as unknown. |

### Per building block

Each block declares the privileges it needs; the app only uses what the
tenant's baseline actually contains. Checking for changes needs only the
`read` half; deploying needs everything listed (create/read/update/delete,
or read/update for tenant-wide settings).

| Block | Privileges |
| --- | --- |
| Device Groups | `device-groups` (create/read/update/delete) |
| Categories | `categories` (create/read/update/delete) |
| Extension Attributes | `extension-attributes` (create/read/update/delete) |
| Enrollment | `prestage-enrollments` (create/read/update/delete), `device-enrollment-program-instances:read` |
| FileVault | `disk-encryption-configurations`, `policies` (create/read/update/delete) |
| Software Updates | `blueprints` (create/read/update/delete), `device-groups:read` |
| Compliance — CIS Level 1 | `compliance-benchmarks` (create/read/update/delete), `device-groups:read` |
| Rosetta 2 | `scripts`, `policies` (create/read/update/delete) |
| Check-in & Inventory | `computer-check-in`, `computer-inventory-collection-settings` (read/update) |
| Re-enrollment | `re-enrollment` (read/update) |
| Local Admin Password Rotation | `local-admin-passwords` (read/update) |
| Self Service App | `self-service` (read/update) |
| Self Service Maintenance | `scripts`, `policies` (create/read/update/delete) |
| macOS Version Groups | `device-groups` (create/read/update/delete) |
| App Catalog | `applications` (create/read/update/delete), `smart-computer-groups:read` |
| Security Cloud | `uem-connections`, `activation-profiles` (create/read/update/delete), `tenant-id:read` |
| Jamf Protect Baseline | none on the Platform client — see the Protect client below |

Picking an existing group or category in a block's settings lists them
with `computer-groups:read` and `categories:read`.

### Per feature

| Feature | Needs |
| --- | --- |
| **Export / capture blocks** | Read privileges for the object types you export — nothing is ever written during an export |
| **Adopt** | Read during discovery; the adopted objects' own create/read/update/delete on first deploy |
| **Check for changes (drift)** | The read half of the deployed blocks' privileges |
| **Day 0: ADE token upload** | Create/update for device enrollment instances |
| **Day 0: VPP token upload** | Create/update for volume purchasing locations |
| **Day 0: Protect registration** | The Jamf Pro ↔ Protect registration privilege |

## Jamf Protect API client

For tenants with a Jamf Protect connection, a second API client is created
in the **Protect console** (not Jamf Pro) and entered in the connect wizard
or Day 0 tab:

- **Read-only role** is enough for connecting, exporting Protect
  configuration and checking for changes.
- The **Jamf Protect Baseline block** additionally needs a role that can
  manage plans, telemetry, action configurations and exception sets.

Deploying the Protect plan to devices still happens through Jamf Pro's
Protect deployment sync, under the Platform client above.

## Team Mode

- Each engineer's Mac needs **push access** to the team's GitHub repository,
  with Git credentials already configured (SSH key or `gh auth login`) — the
  app never asks for Git passwords.
- Repository access is tenant-record access: names, baselines, scope IDs and
  encrypted state are visible to every collaborator. Credentials are not —
  they are end-to-end encrypted per engineer (see [Team Mode](team-mode.md)).

## On the Mac

- Secrets are stored in the **login Keychain** under the app's own items;
  nothing is shared with other apps.
- The app talks only to your Jamf tenants, your Git remotes (Team Mode and
  Git catalog sources), GitHub's public API (release and component-update
  checks) and HashiCorp's release server when you agree to the Terraform
  download for exports.
- No admin rights, no configuration profiles, no system extensions — it is
  an ordinary signed and notarized app.
