# Phase 8 — Team mode and polish

Date: 2026-10-17 · Builds clean · JamfDeployerCore: 34 tests pass · Design agreed first (docs/plans/team-mode.md): **GitHub replaces S3/Azure as the one team backend**, every store is a Git repo, and locking rides on Git's atomic push.

## 1. What was built

### The store is a Git repository (always)
- `Application Support/Jamf Deployer/store/` is a working copy: `tenants/<id>/…`, `presets/`, `catalog-sources.json`, `locks/`, `store.json` manifest, with `generated/` and `exports/` gitignored (regenerated every run). One-time migration moves pre-existing installs into the layout automatically.
- Solo users get **free local versioning**: every deploy and drift check commits (`Deploy Demo (Beta): 1 added · 2 changed — Jordy`). Secrets stay in the Keychain — never in the repo; a joining engineer sees "credentials needed on this Mac" per tenant.

### Team mode = that repo with a remote
- **`GitStoreService`** (system git as a child process — HTTPS with gh/credential helper or SSH both work; `GIT_TERMINAL_PROMPT=0` so nothing ever hangs on an auth prompt): init, commit, pull --rebase --autostash, push with rejection detection.
- **Locking via compare-and-swap**: acquiring = committing `locks/<tenant>.json` and winning the push; losing the race rewinds the lock commit and reports the holder. Releasing commits the run's outcome (state, history, tenant.json) together with the lock removal. Stale locks: **Break Lock…** on the tenant (recorded in the commit message).
- Deploy service integration: preview acquires the tenant's lock (held through the sheet; closing without deploying releases it), deploy releases with a structured commit + push, drift checks lock/commit too. Locked tenants surface as "This tenant is being worked on by X on Y" before any engine run.
- **UI**: dashboard rows and the tenant view show "Being deployed by Jamie on Jamie's MacBook" with lock age; a Sync button pulls records + locks; Settings → Team hosts the whole lifecycle.

### Safe switch-over (Settings → Team)
- **Create Team Space**: zip backup of the store → commit → `remote add` + push → verified. **Join Team Space**: zip backup → clone to a fresh store (manifest-checked) → local tenants imported (non-conflicting IDs) and pushed → stores reloaded in place. **Leave Team Mode**: remove the remote; everything stays local. Every path starts with a full zip backup.
- Shared settings fall out of the layout: presets and catalog-source lists are files in the repo.

### Schema-driven object editor
- "Add a Custom Object…" on every tenant: the resource-type list and form are built from the live `tofu providers schema -json` (generated once into a cache from the bundled engine, both providers). Required/optional primitives render as native fields with the provider's own descriptions; sensitive attributes get secure fields; types whose required attributes need nested objects are excluded as not-yet-editable (listed honestly in the form). Output is staged into the tenant's adopted-config folder → Preview shows a Create like anything else. Technical-details toggle reveals the generated configuration.

### Support bundle + accessibility
- Settings → Diagnostics → **Create Support Bundle…**: versions, team-sync status and the activity log — never secrets, tenant records or state.
- Status indicators now carry VoiceOver labels ("Passed", "Needs attention", …); `.help()` tooltips cover the new team controls.

## 2. How to test manually
1. Settings → Team → paste an empty private repo URL → **Create Team Space** (a store zip backup lands next to the store first).
2. On a second Mac (or after Leave + Join): **Join Team Space** — tenants appear, local ones are imported.
3. Open a tenant → Preview Changes on Mac A; on Mac B the dashboard shows "Being deployed by … on …" and its own Preview refuses with the same message. Close A's sheet without deploying → B can proceed.
4. Tenant view → Break Lock… for the stale-crash case.
5. "Add a Custom Object…" → pick e.g. `pro_category` → fill name/priority → Stage → Preview shows the Create.
6. Settings → Create Support Bundle….

## 3. Live verification (real GitHub repo, two simulated engineers)
Against `github.com/JordyThery/jamf-deployer-teamspace-test` (private, created via gh):
- Team space created from the real store (2 tenants pushed); second store cloned and saw both.
- **Lock contention**: A acquired; B's acquire was correctly rejected with the holder identified ("Jordy on Mac van Jordy Thery…"); after A's release (which carried A's change, visible to B after pull) B acquired cleanly; a stale lock was broken and the break propagated.
- The push-rejection CAS path (lose the race → rewind → report holder) is the exact code the app ships.
- This Mac remains in team mode against the test repo — leave it via Settings → Team whenever you like.

## 4. Remaining TODO(verify) / open items
- Git auth relies on the Mac's existing git credentials (gh helper or SSH). A PAT-entry field with askpass injection is designed but not built — joining engineers currently need `gh auth login` or SSH set up once.
- The object editor covers primitive-attribute types only (honestly labeled); nested-object editing (e.g. whole policies) remains the domain of blocks, capture and adopt.
- Lock TTL is informational (age shown) — no auto-expiry; Break Lock is the manual escape.
- A full VoiceOver/contrast audit (the dedicated nutrition-label checks) is still worth a dedicated pass before release; this phase's sweep covered the shared components and new UI.
- The brief's S3/azurerm backends were dropped by agreement; the storage layer stays thin enough to add a native backend later.

## 5. Decisions needed
None. **Phase 9 — Public release** remains: notarisation, release feed, public catalog repo + contribution guide, catalog CI, README + third-party notices, Jamf trademark check.
