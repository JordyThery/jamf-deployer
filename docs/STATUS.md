# Jamf Deployer — status, limitations and uncertainties

As of 2026-10-17 (1.0.1). Consolidates the open items from every phase report and the 1.0.1 association-fidelity work.

## Never exercised live (schema-verified, validated, but unapplied)
- **protect-baseline block** — no non-production Jamf Protect tenant exists to apply it to. The provider wiring itself *is* live-verified read-only (auth + all four data sources against production).
- **security-cloud block** (UEM Connect + activation profile) — no Security Cloud-entitled environment available. The not-entitled failure path *is* live-verified and translated.
- ADE `.p7m` / VPP `.vpptoken` uploads and Protect registration in Day 0 — wired and spec-verified, needing real Apple/Protect artifacts to fire for the first time.
- Jamf Pro below 11.31 — no such tenant to test the degradation path.

## Known behavioral gaps
- **"Keep this change"** adopts the drifted value into the block's setting when the block declares a drift binding for that field; fields without a binding fall back to acknowledgment (a later deploy reverts them, and the UI says so).
- **Create-500-but-created quirk** (Jamf, seen on policies, profiles, patch titles and App Installer deployments, as 500 and 504): under parallel load Jamf sometimes reports a server error after creating the object. Deploys run four operations at a time (measured: roughly half the failures of the engine default of ten, ~20% slower). After a deploy, each failed create is looked up by its planned name; objects Jamf did create — and that the state does not already track — become import blocks, so the next preview adopts them instead of hitting a duplicate. Ambiguous duplicate names are left for review rather than guessed. Live-verified: recovered objects adopted, the rest created, no duplicates left in Jamf.
- **Baseline updates are per-block for Git-tag catalog sources** (tenants pin tags; blocks can opt into newer tags individually). Local-folder sources are always "latest", so updates there remain all-or-nothing.
- **CIS benchmark ODVs** use baseline-recommended values; per-rule overrides aren't editable yet.
- **Adopt**: provenance-tagged objects are detected and excluded by default, but re-binding them to their blocks (after state loss) isn't built; adopted root objects can't be individually stop-managed yet; composite-identity imports would pass through unnormalized (none exist in today's providers).
- **Object editor** handles primitive attributes only (honestly labeled in the UI).
- Day 0: branding icon/banner upload (multipart) and full onboarding config are assist-level; APNs expiry has no public API anywhere (manual date).
- Drift noise classification is a curated attribute list — new computed attributes would initially show as actionable.

## Team mode caveats
- Git auth assumes the Mac has gh/SSH credentials configured; an in-app PAT flow is designed, not built.
- Lock expiry is manual (age shown + Break Lock); no auto-TTL.
- Join-time tenant ID conflicts are skipped, not merged.
- Repo access = access to all tenant records (names, scope IDs, encrypted state). Secrets are never in the repo in the clear: Share Credentials seals them per engineer (Curve25519 + ChaCha20-Poly1305) into `team/secrets/`, and private keys stay in each engineer's Keychain.
- Two operations on one tenant from the *same* Mac are guarded only by the engine's state lock.

## Ejecting to plain OpenTofu
Live-verified: `tenants/<id>/generated/` + `state/` + the env vars (`JAMFPLATFORM_*`, `TF_ENCRYPTION` with the recovery-sheet passphrase) run under vanilla OpenTofu ≥ 1.13 with providers from the public registry once the copied lock file is removed (it records the bundled, re-signed provider checksums). After a one-time decrypt with OpenTofu, HashiCorp Terraform 1.16 plans the same state with "No changes". The ejector owns the HCL from then on. A one-click "Export as standalone configuration" bundle is planned.

## Packaging and release
- 1.0 shipped signed and notarized (Developer ID, hardened runtime); the embed script signs the provider binaries inside the mirror archives at build time.
- No app-target unit tests (needs a test target added in Xcode); JamfDeployerCore carries 68 tests, DeployerKit 4.
- App Sandbox is off by design (child-process engine); Developer ID + notarisation is the distribution model.

## Adopting an existing tenant
- Live-verified on a content-rich tenant: all 99 exporter types discovered (494 objects), 487 adopted with an import-only preview (no creates or deletes), deployed, converged to "No changes", and a change made directly in Jamf was detected and restored.
- Adopt leaves out what the app cannot manage, with a note: objects whose secret values Jamf never exports (activation code, ADE server token, GSX credentials) and enrollment invitations. References from adopted objects to anything left out are pointed at the object's existing Jamf ID, and values the export supplies are written into the adopted configuration.
- Importing PreStages clears their empty account-settings and location sections, which the exporter omits; the values involved are defaults.
- Objects an adopted object references by Jamf Pro ID or name (for example a scope group) are adopted with it: only `.id` references can be pointed at an existing ID.
- **Adopt More…** lists only objects not yet adopted and adds them to the record; already adopted objects are left untouched.
- **Hand over** is prepared, previewed and deployed like any change, and can be cancelled until it deploys; the adopted configuration is archived next to the record once it has.

## Composition
- **Two blocks owning one tenant-wide setting** are refused when the workspace is generated, with a message naming both blocks.
- **Name collisions are not detected yet**: selecting the demo catalog's Categories block next to a captured categories block while "apply the tenant prefix to all names" is on can produce identically named categories (both create "<prefix>Enrollment"), and duplicated App Catalog titles (for example "TF - Google Chrome" next to "Google Chrome") collide once rebinding collapses their deployments onto one target group. Jamf rejects the duplicates; deselect the duplicate objects at capture, or skip the prefix option. An editor-level collision warning is planned.
- **Removing a settings block only stops managing it**: Jamf has no "empty" state for tenant-wide settings, so the provider drops them from state and Jamf keeps the current values. The removal dialog says so.
- **Deploy history masks sensitive values**: `tofu show -json` prints them in clear text; the copy kept in history (and the team repository) is redacted with the engine's sensitivity markers.

## Upstream dependencies being watched
- jamfplatform provider pinned at 1.5.0 (released 2026-10-16 — very fresh); blueprints' top-level settings deprecated with a stated removal window (catalog already uses `component_blocks`). Settings → Built-in tools now flags newer upstream releases of OpenTofu, both providers and jamformer (24-hour check).
- jamformer 0.6.0 emits Terraform-style identity imports that fail under OpenTofu; the app normalizes them (worth reporting upstream). It also always runs a search phase, so a selection of only settings-style types fails with "No resources to query" — the app retries those exports with a small helper type and drops its files (worth reporting upstream).
- jamfplatform 1.5.0 returns an unknown `self_service.display_notifications` after creating macOS configuration profiles ("invalid result object after apply"). Captured blocks set the attribute explicitly, drop the vestigial `self_service` object from install-automatically profiles, and trim the trailing description whitespace Jamf discards — all three sidestep provider/server inconsistencies (worth reporting upstream).
- Full-tenant clones are live-verified: a 468-object clone of a tenant (policies, profiles, groups, apps, App Installers, patch titles, blueprints, settings singletons) applies to an empty tenant and converges to "No changes". PreStages clone too: their ADE instance reference becomes a name-based lookup with an editable block setting, and Recovery Lock is turned off when its password (never exported) is missing. Objects that cannot move — icons, invitations, built-in groups, default allowed file extensions, the cloud distribution point, Jamf Patch reporting attributes, compliance benchmarks, values Jamf does not export, a login page without disclaimer text — are left out at capture with per-item warnings. All 24 settings-style types were exported one by one and in one bulk export (identical output); the 20 portable ones deploy alone and together with a 400-object baseline.
- Platform OAuth tokens live 900 s (handled); provider request pacing left at its real default (0 ms).
- Compliance benchmarks auto-create an audit policy in Jamf Pro (Jamf-managed; excluded from drift logic by the noise list).

## Scale honesty
Verified with a handful of tenants, a 440-object 31-block baseline and a 468-object full clone. Fleet views, drift batching (3 at a time) and the Git store should handle dozens of tenants comfortably; hundreds are untested.
