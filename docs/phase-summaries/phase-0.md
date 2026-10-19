# Phase 0 — Spike and verification

Date: 2026-10-17 · Engine: OpenTofu 1.13.1 · Providers: jamfplatform 1.5.0, jamfprotect 0.12.0 · jamformer 0.6.0 · Sandbox: Jamf Pro 11.33.0 (US region, Platform environment scope)

## 1. What was built

### Vendored engine and tools (`Vendor/`)
- OpenTofu 1.13.1 (darwin arm64 + amd64 zips, checksums verified; arm64 extracted to `Vendor/opentofu/bin/tofu`).
- Provider filesystem mirror at `Vendor/providers/registry.opentofu.org/{jamf/jamfplatform@1.5.0, jamf-concepts/jamfprotect@0.12.0}` (packed layout, SHA256-verified, both architectures).
- jamformer 0.6.0 (darwin-universal).

### Spike workspaces
*These were temporary spike workspaces and are no longer part of the repository.*
- `tofu.tfrc` — CLI config with `filesystem_mirror` + `direct { exclude }`; proven that init installs only from the mirror (negative control with a broken mirror fails; mirror installs report "unauthenticated").
- `mirror-test/` — provider install + `providers schema -json` capture.
- `engine-fixtures/` — offline cycle with `terraform_data`: encryption, forget, fixture capture.
- `live-sandbox/` — hand-written foundation + rosetta blocks plus blueprint, benchmark, prestage (var-gated), package upload (var-gated), with `run.sh` (plan/apply/refresh/destroy/output; credentials read from the login Keychain).
- `mcp.sh` — query helper for the Jamf Developer MCP over HTTPS (needs the `MCP-Protocol-Version: 2025-06-18` header or the server 500s).

### Fixtures (`Fixtures/`) — the contract for the app's parsers
- `providers-schema.json` — full `tofu providers schema -json` for both providers.
- `engine/` — plan/apply/refresh streams and `show -json` plans for create and forget, all encrypted.
- `live/` — real-tenant plan/apply/destroy streams, drift plan with field-level diffs, outputs.
- `jamf-api/` — `platform-permission-scopes.txt` (all 197 permission names from the OpenAPI security scheme), device-enrollments endpoint spec.
- `jamformer/` — `-list-resources` output for both providers (includes per-type scope + read permissions), help topics, representative export sample (provider.tf, variables, PERMISSIONS.md, import blocks, script extraction).

### Swift spike (app target, builds clean, Swift 6 strict concurrency)
- `Engine/JSONValue.swift`, `Engine/EngineStreamEvent.swift`, `Engine/PlanFile.swift` — Decodable models; **all 176 captured stream events and 5 plan files decode with 0 failures and 0 unknown event types**, including field-level drift diffs.
- `Engine/EngineRunner.swift` — actor that runs `tofu` as a child process (env-only secrets, SIGINT cancel, force-kill as a separate action) and streams decoded events. Verified live from Swift: init → plan (8 planned changes + 4 impact alerts parsed) → `show -json` decode.
- `Engine/SpikeKeychain.swift` — reads the spike credentials (generic passwords).
- `Debug/EngineDebugView.swift` — Phase 0 debug window: Init / Preview changes / Read plan / Deploy / Check for changes / Stop, with parsed event log.
- Build setting change: `ENABLE_APP_SANDBOX = NO` (a sandboxed app cannot usefully exec the engine; distribution is Developer ID + Sparkle, not App Store — see §4).

