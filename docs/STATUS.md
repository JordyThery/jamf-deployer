# Jamf Deployer — status, limitations and uncertainties

As of 2026-10-17, end of the pre-release hardening sprint (see `phase-summaries/hardening.md`). Consolidates the open items from every phase report.

## Never exercised live (schema-verified, validated, but unapplied)
- **protect-baseline block** — no non-production Jamf Protect tenant exists to apply it to. The provider wiring itself *is* live-verified read-only (auth + all four data sources against production).
- **security-cloud block** (UEM Connect + activation profile) — no Security Cloud-entitled environment available. The not-entitled failure path *is* live-verified and translated.
- ADE `.p7m` / VPP `.vpptoken` uploads and Protect registration in Day 0 — wired and spec-verified, needing real Apple/Protect artifacts to fire for the first time.
- Jamf Pro below 11.31 — no such tenant to test the degradation path.

## Known behavioral gaps
- **"Keep this change"** adopts the drifted value into the block's setting when the block declares a drift binding for that field; fields without a binding fall back to acknowledgment (a later deploy reverts them, and the UI says so).
- **Policy-create 500-but-created quirk** (Jamf classic gateway): "Retry failed" can hit 409 Duplicate name; recovery is manual deletion today. Planned: adopt-on-409.
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
Supported by design: `tenants/<id>/generated/` + `state/` + the env vars (`JAMFPLATFORM_*`, `TF_ENCRYPTION` with the recovery-sheet passphrase) run under vanilla OpenTofu ≥ 1.13 with providers from the public registry. Caveats: the ejector owns the HCL from then on, and HashiCorp Terraform (vs OpenTofu) cannot read encrypted state without a manual encryption-migration first. A one-click "Export as standalone configuration" bundle is a planned Phase 9 nicety.

## Packaging and release (Phase 9 scope)
- Vendor binaries and the Catalog resolve from the repo in dev builds; bundling into the app wrapper (copy phase or archive-time script), universal tofu packaging, signing + notarisation are still to do.
- The update feed repo (`JordyThery/jamf-deployer`) has no releases yet; the checker's mechanism is live-verified against another feed.
- No app-target unit tests (needs a test target added in Xcode); the two packages carry 39 + 4 tests.
- App Sandbox is off by design (child-process engine); Developer ID + notarisation is the distribution model.

## Upstream dependencies being watched
- jamfplatform provider pinned at 1.5.0 (released 2026-10-16 — very fresh); blueprints' top-level settings deprecated with a stated removal window (catalog already uses `component_blocks`). Settings → Built-in tools now flags newer upstream releases of OpenTofu, both providers and jamformer (24-hour check).
- jamformer 0.6.0 emits Terraform-style identity imports that fail under OpenTofu; the app normalizes them (worth reporting upstream).
- jamfplatform 1.5.0 returns an unknown `self_service.display_notifications` after creating macOS configuration profiles ("invalid result object after apply"); objects are created and kept in state regardless. Captured blocks set the attribute explicitly to sidestep it (worth reporting upstream).
- Platform OAuth tokens live 900 s (handled); provider request pacing left at its real default (0 ms).
- Compliance benchmarks auto-create an audit policy in Jamf Pro (Jamf-managed; excluded from drift logic by the noise list).

## Scale honesty
Verified with a handful of tenants and ~20-object baselines. Fleet views, drift batching (3 at a time) and the Git store should handle dozens of tenants comfortably; hundreds are untested.
