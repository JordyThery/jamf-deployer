# Phase 1 — App shell and parity

Date: 2026-10-17 · Builds clean (Swift 6, strict concurrency, MainActor default isolation, macOS 15 target) · Bundle `be.jordythery.jamf-deployer`, team K3LQ9NPBMG, hardened runtime, App Sandbox off (required to run the engine), v0.1.0 (1)

## 1. What was built

### DeployerKit (local Swift package, `DeployerKit/`)
Extracted from Intune Deployer's patterns so both apps can share it (Intune Deployer was read but not modified):
- `UpdateChecker` + `UpdateView` — the GitHub Releases update flow, parameterized by `UpdateFeed(owner:repository:appName:)`. Same UserDefaults keys (`checksForUpdates`, `lastUpdateCheck`, `lastOfferedUpdate`), 24-hour automatic cadence, trusted-host checks, zip download via `.fileExporter` + reveal in Finder.
- `GuidedTour` — generic spotlight tour (`TourState<AnchorID>`, `tourAnchor(_:)`, `.guidedTour(_:)`): dim layer with rounded cutout, positioned card, first-launch detection that marks seen before starting.
- `ActivityLog` + `ActivityLogView` — capped in-memory log with the same table UI; entries gained a `category` column (API / Engine / Export) since this app logs more than HTTP.
- `KeychainItem` — the generic-password pattern (`service = <bundleID>.<purpose>`, update-then-add, never synchronized, empty deletes).
- `JSONFile` — pretty-printed, sorted-keys, atomic JSON persistence.
- Design components encoding the shared idioms: `StatusBadge` (capsule pill), `StatusIndicator` (the green/red/yellow icon set), `SheetFrame` (header/divider/content/divider/footer), `DetailHeader`.
- `TextExportDocument` for later report export.
- Swift Testing suite (version comparison, feed trust, JSON round-trip) — 4 tests pass.

**Important parity note:** Intune Deployer does **not** use Sparkle — it ships a hand-written GitHub Releases checker with a sandbox-safe "download zip and replace in Applications" flow, one stable channel, no EdDSA keys. Phase 1 mirrors that exactly (true parity). Switching to Sparkle (appcast, channels, silent install — now possible since this app is unsandboxed) is a Phase 9 decision.

