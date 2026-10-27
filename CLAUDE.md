# Jamf Deployer: instructions for Claude

Shared code and the standards for every app: see JTKit's CLAUDE.md and ROADMAP.md (github.com/JordyThery/JTKit, or ../JTKit in the workspace).

## What it is

A macOS app (Apple silicon, macOS 15+) for engineers who set up and look after Jamf tenants. It deploys a baseline built from building blocks, captures or adopts what a tenant already has, checks for changes made in Jamf, rolls changes out across a fleet, and can work as a team through a shared Git repository. Under the hood it drives a bundled OpenTofu with the jamfplatform, jamfprotect and jamfpro providers, plus jamformer for export and discovery.

- User docs: `README.md` and `docs/` (getting-started, building-blocks, permissions, team-mode, graduating). Current limits and what is live-verified: `docs/STATUS.md`. Point to these; don't repeat them here.
- Positioning (decided): the app is an on-ramp to Terraform/OpenTofu, not a replacement. The audience is Jamf admins who haven't adopted infrastructure as code yet. Leaving the app is a feature: no lock-in.

## How to work on it

- App-only work: open `~/Developer/Jamf Deployer/Jamf Deployer.xcodeproj` (uses the published JTKit; its Xcode notes load).
- Anything that changes JTKit: use `~/Developer/Apps.xcworkspace`. Never have the app open in both.
- Build releases from the app's own project.
- After merging into main, push main to origin straight away (keep GitHub in sync).
- After a fresh clone, run `Vendor/fetch.sh` once (pinned, checksum-verified OpenTofu, providers, jamformer, terraform-backend-git). Versions change only in that file; a jamformer bump also needs its licence checksum and the text in `JamfDeployerCore/Sources/JamfDeployerCore/Licences/`.

## Architecture

- `Jamf Deployer/API/`: `JamfPlatformClient` is a thin layer over JTKit's Platform client and token provider (Jamf Pro path mapping; one variant returns an error status instead of throwing, which preflight needs). `TenantClients` shares one client per tenant; the Connect wizard and Test Connection stay one-off. Also `PreflightService`, `Day0Service`, `ExistingObjectService`.
- `Jamf Deployer/Engine/`: `TenantDeployService` (workspace generation, plan/apply, recovery after failed creates, decisions trace), `EngineRunner`/`EngineLocator` (bundled `tofu`), `StateBackendService` (terraform-backend-git for Team Mode), `RepositoryPublisher` (Export as Terraform), `EngineOutputCleaner`.
- `Jamf Deployer/Export/`: `JamformerRunner`; `TerraformManager` downloads HashiCorp Terraform on first use, with consent, for capture and adopt (BUSL, never bundled).
- `Jamf Deployer/Stores/`: the store is a Git repo at `~/Library/Application Support/Jamf Deployer/store` (`tenants/<UUID>/tenant.json`, baselines, history, catalog sources). `GitStoreService` owns commits, the secret check and lock branches. `TenantStore`/`TenantConnection` (JTKit connections adapter), `TenantSecrets` (Keychain), `GitCatalogManager`, `CatalogSourceStore`, `ComponentUpdateChecker` (`ComponentVersion`).
- `Jamf Deployer/UI/`: SwiftUI views, `JamfDeployerTour` (guided tour).
- `JamfDeployerCore/`: local Swift package, UI-free, app-specific (not a JTKit candidate): plan and stream models, catalog models, `WorkspaceGenerator`, `BlockCapture`, `BlockModule`, `DriftModels`, `PreviewModel`, `ErrorTranslation`, `CreateFailureRecovery`, `DeleteOrderRetry`, `SecretScan`, `StandaloneExport`, `PlanRedactor`, third-party licence texts.
- `Catalog/`: built-in, configuration-free blocks. Opinionated blocks live in the separate public demo catalog repo (`JordyThery/jamf-deployer-catalog`), which versions independently of the app.
- `Templates/standalone-export/`: the repo, workflows and scripts that Export as Terraform writes. Bundled with the app, so changes ship as an app release.
- `Scripts/`: `embed-engine.sh` (build phase), `run-*-ui-tests.sh`, `catalog-test/` (Python API helpers for live checks). `Fixtures/`: real engine, jamformer and API output for tests.

From JTKit (0.10.0): `UpdateChecker`, `AboutWindow`, `SettingsWindow` with the Connections tab, `ActivityLog`/`ActivityLogWindow`, `GuidedTour`, `StatusBadge`, `SheetFrame`, `KeychainSecretStore`, `JamfPlatform.Client`, `PermissionCheck`, environments, `JamfRegion`, the token provider, `JamfClassic.errorMessage`. Extend JTKit instead of adding another copy.

Deliberate exceptions to the JTKit standards: no connection picker, no Connection menu and no "Use This Connection" (the app manages a fleet); its sidebar moves between tenants and its "Tenant" menu stays.

## Rules

