# Building Blocks

A baseline is composed of building blocks. Each block is a self-contained piece of configuration — the objects it creates, the settings you can change, and the device scope it applies to. Blocks declare what they need (products, permissions, other blocks) and the app wires them together.

## The built-in catalog

| Block | Creates | Risk |
| --- | --- | --- |
| **Foundation** | Categories, device groups and extension attributes every other block relies on. Always part of a baseline. | Low |
| **Enrollment** | A computer PreStage for Automated Device Enrollment: supervised, MDM non-removable, consumer setup panes skipped. | Medium |
| **FileVault** | FileVault with an individual recovery key escrowed to Jamf Pro, enforced by a login policy on the chosen scope. | Medium |
| **Software Updates** | Declarative software-update settings via a Jamf Blueprint: automatic download and install, with deferral windows you control. | Medium |
| **Compliance — CIS Level 1** | A compliance benchmark built from the CIS Level 1 baseline. Starts in monitor mode: it reports, it does not change devices. | High |
| **Rosetta 2** | A script plus check-in policy that installs Rosetta 2 on Apple silicon Macs so Intel-only apps keep working. | Low |
| **App Catalog** | Apps from Jamf's App Catalog, installed and kept up to date automatically — no packaging. Pick apps with the built-in picker. | Medium |
| **Jamf Protect Baseline** | Endpoint security to a safe starting point: telemetry, alert forwarding, an exception set, and a plan in report-only mode. Needs a connected Jamf Protect tenant. | High |
| **Security Cloud** | Connects Jamf Security Cloud to the tenant (UEM Connect) and creates a Mac activation profile. Needs a Security Cloud entitlement. | Medium |

The App Catalog block picks its apps with a built-in picker — searchable, with per-app delivery and update behavior:

![The App Catalog picker: searchable app list on the left, per-app delivery and update choices on the right](screenshot-app-catalog.png)

![The baseline editor: blocks with checkboxes and settings, the last deploy result, and the adopt and hand-over actions](screenshot-baseline.png)

## Settings and scope

Every block exposes a small set of plain-language settings — toggles, choices, numbers — defined by the block, not by the underlying provider schema. Secret-typed settings (API keys and similar) are stored in your Keychain, never in the tenant record.

Scope is chosen per block: **all computers**, the **pilot group**, or a device group of your own. Production tenants default to the pilot group. Blocks that only support smart groups (App Catalog apps) only offer those.

## Presets

- **Standard** — foundation, enrollment, FileVault, software updates, CIS Level 1 (monitor), Rosetta 2.
- **Minimal** — foundation and software updates; a starting point to grow from.

A preset is just a starting selection. Everything stays editable afterwards.

## Baseline updates

Blocks are versioned. When a tenant's catalog source publishes a newer release, **Baseline Updates…** lists what changed per block, and you opt blocks into the newer version individually — each update then goes through the normal preview before it can deploy.

## Making your own blocks

Three ways:

1. **Capture from a tenant.** Export an object (or a set of objects) from any connected tenant; the app turns it into a block — parameterizing names, categories and scope — and saves it to a catalog source of yours. Captured blocks are marked for review until you approve them. A captured block is meant for *other* tenants: in its origin tenant the objects already exist, so use **Adopt** there instead (the editor warns about this).
2. **Duplicate a built-in.** Built-in blocks are read-only — they ship inside the app and update with it. **Duplicate to My Blocks** in a block's detail view copies it into one of your sources under a new ID, where everything is editable.
3. **Author by hand.** A block is a folder with a `block.json` manifest (identity, settings, scope options, drift bindings) and the OpenTofu module that implements it. The built-in catalog in [`Catalog/blocks`](../Catalog/blocks) is the reference for the format.

Custom blocks are managed from their detail view: edit the name, summary and version in place, reveal the folder in Finder for deeper changes, or delete the block (the app warns when tenants still select it). Sources themselves are managed under **Manage Sources…** in the library's toolbar.

## Catalog sources

Blocks come from catalog sources. Besides the built-in catalog:

- **Local folder** — a folder of blocks on disk (where captured blocks land). Always used at its current content.
- **Git repository** — a repository of blocks, pinned by release tag. Tenants record the tag they use, so a published update never changes a tenant until you opt in. This is the way to share a catalog across a team or publish one publicly.

On conflicting block IDs the built-in catalog always wins; custom blocks are used only where a tenant explicitly selects them.
