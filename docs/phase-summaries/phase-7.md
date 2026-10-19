# Phase 7 — Jamf Protect and Security Cloud

Date: 2026-10-17 · Builds clean · JamfDeployerCore: 32 tests pass · Live verification was **strictly read-only** against the production Protect tenant (user mandate) — data-source-only plans and jamformer exports, zero writes.

## 1. What was built

### Protect provider wiring
- `WorkspaceGenerator` emits the **jamfprotect** provider (pinned 0.12.0, installed from the bundled mirror) whenever a selected block declares the `jamf-protect` product — tested.
- `TenantDeployService` injects `JAMFPROTECT_URL` / `JAMFPROTECT_CLIENT_ID` / `JAMFPROTECT_CLIENT_SECRET` from the tenant's Protect connection (URL/client ID from tenant.json, secret from the Keychain) only when Protect blocks are in the baseline; a missing connection fails before any engine run with a plain-language pointer to Day 0 Setup.

### protect-baseline block (authored + tofu-validated; deliberately not applied anywhere)
Telemetry (core categories; network telemetry an opt-in setting), action configuration forwarding all alert severities to Jamf Protect cloud, an empty named exception set, and a plan tying them together — **"Report only" by default** (the monitor-first philosophy), tamper prevention blocking, agent auto-update on. Settings: threat mode, reporting interval, auto-update, network telemetry. Validation surfaced that `report_os_version` is deprecated (always collected) — removed.

### security-cloud-activation block (authored + validated)
A self-contained starter: one macOS activation profile with content-controls/network-security capability toggles — the enrollment entry point for Security Cloud. Marked with an entitlement note in block.json and README.

### Entitlement and connection messaging
- Error translation now carries the **live-captured** not-entitled error (`[TENant_NOT_FOUND] No tenant found for environment …` from `/securitycloud/v2/…`) → "This environment does not include Jamf Security Cloud" with a remove-the-block hint; plus a Protect-connection-missing translation.
- Deploying Security Cloud blocks on an unentitled environment stops with that message and affects nothing else.

### Protect exports
- Export tab gains a **"From: Jamf Pro and Platform / Jamf Protect"** picker (Protect enabled once the tenant has a Protect connection); `JamformerRunner` authenticates Protect exports against the console URL with the Protect API client. Protect object types load into the same checklist (18 types).

## 2. How to test manually
1. Tenant with a Protect connection (Day 0 Setup → Link Jamf Protect) → Baseline → select **Jamf Protect Baseline** → settings show Report-only default → Preview (against a *test* Protect tenant: Deploy; against production: don't).
2. Export tab → From: **Jamf Protect** → tick `plans` etc. → Export → capture/snapshot/doc flows work identically.
3. Select **Security Cloud Activation** on an unentitled tenant → Preview fails with "This environment does not include Jamf Security Cloud" and the hint.

## 3. Read-only live verification
- **Protect provider end to end** (a production Protect tenant): a data-source-only plan — structurally incapable of writing — authenticated and read **3 plans, 1 action configuration, 1 exception set, 1 telemetry configuration**. The brief's `JAMFPROTECT_*` env-var contract is confirmed real.
- **Protect export** (read-only by nature): jamformer exported all 6 objects to local files (then deleted); per-type files + import blocks as expected.
- **Security Cloud entitlement probe** (demo environment, data-source-only): captured the real 404 `[TENANT_NOT_FOUND]` error now encoded in the translation table and its test.
- An earlier wrong-URL attempt produced a clean "Jamf Protect authentication failed" — good failure behavior, no retry storms.

## 4. Remaining TODO(verify) / open items
- **protect-baseline has never been applied** (no non-production Protect tenant). The block is schema-true and validated; first apply on a test Protect tenant should be watched. Same for security-cloud-activation (no entitled environment available).
- Protect **drift/adopt** flows reuse the standard machinery but are likewise unexercised live (read-only mandate). Protect adopt would need the identity-import normalization check against jamfprotect imports — the Phase 6 normalizer handles the syntax generically.
- `jamfprotect_plans` data source attribute naming quirk noted: `action_configurations` data source exposes `action_configs` (schema fixture already knew; my first probe config didn't).
- Linking a Protect plan to devices still flows through Jamf Pro (`/v1/jamf-protect/plans/sync` + config profiles) — surfaced in the block README; a "sync plans" Day 0-style action is a good follow-up.

## 5. Decisions needed
None blocking. Next: **Phase 8 — Team mode and polish** (remote state backends with locking, shared settings bundle, schema-driven object editor, support bundle, accessibility pass). Heads-up: remote-backend verification needs an S3-compatible bucket or Azure Blob — tell me if you have one for testing, otherwise that part ships config-complete with live checks deferred (same pattern as today).

## Correction (same day): Phase 7 was not complete as first reported
The first version of this report shipped Security Cloud as an activation profile only. That left the chain dangling: in reality **UEM Connect** is how Security Cloud binds to Jamf Pro — it authenticates against the tenant, syncs devices, signals risk back, and pushes the activation profile's enrollment configuration down to Jamf Pro. Verified against Jamf's reference repo (Jamf-Concepts/terraform-jamf-platform, whose legacy `configuration-jamf-security-cloud-jamf-pro` module builds API roles + an integration by hand) and the new provider's far cleaner path: `jamfplatform_security_cloud_uem_connect` with `platform_tenant` wired from the `jamfplatform_pro_tenant_id` singleton data source — no manual API client at all.

The block is now **`security-cloud`** (replacing `security-cloud-activation`): UEM Connect (scheduled sync, risk signaling back to Jamf Pro, auth-error sync pause) **plus** the Mac activation profile, with `depends_on` ordering. Settings add risk signaling and the sync interval. Validated; still unapplied pending an entitled environment — that caveat stands and is the honest state of Security Cloud support. The reference repo's role-privilege list is kept in mind for environments where `platform_tenant` wiring isn't available (`uem_server_url` + `oauth` is the block's documented fallback, not yet parameterized).

Also reviewed on request: the `ref-jamfplatform` / `ref-jamfplatform-starter` branches (per-type file layout, support_files conventions, and the starter's "inspect cbengine rules before building the benchmark" guidance — which matches this app's benchmark block design) and the jamfprotect provider repo (already pinned at 0.12.0; schema fixture originates from its release).

## Addendum (same day)
A real Security Cloud enrollment configuration profile from a production tenant confirmed the activation-code chain: the profile embeds `https://e.wandera.com/<activation-code>` with `activationType: AP` and MDM substitution variables. The block now also outputs `enrollment_url`, and its README documents the Jamf Trust payload mapping (with placeholders — the tenant's `apiKey`/`secretKey` are secrets and were not stored; rotation was recommended since they transited a chat). Provider create/update for Security Cloud remains unverified pending an entitled environment.
