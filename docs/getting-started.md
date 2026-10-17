# Getting Started

From download to a deployed baseline in four steps.

## 1. Install

Download the latest release from the [releases page](https://github.com/JordyThery/jamf-deployer/releases/latest), open the disk image and drag **Jamf Deployer** to Applications. The app is signed and notarized; everything it needs is inside.

On first launch a guided tour points out the main areas. Revisit it any time from **Help → Guided Tour**.

## 2. Connect a tenant

You need an API client for the Jamf Platform API gateway:

1. In your Jamf tenant, create an API client and note the **client ID**, **client secret** and the tenant's **environment ID**.
2. In Jamf Deployer, click **Connect Tenant** and enter the region (US, EU or APAC), the credentials and a display name.
3. The wizard runs a preflight — authentication, API reachability, Apple push and enrollment token status — before saving anything.

The client secret goes straight into your Keychain. It is never written to a file.

Connecting a Jamf Protect tenant (for the Protect building blocks) works the same way from the tenant's settings: Protect URL, client ID and secret.

## 3. Compose a baseline

First visit to **Building Blocks**: the app ships only the Foundation block — add the **[demo catalog](https://github.com/JordyThery/jamf-deployer-catalog)** to try a full baseline (enrollment, FileVault, software updates and more, versioned by release tag). For real fleets, capture your own blocks or publish your own catalog — the demo repository is the template.

Then open the tenant's **Baseline** editor:

- Start from a preset — **Standard** (enrollment, FileVault, software updates, CIS Level 1 monitoring, Rosetta 2) or **Minimal** — or pick blocks individually.
- Each block has plain-language settings and a scope: all computers, a pilot group, or a group of your own. Production tenants default to the pilot scope.
- Blocks marked high-risk (compliance, endpoint security) start in monitor or report-only mode.

See [Building Blocks](building-blocks.md) for what each block creates.

## 4. Preview and deploy

Click **Preview Changes** (⌘P). The app generates the configuration, compares it with the tenant, and lists every object it would add, change or remove — grouped by block, with field-level detail. Nothing has happened to the tenant yet.

If the preview looks right, click **Deploy**. Only the previewed plan is applied; if anything changed in between, the deploy stops. The first deploy produces a **recovery sheet** with the passphrase that encrypts this tenant's records — store it somewhere safe. Every deploy is recorded under **History**, with rollback.

## Day 0 checklist

The **Day 0 Setup** tab tracks the things an API cannot fully do — APNs certificate, Apple Business Manager enrollment and VPP tokens, branding — with live status where Jamf exposes it and links to the right console pages where it does not.

![The Day 0 Setup tab: APNs, Automated Device Enrollment, volume purchasing, branding, single sign-on and the Jamf Protect link, each with live status](screenshot-day0.png)

## From here

- **Check for Changes** (⌘R) shows what was changed directly in Jamf since the last deploy — keep each change, restore the baseline, or stop managing the object.
- **Export** captures an existing tenant's objects as reusable blocks, documentation or a snapshot; **Adopt** brings hand-configured objects under management without recreating them.
- Working with colleagues? Set up a shared repository: [Team Mode](team-mode.md).