### Live verification on the sandbox (all objects destroyed afterwards)
Created, drift-tested, restored and destroyed end to end:
category, static + smart platform device groups (criteria), extension attribute, script + policy with scope (policy scoped via the group's `jamf_pro_id`), Blueprint (software update settings via `component_blocks`), CIS Level 1 compliance benchmark in MONITOR mode (rules pulled from `cbengine_baselines`/`cbengine_rules` data sources), computer prestage (against the real ADE instance), package record **with real binary upload** (`cloud_transfer_status = READY`).

Drift flow proven: rename via direct API → `tofu plan -refresh-only` reports `resource_drift` → `show -json` yields exact changed attributes → normal plan shows exactly one update ("Restore baseline") → apply reverts it.

## 2. How to test manually

CLI (no credentials needed for the first two):
1. Mirror test: `TF_CLI_CONFIG_FILE=tofu.tfrc Vendor/opentofu/bin/tofu init` → providers install from the mirror, no network.
2. Engine fixtures: same pattern with the `TF_ENCRYPTION` env from `run.sh` → encrypted state, `forget` behaviour.
3. Live sandbox: `./run.sh plan` → review → `./run.sh apply` → `./run.sh refresh` → `./run.sh destroy`. Optional gates: `TF_VAR_ade_instance_name="Apple Business Manager"`, `TF_VAR_package_path=$PWD/files/jamf-deployer-spike.pkg`.

App: build & run (⌘R) → debug window → Init → Preview changes → Read plan (decoded actions + changed attributes) → Deploy → Check for changes. First use triggers a Keychain access prompt for the spike's login Keychain items — click Always Allow.

## 3. TODO(verify) resolutions

| Item | Result |
|---|---|
| CLI-config env var | **`TF_CLI_CONFIG_FILE`**. `TOFU_CLI_CONFIG_FILE` is silently ignored by OpenTofu 1.13.1 (proven with garbage-config + broken-mirror controls). |
| Gateway hostname / IDs | One model everywhere: `https://{us\|eu\|apac}.api.jamfcloud.com`. Provider: `base_url` + `environment_id` (preferred) or `tenant_id` (legacy, mutually exclusive). jamformer 0.6.0: same (`JAMF_URL` = gateway, `JAMF_ENVIRONMENT_ID` preferred; the `apigw.jamf.com` docs are outdated). Direct API: same gateway with path prefixes `/pro/...`, `/organization/...`; token at `/auth/token` (client credentials, **expires_in 900 s** → client must auto-refresh). Verified live. |
| Scope headers | Exactly one of `X-Environment-Id` / `X-Tenant-Id` (UUID) per request — confirmed in the OpenAPI parameters and live. |
| App Installers resource | **Exists**: `jamfplatform_pro_app_installer` (+ `_settings`, title data sources) → manage deployments via Terraform; no direct-API fallback needed. `GET /pro/v1/app-installers/titles` verified live with RSQL filter + pagination (`iconUrl`, `publisher`, `version` present). 200 vs 403 works as the Cloud Services Connection preflight probe. |
| Package binary upload | **Provider uploads**: `package_file_source` (path or URL) → Cloud Distribution Point; verified live, `cloud_transfer_status = READY`; optional SHA3-512 pre-check, `stream_url_directly`. |
| ADE / VPP expiry fields | ADE `tokenExpirationDate` (API) / `token_expiration_date` (data source, verified live); VPP `tokenExpiration` (verified live). Both also available via Terraform data sources. |
| APNs expiry | **No public endpoint** in the Jamf Pro or Platform specs (only `apns-client-push-status`). Dashboard keeps "check manually". |
| Impact alerts in JSON | Confirmed: `diagnostic` warnings with `address`, `range`, `snippet`; plan-time ("cannot be determined — group created in this plan"), apply-time with counts ("scoped to 0 computers"), destroy-time ("via 1 policy"). **Provider default `min_request_interval_ms` is 0, not 100 ms** as the brief assumed. |
| State encryption | `TF_ENCRYPTION` (pbkdf2 + aes_gcm, `enforced = true`) encrypts state and plan files; verified (no plaintext in either). Note: attribute lists inside the env HCL must be newline-separated, not comma-separated. |
| removed + destroy=false | Verified: plan "1 to forget" (`forget` in `change_summary`), show actions `["forget"]`, apply "1 forgotten", object survives in the tenant. |
| Dual group IDs | `jamfplatform_device_group` → `id` (platform UUID) + `jamf_pro_id` (numeric), verified live in one deploy (UUID into blueprint/benchmark, numeric into policy scope). Jamf Pro smart/static group resources also expose `platform_id`. |
| Permission names for block.json | Authoritative sources captured: 197 scope names from the OpenAPI security scheme (`Fixtures/jamf-api/platform-permission-scopes.txt`); `jamformer -list-resources` gives per-resource-type scope + read permissions; every jamformer export writes `PERMISSIONS.md`. |
| Benchmark replace behaviour | Confirmed in schema: `enforcement_mode` immutable, `title`/`description` replace the resource; `source_baseline_id` required on create, computed on import. |
| jamformer flags | All brief-listed flags exist, plus `-compact`, `-split-by-category`, `-skip-import-blocks`, `-skip-references`, `-parallelism`, `-provider-version`, `-multi-env`. Credentials env-only by design. Terraform auto-download worked; `-terraform-path` available for the managed binary. Live export: 226 resources / 6 types, cross-references resolved, scripts extracted to `support_files/`, gitleaks secret scan ran. |

### New findings (not in the brief)
- Blueprints: top-level `software_update_settings`/`software_update` are **deprecated** in jamfplatform 1.5.0 — generate `component_blocks` instead (removal "on or after 2026-10-22"). Catalog conventions must use component blocks from day one.
- Drift noise: a category rename surfaced `resource_drift` on *referencing* objects via computed attributes (`category_name`, `profile_uuid`). The Maintain screen must classify computed-only drift separately from real admin changes.
- `platform-api=Jamf Pro API` is a distinct spec: the whole Jamf Pro API is republished behind the Platform gateway — one credential set for Terraform and all direct calls.
- The MCP server supports an `execute-request` tool (HAR format) — handy for future tooling.
- Token response carries no granted-scope list (`scope` empty) → preflight permission checks need dry reads per object type.
- Jamf CLI (github.com/Jamf-Concepts/jamf-cli, MIT) confirmed as reference for the Swift API client: same gateway auth model, `keychain:` secret refs, rate-limit backoff, structured errors.

## 4. Remaining TODO(verify) / open items
- **Organization API scope**: `/organization/v1/environments` + `/v1/tenants` exist; expected to need an organization-scope integration (env-scoped probe to be done in Phase 1; manual-entry fallback stays).
- **Module variable metadata** (settings forms): no engine command dumps module variables directly; candidate is HCL-level inspection (e.g. terraform-config-inspect approach) — decide in Phase 2.
- App Installers deployment create not yet exercised live (resource schema confirmed; needs `app_installer_settings` T&C acceptance state — Phase 3).
- jamfprotect provider: schema captured, no live checks yet (Phase 7).
- Live behaviour on Jamf Pro < 11.31 untested (no such tenant available).
- First `plan` after jamformer import showing attribute differences — to quantify during Phase 6 (Adopt).

## 5. Blockers / decisions needed
1. **Intune Deployer repo** is not in this workspace. Phase 1 needs it for the DeployerKit extraction (Sparkle feed config, tutorial, design system, activity log, report scaffolding). Please provide a local path or repo access, and list any other features to mirror.
2. **App Sandbox disabled** (required to exec the engine). This assumes Developer ID + Sparkle distribution like Intune Deployer, i.e. no Mac App Store. Confirm.
3. **Vendor binaries in git**: extracted binaries are gitignored; the verified zips (~90 MB) currently are not. Options: commit zips, or add a pinned fetch-and-verify script. Preference?
4. Spike leftovers: credentials screenshots at the repo root are gitignored but still on disk — consider deleting them now that the sandbox credentials are in the Keychain (the demo environment's screenshot is still unread/unstored).
5. Naming: per your guidance, neutral vocabulary everywhere; spike prefix is now "JD Spike - ". Default `name_prefix` for real baselines ("JD - "?) to settle in Phase 2.
