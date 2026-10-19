# Phase 2 — Catalog and deploy (U1)

Date: 2026-10-17 · Builds clean · JamfDeployerCore: 16 tests pass · Exit criterion met: the empty demo tenant reached the full baseline (18 objects, 6 blocks) through the app's own code path, drift-free afterwards ("Unchanged: 18").

*The foundation block described here was later split into the demo catalog's Device Groups, Categories and Extension Attributes blocks and made optional.*

## 1. What was built

### Catalog (`Catalog/` — the "Jamf Deployer Official" source, local for now)
Six blocks, each `block.json` + `variables.tf` + `main.tf` + `outputs.tf` + `versions.tf` + `README.md`; all six validated together with the bundled engine:
- **foundation** (always on): 4 categories, 5 device groups (static Pilot; smart All Managed Macs, Laptops, Desktops, Apple Silicon), 2 extension attributes. Outputs expose each group's Platform UUID *and* Jamf Pro ID — the dual-ID convention every other block scopes with.
- **enrollment**: ADE computer PreStage (supervised, MDM non-removable, consumer Setup Assistant panes skipped), settings for ADE instance, name, default-PreStage, auto-advance, support contact.
- **filevault**: disk-encryption configuration (Individual key, escrowed) + "Enable FileVault" login policy on the chosen scope, auth-restart setting.
- **software-updates**: Blueprint with declarative update settings via `component_blocks` (the non-deprecated shape), deferral windows and behaviour settings.
- **compliance-cis-l1**: benchmark built live from the CIS Level 1 baseline via the `cbengine` data sources, every rule enabled at baseline-recommended values, MONITOR by default (mode change recreates the benchmark — explained in the block's copy).
- **rosetta**: script + once-per-computer check-in policy, default scope Apple Silicon Macs.
- Presets: **Standard** (all six) and **Minimal** (foundation + software-updates).
- Conventions carried: `name_prefix` on every name, `managed_by_tag` provenance on every description, categories wired via `acceptsCategory`.

### JamfDeployerCore (second local package; 16 fixture-driven tests)
- Engine stream + plan models (moved from the app, made public).
- `LoadedCatalog` (catalog.json/block.json/preset parsing with tolerant decoding) — tests load the *real* repo catalog, keeping block.json honest.
- `WorkspaceGenerator`: tenant.json + catalog → `providers.tf` (pinned provider, `impact_alerts = true`, local backend into `../state/`) and `main.tf` (one module call per block; scope wiring `module.foundation.<group>_<jamf_pro_id|platform_uuid>`; category wiring; settings typed into HCL with escaping; secret settings become sensitive root variables fed by `TF_VAR_*` — never files). `materialize` copies the pinned block folders into `generated/modules/`.
- `PreviewBuilder`: show-plan JSON + stream diagnostics → changes grouped by block with labels (Create/Update/Replace/Remove/Adopt/Stop managing), field-level diffs with sensitive masking and "(decided during deploy)" for unknowns, impact alerts pinned to their object.
- `ErrorTranslation`: plain-language table for known engine/provider errors with fix-it hints; raw text stays behind "Show details".
- `DeployHistoryEntry` model (summary.json).

### App
- `TenantDeployService` (per-tenant runner map — a tenant never runs twice concurrently): regenerate workspace → init → plan (`plan.bin`) → show → Preview; Deploy applies **exactly the saved plan.bin the user approved**. Writes `history/<ts>/{plan.json, summary.json, log.jsonl}`, backs up state after every deploy, logs to the activity log, updates the tenant record.
- State passphrase: generated per tenant into the Keychain; **the first deploy is blocked until the user exports a recovery sheet** (fileExporter).
- `EngineRunner` reworked: results (events, raw lines, error diagnostics) are returned — and on failure the error carries the partial result so successes aren't lost.
- UI: Building Blocks library (cards by category, detail sheet with created objects/permissions/README), baseline editor per tenant (preset menu, prerequisite auto-select, dependents block removal, per-block settings forms + scope picker, Pilot default), Preview & Deploy sheet (plain-language phases, grouped changes, diffs, impact alerts, production typed-name guard for Remove/Replace, live apply progress, translated errors, recovery-sheet gate), History table across the fleet.
- `EngineLocator`: bundle-first lookup with a dev fallback to the repo for tofu, the provider mirror, and the catalog; writes the engine CLI config (filesystem mirror) under Application Support.

## 2. How to test manually
1. Run the app → open the **Demo (Beta)** tenant (created by the verification run — it's real and fully deployed).
2. Its Baseline box shows the Standard preset selected; open a block's **Settings…** to see forms and scope.
3. **Preview Changes** → first time the app itself runs, macOS will ask for Keychain access (Always Allow) and the recovery-sheet gate may appear (the harness and the app keep separate "recovery saved" flags) → the preview should say **Nothing to Change**.
4. Toggle a block (e.g. remove Rosetta 2) → Preview shows the removal; production tenants would demand the typed name (this one is a test tenant).
5. Sidebar → **Building Blocks** for the catalog; **History** shows the three recorded deploys (17-object first run, 1 fix-up, in-sync check); ⌘⇧L shows engine runs alongside API calls.
6. Jamf side: the demo Jamf Pro instance now shows all "JD - " objects: groups, categories, EAs, PreStage, FileVault config+policy, Blueprint, CIS benchmark (monitor), Rosetta script+policy.

## 3. Live verification notes (and two real-world finds)
- First deploy: **17 of 18 created**; rosetta's policy got a Jamf **500** that *did* create the policy server-side → retry saw **409 Duplicate name**. Cleaned the orphan via API; re-deploy created the remaining object; final state **Unchanged: 18**. Two lessons recorded:
  - Policy creation via the classic gateway can 500 transiently while still creating — "Retry failed" (Phase 4) must expect duplicates; candidate mitigations: `min_request_interval_ms` pacing or name-based adoption on 409. Known-issues list seeded.
  - The compliance benchmark auto-creates its own audit policy in Jamf Pro ("… - Tahoe Audit policy") — Jamf-managed, must be ignored by drift logic (Phase 4) and documented in the block README.
- Impact alerts with real numbers confirmed ("this policy will be scoped to 1 of 1 computers (100%)") — the demo environment has one enrolled Mac.
- State on disk is encrypted (`encrypted_data`), plan preview grouped by block exactly as designed.

## 4. Remaining TODO(verify) / open items
- Module-variable metadata: resolved pragmatically — `block.json` `settings` is the UI's source of truth, `variables.tf` the engine's; a CI linter (Phase 9) must keep them in sync. No OpenTofu CLI surface exists today for module variable metadata.
- The 500→409 policy-create behaviour deserves a retry-with-adopt strategy (Phase 4 "Retry failed").
- Catalog is a repo-local source; the Git-tag source type and catalog update badges are still to come (Phase 4 scope per brief's maintain features).
- Vendor + Catalog not yet copied into the app bundle (dev fallback paths in use) — packaging lands by Phase 9; needs a Copy Files phase (your help or scripting at archive time).
- ODV overrides for individual CIS rules (settings UI) deferred; rules currently use baseline-recommended values.

## 5. Decisions needed
None blocking. Phase 3 (Day 0 wizard + App Catalog picker) can start. Optional: delete the harness-created "Demo (Beta)" tenant from the app if you'd rather connect it manually through the wizard.