### App
- **Navigation**: `NavigationSplitView` — sidebar sections Fleet (Dashboard), Tenants (+ Connect a Tenant…), Library (Building Blocks, History placeholders). Window minimum 900×560, single main window, Activity Log window on ⌘⇧L, Settings scene.
- **Menus**: App → Check for Updates…; Tenant menu with Check for Changes (⌘R), Preview Changes (⌘P), Deploy… (⌘D) — reserved and disabled until the engine phases; Help → Guided Tour.
- **Tenant model + store**: `Tenant` (region/gateway, environment vs legacy tenant scope, production flag, mode, Protect fields, catalog pins, block selections, preflight snapshot — tolerant decoding) persisted at `~/Library/Application Support/Jamf Deployer/tenants/<id>/tenant.json`; each tenant folder is a full workspace (`generated/`, `state/`, `history/`, `exports/`). Secrets per tenant in the Keychain (`…platform-client-secret`, `…protect-client-secret`, `…state-passphrase`; account = tenant UUID).
- **Jamf Platform client** (`JamfPlatformClient` actor): token endpoint with early refresh (tokens live 900 s), exactly one scope header, retry with Retry-After/backoff on 429/503/504 and transient network errors, every request logged to the activity log (never tokens/headers/bodies).
- **Connect-a-tenant wizard** (5 steps): identity (name, region, "This is a test tenant"), Jamf Account instructions with copyable permission checklist, credentials (environment vs legacy tenant scope + optional environment picker via the Organization API), optional Jamf Protect, live preflight. Tenant can't be added while credentials fail; warnings don't block.
- **Preflight** (all reads): credentials, Jamf Pro ≥ 11.31 (amber below), permission dry reads with the missing permission named in the hint, Cloud Services Connection probe (App Catalog availability), tenant-empty check that suggests Adopt when content exists. It also harvests ADE/VPP token expiry into the tenant snapshot for the dashboard.
- **Fleet dashboard**: table with name + Production/Test badge, status, Jamf Pro version, baseline (—), last deploy, ADE/VPP token expiry (yellow under 30 days), search, "Needs attention" filter, empty-state with Connect button. Check-all is disabled with a tooltip until Phase 4.
- **Tenant detail**: connection box, preflight results with Run Preflight, baseline placeholder.
- **Guided tour**: 8 Jamf-specific steps (fleet, tenants, blocks, preview-then-deploy, history/activity, test-tenant suggestion), first-launch + Help replay.
- **Settings**: auto-update toggle, engineer name (for history), **Show technical details** (off by default — also gates the Phase 0 engine window, now a scene `Engine (technical)`), built-in tool versions (OpenTofu 1.13.1, jamfplatform 1.5.0, jamfprotect 0.12.0, jamformer 0.6.0).
- **App icon** installed from the provided artwork (masked to the macOS squircle grid, transparent corners, all 10 slots).
- `Vendor/fetch.sh`: pinned, checksum-verified re-fetch of all vendored binaries (binaries stay out of git — decision #3).

## 2. How to test manually
1. Build & run (⌘R). First launch shows the guided tour; replay via Help → Guided Tour.
2. Fleet shows the empty state → **Connect a Tenant…** → walk the wizard (sandbox credentials are in the Keychain under `JamfDeployer-Spike` / `JamfDeployer-Demo`; both are US region, environment scope). Watch preflight stream its checks.
3. The new tenant appears in the sidebar and dashboard with version + token expiry columns filled from preflight.
4. Open the tenant → Run Preflight re-runs and updates the stored snapshot.
5. ⌘⇧L shows every API call with status and duration.
6. App menu → Check for Updates… (feed `JordyThery/jamf-deployer` has no releases yet — expect the friendly failure; the mechanism itself is live-verified below).
7. Settings → toggle Show technical details → the Engine (technical) window exposes the Phase 0 spike (init/preview/deploy against `Spike/live-sandbox`).

## 3. Live verification results (headless harness using the real app code)
- Sandbox environment: credentials ✓, 11.33.0 ✓, all four permission probes ✓, Cloud Services Connection ✓, "already has configuration (61 objects) — consider Adopt" ⚠ (correct), ADE 2027-06-04 / VPP 2027-06-04 harvested.
- Empty demo environment: **all checks green**, "tenant looks empty — a clean start", ADE 2027-05-18, no VPP (handled).
- Organization API with an environment-scoped integration: 403 → friendly fallback copy. **Phase 0 TODO resolved: the environment picker requires an organization-scope integration; manual entry is the default path.**
- Update feed mechanism against a real GitHub feed (intune-deployer, pretending v0.0.1): detects v1.3.0 and its zip asset. ("Updates itself" ends at the deliberate manual-replace flow — see parity note.)

## 4. Remaining TODO(verify) / open items
- Granted-permission introspection: unchanged (dry reads are the mechanism; the token carries no scope list).
- Permission checklist in the wizard is the connect-time read set; per-block permissions get aggregated from the catalog in Phase 2.
- `ASSETCATALOG_COMPILER_APPICON_NAME` had to be set by hand in Xcode (the MCP build-settings tool rejected the key).
- DeployerKit currently builds inside Jamf Deployer's repo; adopting it from Intune Deployer is a later, separate change there.
- App-target unit tests need a test target (pbxproj change) — engine parser tests ride in DeployerKit for now; a proper `Jamf DeployerTests` target is worth adding in Phase 2 (ask me to guide you through adding it, or add it when convenient).

## 5. Decisions made / needed
- **Made:** GitHub-releases updater for parity instead of Sparkle (brief's Sparkle assumption didn't match Intune Deployer reality); binaries out of git with `Vendor/fetch.sh`; demo credentials stored in Keychain (`JamfDeployer-Demo`), screenshots kept on disk per your request.
- **Needed from you:** none to start Phase 2. Optional: create the public `jamf-deployer` GitHub repo when you want real update checks to succeed, and consider a test target for the app.