- **Naming:** this is a personal project. Never name an employer, and never use "MSP" or "customer" wording anywhere: UI, code, comments, docs, presets, name prefixes. Use "engineer", "admin", "organization", "tenant", "fleet". Prefix `JD - `, preset "Standard", catalog source "Official".
- **Never auto-apply.** The app applies only the exact plan the user approved.
- **Never show the word "provider" in the UI.** A tenant's connection type ("Jamf Platform API" or "Jamf Pro API") is chosen in the Connect wizard and fixed per tenant: its state is bound to one provider's resource addresses. One dialect per tenant; jamfpro never goes through the Platform gateway.
- Jamf Pro API tenants deploy blocks through each block's `jamfpro/` module (`BlockModule` picks it). Capture, clone, Software Updates, CIS Level 1, Security Cloud and App Store blocks stay Platform-only. Moving to the Platform API is Hand Over, connect again, Adopt.
- **Secrets never reach disk or the store.** Credentials live in the Keychain and reach the engine as environment variables for one run. Never inline sensitive variables from `terraform.tfvars` into `.tf` files; adopted sensitive values go to the Keychain (block ID `_adopted`). Before every store commit, `GitStoreService` scans the whole store and stops on a finding; acknowledgements store location + rule, never the value. READMEs and screens show object + rule only, never scanned text. Background: JTKit ROADMAP, "Follow-up for Jamf Deployer after step 5".
- **Team Mode:** the team repo holds tenant records, baselines, catalog sources and history; never state, secrets or lock files. State lives on the `jamf-deployer-state` branch through the bundled terraform-backend-git; locking is the engine's own (`locks/…` branches). Encryption is OpenTofu's, with one team passphrase in each Mac's Keychain. Each engineer uses their own API client. No home-made sync, locking or crypto. Details: `docs/team-mode.md`.
- **Preserve stored data:** Keychain items under `be.jordythery.jamf-deployer.*`, `tenant.json` written byte-for-byte as before, UserDefaults keys.
- Docs: one learning path in `docs/graduating.md`; no guides that repeat each other. The exported template README covers operations only. Don't describe in docs which Jamf tool produced example content.
- Out of scope (decided): DDM status reports, device actions, inventory browsing, Jamf School, Slack notifications, data-driven list settings in blocks. Not recommended: SonarQube, a jamf-cli dependency, S3 as the default backend. No jamformer in CI for Jamf Pro API tenants.

## Engine and Jamf quirks (verified)

- Applies always run `-parallelism=1`: concurrent configuration profile creates draw 500s from Jamf (which creates them anyway), and the jamfpro plugin requires it. Reads use the default on Platform, 1 on Jamf Pro API tenants. Exported workflows: 1 for apply/destroy, 10 for plan.
- **Create 500/504 but created:** after a deploy, failed creates are looked up by planned name and become import blocks. The Classic lookups must ask for JSON (`Accept`), or JTKit gets XML and finds nothing. Not live-verified again since that fix.
- Renaming an object another block uses can make OpenTofu delete it first; Jamf answers 422 HAS_DEPENDENCIES. `DeleteOrderRetry` finishes non-deletes first, then deletes, each from a fresh plan within the approved one. Delete errors carry no address; read them from `apply_errored` events.
- `generateWorkspace` deletes `.terraform.lock.hcl` before every run: re-signed bundled providers change hashes per build.
- terraform-backend-git 0.1.12: keeps a PID file in `$TMPDIR` (the app gives it its own TMPDIR and kills leftovers on launch); a stale lock branch stops a fresh backend from reading state, so Force Unlock deletes the `locks/…` branch directly.
- jamformer 0.6.x: emits Terraform-style identity imports that fail under OpenTofu (the app normalizes them); a settings-only selection fails with "No resources to query" (retried with a helper type).
- jamfplatform: captured macOS profiles set `self_service.display_notifications` explicitly and trim trailing description whitespace. PreStages with `scope_serial_numbers = []` get a 500 on PUT; capture drops the attribute.
- Mac App Store apps without licences: Jamf returns 409 "not available for device assignment" (translated in `ErrorTranslation`).
- Classic API through the Platform gateway: `/proclassic/<resource>/…` with the Bearer token and `X-Environment-Id`. Classic deletes answer in XML. Platform OAuth tokens live 900 s.
- Jamf Pro API privileges: App Installers need Create/Read/Update/Delete **Mac Applications**; Check-in needs Read + Update Policies; enrollment blocks need Read Device Enrollment Program Instances. A missing read privilege makes the jamfpro plugin retry forever: time-box privilege probes (about 5 minutes per step). Verified lists: each block's `jamfProPermissions` and `docs/permissions.md`.
- New smart mobile groups via `/api/v1/mobile-device-groups/smart-groups` need `"siteId": "-1"`. Jamf Protect's GraphQL endpoint is `/app`, not `/graphql`.
- Security Cloud allows one UEM Connect per tenant; activation profiles can't be imported (to remove one, seed a state holding it and destroy).
- `terraform query` (Terraform ≥ 1.14) drives the exported "Not in code" check; the jamfpro plugin cannot list objects.

