# Building Blocks

A baseline is composed of building blocks. Each block is a self-contained piece of configuration — the objects it creates, the settings you can change, and the device scope it applies to. Blocks declare what they need (products, permissions, other blocks) and the app wires them together.

## Where blocks come from

The app ships the blocks that carry **no configuration opinions of their own** — Foundation plus the connector-style blocks you configure entirely yourself:

| Built-in block | Creates | Risk |
| --- | --- | --- |
| **Foundation** | Categories, device groups and extension attributes the opinionated blocks rely on. Added automatically when a selected block depends on it; captured blocks that carry their own groups and categories do not need it. | Low |
| **App Catalog** | Apps from Jamf's App Catalog, installed and kept up to date automatically — no packaging. Pick apps with the built-in picker. | Medium |
| **Jamf Protect Baseline** | Endpoint security to a safe starting point: telemetry, alert forwarding, an exception set, and a plan in report-only mode. Needs a connected Jamf Protect tenant. | High |
| **Security Cloud** | Connects Jamf Security Cloud to the tenant (UEM Connect) and creates a Mac activation profile. Needs a Security Cloud entitlement. | Medium |

Opinionated configuration — what your FileVault, enrollment or update policy should look like — comes from catalogs you follow: capture blocks from a tenant, or publish a catalog repository for your team. Tenants pin the release tag they use, so a published update never changes a tenant until you opt in. The **[demo catalog](https://github.com/JordyThery/jamf-deployer-catalog)** is a worked example and the template for publishing your own.

## The demo catalog

| Block | Creates | Risk |
| --- | --- | --- |
| **Enrollment** | A computer PreStage for Automated Device Enrollment: supervised, MDM non-removable, consumer setup panes skipped. | Medium |
| **FileVault** | FileVault with an individual recovery key escrowed to Jamf Pro, enforced by a login policy on the chosen scope. | Medium |
| **Software Updates** | Declarative software-update settings via a Jamf Blueprint: automatic download and install, with deferral windows you control. | Medium |
| **Compliance — CIS Level 1** | A compliance benchmark built from the CIS Level 1 baseline. Starts in monitor mode: it reports, it does not change devices. | High |
| **Rosetta 2** | A script plus check-in policy that installs Rosetta 2 on Apple silicon Macs so Intel-only apps keep working. | Low |
| **Check-in & Inventory** | Check-in frequency, whether startup and login run policies, and what inventory Macs report. Tenant-wide setting. | Low |
| **Re-enrollment** | What Jamf Pro clears when a Mac enrolls again, so reused Macs start with a clean record. Tenant-wide setting. | Low |
| **Local Admin Password Rotation** | Rotates managed local admin passwords on a schedule and after each viewing. Tenant-wide setting. | Medium |
| **Self Service App** | Installs Self Service on every Mac; landing page and notifications. Tenant-wide setting. | Low |
| **Self Service Maintenance** | "Update inventory" and "Flush DNS cache" items users run when support asks. | Low |
| **macOS Version Groups** | Smart groups for Macs on the current macOS and Macs below your supported minimum. | Low |

The built-in App Catalog block picks its apps with a searchable picker — searchable, with per-app delivery and update behavior:

![The App Catalog picker: searchable app list on the left, per-app delivery and update choices on the right](screenshot-app-catalog.png)

![The baseline editor: blocks with checkboxes and settings, the last deploy result, and the adopt and hand-over actions](screenshot-baseline.png)

## Settings and scope

Every block exposes a small set of plain-language settings — toggles, choices, numbers — defined by the block, not by the underlying provider schema. Secret-typed settings (API keys and similar) are stored in your Keychain, never in the tenant record.

Scope is chosen per block from Foundation's groups: **Pilot**, **All Managed Macs**, **Laptops**, **Desktops** or **Apple Silicon Macs**. New selections start on Pilot unless the block sets its own default. Blocks that only support smart groups (App Catalog apps) only offer those. Captured blocks that keep their original wiring carry their own scope instead.

## Removing blocks

Deselecting a block offers two choices. **Remove from Tenant** deletes the block's objects from Jamf on the next deploy — except tenant-wide settings (check-in, re-enrollment, Self Service and similar), which keep their current values because Jamf has no "empty" state for them. **Stop Managing** leaves everything in Jamf untouched and only stops tracking it. Either way the preview shows exactly what will happen.

A tenant-wide setting can belong to one block only: selecting two blocks that manage the same setting stops the preview with a message naming both.

## Presets

Presets come from the catalogs you follow. The demo catalog ships three:

- **Standard** — foundation, enrollment, FileVault, software updates, CIS Level 1 (monitor), Rosetta 2.
- **Minimal** — foundation and software updates; a starting point to grow from.
- **Complete** — everything in the demo catalog: Standard plus the tenant settings, Self Service maintenance and macOS version groups.

A preset is just a starting selection. Everything stays editable afterwards.

## Baseline updates

Blocks are versioned. When a tenant's catalog source publishes a newer release, **Baseline Updates…** lists what changed per block, and you opt blocks into the newer version individually — each update then goes through the normal preview before it can deploy.

## Making your own blocks

Three ways:

1. **Capture from a tenant.** Export an object (or a set of objects) from any connected tenant; the app turns it into a block and saves it to a catalog source of yours. One export can be captured as a single block or **split into several** — define the blocks, assign each object to one, and the app captures them all from the same export. Captured blocks are marked for review until you approve them. A captured block is meant for *other* tenants: in its origin tenant the objects already exist, so use **Adopt** there instead (the editor warns about this).

   Captured blocks **keep their wiring**: a policy keeps its category, scripts, packages and scope groups, and smart groups keep the extension attributes their criteria name. When an export is split, each block declares what it needs from the others; the baseline editor warns when a selected block's dependencies are not covered, and the preview refuses to run until they are. Names that start with the tenant's prefix are parameterized so they follow each tenant's own prefix; a capture option can apply the prefix to every object name. PreStage enrollments stay in the capture: they attach to the deploying tenant's Automated Device Enrollment instance through an editable block setting (the instance name), so the tenant only needs its own ADE token uploaded. PreStages that enable Recovery Lock have it turned off, because Jamf never exports the password. Objects that cannot move between tenants — Self Service icons, enrollment invitations, Jamf's built-in All Managed groups, default allowed file extensions, the cloud distribution point, Jamf Patch reporting attributes, compliance benchmarks, values Jamf does not export (activation code, GSX and volume purchasing tokens) and a login page without disclaimer text — are left out automatically, each with a warning that says why. Settings-style types (check-in, re-enrollment, Self Service and the like) can be exported on their own or together with anything else. An alternative capture option collapses scope groups and categories onto Foundation; everything else (scripts, packages, extension attributes) stays wired between blocks either way.
2. **Duplicate a built-in.** Built-in blocks are read-only — they ship inside the app and update with it. **Duplicate to My Blocks** in a block's detail view copies it into one of your sources under a new ID, where everything is editable.
3. **Author by hand.** A block is a folder with a `block.json` manifest (identity, settings, scope options, drift bindings) and the OpenTofu module that implements it. The built-in catalog in [`Catalog/blocks`](../Catalog/blocks) is the reference for the format.

Custom blocks are managed from their detail view: edit the name, summary and version in place, reveal the folder in Finder for deeper changes, or delete the block (the app warns when tenants still select it). Sources themselves are managed under **Manage Sources…** in the library's toolbar.

## Catalog sources

Blocks come from catalog sources. Besides the built-in catalog:

- **Local folder** — a folder of blocks on disk (where captured blocks land). Always used at its current content.
- **Git repository** — a repository of blocks, pinned by release tag. Tenants record the tag they use, so a published update never changes a tenant until you opt in. This is the way to share a catalog across a team or publish one publicly.

On conflicting block IDs the built-in catalog always wins; custom blocks are used only where a tenant explicitly selects them.
