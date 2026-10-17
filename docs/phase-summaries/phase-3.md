# Phase 3 — Day 0 wizard (U2) and App Catalog picker

Date: 2026-10-17 · Builds clean · JamfDeployerCore: 19 tests pass · Live-verified against the demo tenant: Day 0 detection + actions, App Catalog search, and an App Installer deployed through the app ("JD - Google Chrome", 1 succeeded / 0 failed).

## 1. What was built

### Day 0 setup (direct API, deliberately outside the engine)
These items carry Apple tokens and secrets that renew yearly and would otherwise show up as constant drift — exactly as the brief prescribed.
- **`Day0Service`**: detection + actions, every request body verified against the OpenAPI spec via the Jamf Developer MCP before coding:
  - APNs — no public read endpoint exists (re-confirmed), so it's a guided manual step: deep link to Jamf Pro (the tenant's real URL is fetched from `/v1/jamf-pro-server-url`), completion date recorded in tenant.json.
  - ADE — detects instances + token expiry; downloads the public key (`application/x-pem-file`) for upload to Apple Business Manager; accepts the returned `.p7m` and posts `{tokenFileName, encodedToken(base64)}` to `/v1/device-enrollments/upload-token`.
  - VPP — detects locations + expiry; accepts a `.vpptoken` and posts `{name, serviceToken}` (file content is already the base64 token).
  - Self Service branding — detects; creates a minimal macOS branding (`applicationName`/`brandingName`/`homeHeading`). Icon/banner upload (multipart `/self-service/branding/images`) is schema-verified but deferred to a polish pass.
  - SSO — reads `/v3/sso` and reports enabled/not, with a deep link (assist-level, as briefed).
  - Jamf Protect — detects an existing registration; links one via `/v1/jamf-protect/register` `{protectUrl(…/graphql), clientId, password}`, prefilled from the tenant's stored Protect connection, and stores the credentials back (Keychain for the secret).
  - Cloud Services Connection — status probe (the App Catalog needs it).
- **Setup tab** on every tenant (segmented Overview / Day 0 Setup): each step shows green/amber status with a plain-language explanation, action buttons (file importers/exporters for the Apple artifacts), **Skip for Now** / Unskip (persisted), and a Check Again button. Fully re-runnable.
- `JamfPlatformClient` gained POST-JSON and raw-Accept download support (same retry/logging path).

### App Catalog (U-part of the baseline)
- **`app-catalog` building block** (tofu-validated): one `jamfplatform_pro_app_installer` per selected app via `jsondecode(var.apps_json)` — the App Installers **resource** confirmed in Phase 0 is now in real use; deployments are fully engine-managed (drift, removal, history like everything else).
  - Per app: delivery (`INSTALL_AUTOMATICALLY` / `SELF_SERVICE`) and updates (`AUTOMATIC` latest / `MANUAL` pinned), enums verified against the provider schema.
  - **Smart-group constraint honored**: App Installers only accept smart groups, so the block declares `smartOnly` scope — the static Pilot group is withheld from its scope picker, default is All Managed Macs.
- **Picker UI**: split view — RSQL search over title *and* publisher (debounced, paginated, icons via `iconUrl`, publisher + version shown) on the left; the selection with per-app delivery/update pickers on the right. Selections are stored as JSON in the block's setting (`AppCatalogApp` round-trip model in JamfDeployerCore, tested).
- Catalog is now 7 blocks; core tests updated (19 passing), including generator coverage for the JSON-embedded setting and the smart-only scope.

## 2. How to test manually
1. Open the **Demo (Beta)** tenant → **Day 0 Setup** tab: ADE shows connected with its 2027 expiry, SSO enabled, Cloud Services Connection established, branding **done** (created during verification as "JD Demo Org"), APNs/VPP/Protect pending with their action buttons.
2. Try "Download Public Key…" (saves the real PEM), "Skip for Now" on Protect, Check Again.
3. Overview tab → Baseline → enable **App Catalog** → **Choose Apps…** → search "chrome" or "microsoft" → add apps, set delivery/updates → Done → **Preview Changes** → the new deployments appear as Creates → Deploy.
4. In the sandbox Jamf Pro tenant: Self Service branding exists, and App Installers shows "JD - Google Chrome" (Self Service, automatic updates, scoped to JD - All Managed Macs).

## 3. Live verification results
- Day 0 detection on the demo tenant: ADE ✓ (expiry 2027-05-18), VPP pending (correct — none connected), branding pending → created → **done**, SSO **enabled**, Protect pending, CSC ✓, Jamf Pro URL resolved for deep links.
- ADE public key: real 1334-byte PEM downloaded through the service.
- App Catalog search: RSQL `titleName=="*Chrome*",publisher=="*Chrome*"` → 1 match.
- Block deploy: preview showed `[Create] JD - Google Chrome` under App Catalog; deploy 1/0. The tenant now runs a 19-object baseline.

## 4. Remaining TODO(verify) / open items
- ADE `.p7m` and VPP `.vpptoken` uploads and Protect registration are schema-verified and wired, but not live-exercised (they need real Apple/Protect artifacts and the demo tenant already has ADE). First real use will confirm; the flows surface API errors inline.
- Branding icon/banner image upload (multipart) deferred; `/v1/onboarding` kept at assist level (status + link) for now.
- APNs expiry still has no public endpoint — dashboard behavior unchanged ("check manually" + recorded date).
- Per-app Self Service categories/descriptions (`self_service_settings`) and notification settings are provider-supported but not yet surfaced in the picker.

## 5. Decisions needed
None. Phase 4 (Maintain: fleet drift checks, the three drift actions, baseline updates, rollback, Hand over, token expiry on the dashboard) is next — and the demo tenant is in the perfect state for it: a deployed baseline ready to be drifted on purpose.
