# Hardening sprint — pre-release review and fixes

Between Phase 8 and Phase 9. Scope set by the project owner: eject
documentation, end-to-end encrypted team secrets, working "Keep this change",
per-block baseline updates, component update monitoring, then a full code
review with fixes.

## What was built

1. **Eject documentation** — `docs/ejecting.md`: moving a tenant from the app
   to plain OpenTofu (workspace + encrypted state + environment variables),
   including the OpenTofu-vs-Terraform state-encryption caveat.
2. **E2E-encrypted team secrets** — `TeamCrypto` (JamfDeployerCore) +
   `TeamSecretsService` (app). Curve25519 ECIES per recipient (ephemeral
   X25519 → HKDF-SHA256 → ChaCha20-Poly1305); the repository carries only
   ciphertext envelopes under `team/secrets/`, identities under
   `team/engineers/*.pub`. Private keys never leave each engineer's Keychain.
   Live-verified across two store checkouts. *Replaced before 1.0: team
   state now lives in a Git state backend encrypted with a team passphrase,
   and each engineer uses their own credentials (see docs/team-mode.md).*
3. **"Keep this change" made real** — blocks declare `driftBindings`
   (resource type + field path → setting key). Keeping a bound drifted field
   writes the value back into the block's setting, so the next deploy keeps
   it; unbound fields fall back to acknowledgment with honest wording.
4. **Per-block baseline updates** — Git-tag catalog sources (one immutable
   shallow checkout per tag), tenant `catalogPins`, per-selection `sourceTag`
   overrides, and a Baseline Updates sheet that opts individual blocks into a
   newer tag. Live-verified with a tagged file:// catalog.
5. **Component update monitoring** — `ComponentUpdateChecker` compares the
   pinned OpenTofu/provider/jamformer versions against GitHub latest releases
   (24-hour cadence), surfaced in Settings → Built-in tools.

## Code review

`code-review high` over the app target and both packages: 10 confirmed
findings, all fixed.

| # | Finding | Fix |
|---|---------|-----|
| 1 | Secret block settings stored in `tenant.json` (synced plaintext) | `.secret` settings now read/write a per-tenant+block Keychain item (`TenantSecrets.blockSetting`); never written to selection settings |
| 2 | Generated `sensitive` root variables never received values | `secretSettingEnvironment` resolves `TF_VAR_*` from the Keychain per run; missing values throw a plain-language error |
| 3 | Override editor offered sensitive attributes as editable (plaintext HCL) | `isEditablePrimitive` excludes `sensitive` attributes |
| 4 | stderr pipe deadlock on chatty child processes (both runners) | stderr drained concurrently with stdout via a child task |
| 5 | Drift check during an open preview invalidated the saved plan and released the team lock | `activePreviewTenants` interlock; drift checks are blocked (and fleet checks skip) until the preview deploys or closes |
| 6 | Preflight completion overwrote concurrent tenant edits | Re-fetches the tenant from the store before applying the snapshot |
| 7 | OAuth form body left `+` unescaped, corrupting secrets containing it | Manual RFC 3986 unreserved-set form encoding |
| 8 | Git catalog network calls ran synchronously on the main actor | `GitCatalogManager` is async (detached); `CatalogSourceStore.load` is disk-only; checkouts pre-fetch before synchronous generation |
| 9 | Adopted `versions.tf` duplicated `required_providers` and failed init | Stripped at staging and skipped when copying adopted files |
| 10 | `Int(Double)` conversion could trap on values ≥ 2⁶³ | `numberText` bounds-checks before converting |

Dead code removed: the Phase 0 engine spike window (`EngineDebugView`) and
its `SpikeKeychain` helper — they depended on hand-created spike Keychain
items no user would have. Wording sweep found no unprofessional or
project-rule-violating text.

## Verification

- App target builds clean (Xcode, Swift 6 strict concurrency).
- JamfDeployerCore: 39 tests passing. DeployerKit: 4 tests passing.

## Carried forward

See `docs/STATUS.md` for the consolidated limitations ledger.