## Testing

- **Unit tests:** the `Jamf Deployer` scheme runs `Jamf DeployerTests`. JamfDeployerCore: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` in `JamfDeployerCore/` (the CommandLineTools toolchain intermittently can't find the TestingMacros plugin; fallback: `rm -rf .build && swift build --build-tests && swift test --skip-build`). "Run its tests" means these two.
- **UI suites (`Jamf DeployerUITests`, `Scripts/run-*-ui-tests.sh`): never run them**, and never a single UI test, unless Jordy asks for that test by name. They run live against tenants and take very long.
- When Jordy does ask for one:
  - Build the app first (the UI scheme doesn't); `touch` the test file if the bundle is stale. The app launches from the runner's sibling Debug build.
  - Credentials come from the login Keychain into `TEST_RUNNER_*` variables; secrets are pasted via the pasteboard, never logged.
  - Start the script with `nohup` and poll from separate commands; a suite killed by the tool time limit skips its cleanup.
  - UI tests share Application Support, preferences and Keychain items with the installed app. Before a run on a reset app: `defaults write be.jordythery.jamf-deployer hasSeenGuidedTour -bool true`. Reset again afterwards if Jordy wants a clean app. Ask for the screen to be left alone.
  - Fields have no accessibility labels (find by `placeholderValue`); scope sheet buttons to `app.sheets`; the save panel's default button is `OKButton`; failures print `UIDUMP` into the xcodebuild log.
  - Select catalog blocks by full description label, never by name prefix. When UI copy changes, grep the UI test target for the old string.
  - Known flakes: first launch on a reset Mac can time out enabling automation mode; clone and capture picker clicks fail as a cluster. Rerun once before suspecting the app.
  - Debug builds append decisions to `/tmp/jamf-deployer-decisions.log`.
- **Live checks** (ROADMAP step 11 and the release check): only against tenants on the local allow-list outside git; never name a real tenant in the repo. Anything not on the list is off-limits; production services are read-only (data-source plans and exports only).
  - Create only prefixed objects; destroy them afterwards, also when a step fails. Snapshot and restore tenant-wide settings. Before a destroy step, check that everything in state carries the test prefix.
  - Verify every block and object type, not a sample. Tools: `run-catalog-ui-tests.sh` (every block on both connections) and `Scripts/catalog-test/` (`purge_prefix.py` counts or deletes by prefix). Use `/usr/bin/python3`: the python.org one has no CA certificates.
  - Check a test tenant's prerequisites first: PreStage blocks need an ADE instance (the fleet suite needs one with devices), App Store blocks an Apps and Books location, Protect and Security Cloud tests an entitled tenant, a new UEM Connect a tenant without one. A Jamf Pro API client with a limited role can fail in the jamfpro plugin ("Error building jamf integration"); full Jamf Pro tests use a user account.
  - A blank test tenant may be emptied only when Jordy asks: keep objects that hold tokens (ADE instance, Apps and Books location), integrations (Protect, Security Cloud UEM Connect), built-ins, accounts and API clients, and take a jamformer export first.
  - Team Mode tests use a private throwaway repo: back up Jordy's real store first and restore it after; reset branches rather than deleting repos.

## Releasing

1. Bump `MARKETING_VERSION` and the build number and commit **before** Jordy archives. Any change to the code or `Catalog/` after signing means a new build number and a new signature.
2. `embed-engine.sh` (last build phase, `ENABLE_USER_SCRIPT_SANDBOXING = NO` on the app target) copies the engine, arm64 provider zips, `Catalog/` and `Templates/` into Resources, and signs every Mach-O inside the provider zips with the Developer ID Application identity. Notarization inspects those zips; Xcode's export re-signing can't reach inside them.
3. Jordy archives: Distribute App, Direct Distribution, and exports the stapled app to the repo root as `Jamf Deployer.app` (gitignored).
4. Check the app's `CFBundleShortVersionString` matches the tag. `ditto -c -k --sequesterRsrc --keepParent`, then `spctl -a` and `stapler validate`.
5. `gh release create vX.Y.Z <zip> --target main` (or a full SHA) on `JordyThery/jamf-deployer`. The in-app updater takes any `.zip` on the latest release; use `gh release list` to see which is latest.
6. Release notes (local, `build/release-notes-X.Y.Z.md`): professional, concise bullets, no internal detail, never mention incomplete test runs.
7. Update `docs/STATUS.md`.
8. Website: only when the app has its own page on jordythery.be and the release changes the app enough to make that page untrue or incomplete, update the page.
9. If the demo catalog changes block format, release the app first: older apps skip unreadable blocks, but can't use them.

Then follow the release gate in JTKit/ROADMAP.md.
