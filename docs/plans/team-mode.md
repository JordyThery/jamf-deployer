# Team mode design (Phase 8) — agreed 2026-10-17

## Decisions
- **Git (GitHub) is the one team backend.** S3/azurerm dropped; the storage layer stays thin enough for a native backend to return later.
- **Every store is a Git repo** from now on, remote or not: solo users get free local versioning; team mode is "add a remote". Requires git (ships with Xcode CLT); a missing git degrades to today's plain-folder behavior with a notice.
- Live verification against a private GitHub repo created via the authenticated `gh` CLI.

## Store layout (a working copy)
```
Application Support/Jamf Deployer/store/        ← git repo
  store.json          manifest {schemaVersion, createdBy}
  tenants/<id>/
    tenant.json       synced
    adopted/          synced
    state/            synced (encrypted via TF_ENCRYPTION; backups/ too)
    history/<ts>/     synced (append-only, conflict-free by construction)
    generated/        NOT synced (.gitignore — regenerated every run)
    exports/          NOT synced
  presets/            synced (team presets)
  catalog-sources.json synced
  locks/<tenant-id>.json  lock records
  .gitignore
```
Never in the repo: secrets (Keychain only), engine binaries, Terraform download, plan.bin. A joining engineer sees "credentials needed on this Mac" per tenant (existing preflight messaging) and fills the Keychain once.

## Locking: Git push as compare-and-swap
- **Acquire**: `pull --rebase` → write `locks/<tenant>.json` `{engineer, host, acquiredAt, operation}` → commit → push. Push success = lock held; rejection = fetch and show the holder ("Being deployed by Jamie on Jamie's MacBook").
- **Run**: engine operates on freshly pulled state.
- **Release**: commit workspace changes (state, history, tenant.json) + delete the lock, push. Structured messages: `Deploy Demo (Beta): 1 added · 2 changed — Jordy`.
- **Stale locks**: age shown; "Break Lock…" requires typing the tenant name; records the break in the commit message.
- Engine runs in team mode require connectivity; reading/browsing works offline. Sole writer of state is the lock holder, so state never merge-conflicts; history is per-run folders (append-only); tenant.json conflicts resolve by rebase, and when a real conflict appears the operation aborts cleanly before the engine ever runs.

## Switch-over (Settings → Team)
- **Create a team space**: preconditions (no busy runs, git present) → zip backup of the store → ensure repo + initial commit → `git remote add` + push → verified round-trip → on.
- **Join a team space**: clone into a fresh store → manifest version check → import local tenants one-by-one (each a commit; ID conflicts skip with a message) → previous store kept as backup.
- **Leave team mode**: remove the remote; everything stays local. The zip backup is the universal escape hatch.
- Git auth: system git (child process) — SSH or HTTPS; PATs stored as a Keychain item, injected via askpass env for HTTPS.

## Remaining Phase 8 scope, in order
1. GitStoreService (init/commit/pull/push/lock CAS) + store migration + solo auto-repo.
2. Team wizard (create/join/leave) + sync on every engine operation + lock indicators (dashboard + tenant).
3. Shared settings = files in the repo (presets, catalog sources, engineer name).
4. Schema-driven object editor (tofu providers schema → form) for tenant overrides.
5. Support bundle (redacted logs + versions).
6. Accessibility + polish pass; localisation readiness.
Signed catalog verification → Phase 9 (meets catalog CI and Git tags).
