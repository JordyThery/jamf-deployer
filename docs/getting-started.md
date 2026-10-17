# Getting Started

From download to a deployed baseline in four steps.

## 1. Install

Download the latest release from the [releases page](https://github.com/JordyThery/jamf-deployer/releases/latest), unzip it and drag **Jamf Deployer** to Applications. The app is signed and notarized; everything it needs is inside.

On first launch a guided tour points out the main areas. Revisit it any time from **Help → Guided Tour**.

## 2. Connect a tenant

You need an API integration for the Jamf Platform API gateway:

1. In Jamf Account, create an API integration scoped to the tenant's Platform environment and note the **client ID** and **client secret**. The wizard lists the permissions to grant (see [Permissions](permissions.md)).
2. In Jamf Deployer, click **Connect a Tenant…** and enter a display name, the region (US, EU or APAC), whether it is a test tenant, and the credentials. The wizard can look up the environment ID for you.
3. The wizard runs a preflight — credentials, Jamf Pro version, read permissions, Automated Device Enrollment and volume purchasing token expiry, and the Cloud Services Connection — and names anything missing before you save. You can still add the tenant and fix permissions later.

The client secret goes straight into your Keychain. It is never written to a file.

Connecting a Jamf Protect tenant (for the Protect building blocks) is an optional wizard step, or later from the tenant's **Day 0 Setup** tab: Protect URL, client ID and secret.

## 3. Compose a baseline

First visit to **Building Blocks**: the app ships only the configuration-free blocks (Foundation, App Catalog, Jamf Protect, Security Cloud) — add the **[demo catalog](https://github.com/JordyThery/jamf-deployer-catalog)** to try a full baseline (enrollment, FileVault, software updates, CIS Level 1, Rosetta 2, tenant settings, Self Service maintenance and macOS version groups — versioned by release tag). For real fleets, capture your own blocks or publish your own catalog — the demo repository is the template.

Then compose the baseline in the tenant's **Overview** tab:

- Start from a preset offered by your catalog — the demo catalog ships **Standard** (enrollment, FileVault, software updates, CIS Level 1 monitoring, Rosetta 2), **Minimal** and **Complete** — or pick blocks individually.
- Each block has plain-language settings and a scope — one of Foundation's groups: Pilot, All Managed Macs, Laptops, Desktops or Apple Silicon Macs. New selections start on Pilot unless the block sets its own default (App Catalog apps start on All Managed Macs).
- Blocks marked high-risk (compliance, endpoint security) start in monitor or report-only mode.

See [Building Blocks](building-blocks.md) for what each block creates.

## 4. Preview and deploy

Click **Preview Changes** (⌘P). The app generates the configuration, compares it with the tenant, and lists every object it would add, change or remove — grouped by block, with field-level detail. Nothing has happened to the tenant yet.

If the preview looks right, click **Deploy**. Only the previewed plan is applied; if anything changed in between, the deploy stops. The first deploy produces a **recovery sheet** with the passphrase that encrypts this tenant's records — store it somewhere safe. Every deploy is recorded under **History**, with rollback.

## Day 0 checklist

The **Day 0 Setup** tab tracks the things an API cannot fully do — APNs certificate, Apple Business Manager enrollment and VPP tokens, branding — with live status where Jamf exposes it and links to the right console pages where it does not.

![The Day 0 Setup tab: APNs, Automated Device Enrollment, volume purchasing, branding, single sign-on and the Jamf Protect link, each with live status](screenshot-day0.png)

## From here

- **Check for Changes** (⌘R) shows what was changed directly in Jamf since the last deploy — keep each change or restore the baseline. **Check All Tenants** on the dashboard does the same for the whole fleet. To stop managing a block's objects without touching Jamf, use **Stop Managing** in the baseline.
- **Export** captures an existing tenant's objects as reusable blocks, documentation or a snapshot; **Adopt** brings hand-configured objects under management without recreating them.
- Working with colleagues? Set up a shared repository: [Team Mode](team-mode.md).
