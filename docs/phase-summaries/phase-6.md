# Phase 6 — Adopt and Clone (U6, U7)

Date: 2026-10-17 · Builds clean · JamfDeployerCore: 30 tests pass · Exit criterion met live: the hand-configured sandbox was adopted with a preview showing **Adopt: 61 and nothing else**, imports applied, post-adopt drift check clean.

*The foundation block described here was later split into the demo catalog's Device Groups, Categories and Extension Attributes blocks and made optional.*

## 1. What was built

### Adopt an existing tenant
- **Adopt wizard** (every non-handed-over tenant, Overview → "Adopt Existing Configuration…"):
  1. object-type checklist (sensible defaults: categories, scripts, policies, groups, EAs);
  2. discovery via jamformer *with* import blocks (Terraform-on-demand from Phase 5);
  3. **per-object picker** with display names and a "Created by a building block" badge on anything carrying a Jamf Deployer provenance tag (deselected by default — those belong to blocks, not overrides);
  4. staging: selection pruned, import blocks normalized, provider wiring stripped, moved into the tenant's `adopted/` folder.
- **Adopted objects are first-class tenant config**: the workspace generator merges `adopted/*.tf` (+ support files) into every generated workspace, so previews, deploys, drift checks, history and state backups all include them. They group under "Adopted objects" in the preview and drift views.
- **Preview semantics**: imports always read as **Adopt**; when the first plan would also change attributes (jamformer's documented warning), the Adopt row carries the exact field diffs — "clearly explained differences", per the exit criterion. Adopt is never counted as destructive.
- After a successful deploy the one-shot `*_import.tf` files are deleted automatically; the tenant is simply Managed from then on.

### Clone A → B
- Export tab gains **"Clone to tenant"**: pick objects (per-object picker), pick a destination tenant → export runs with `-skip-import-blocks` → the clone is captured through the Phase 5 post-processor (names → destination's prefix, category/group IDs remapped to scope/category settings) into an app-managed **"Cloned"** source as a one-off block → the block is added to the destination's baseline (foundation auto-added) → deploying happens through the destination tenant's own preview. Tokens, certificates and secrets are never cloned — the form says so and points at Day 0.

### Per-object selection (Phase 5 debt paid)
- **`ExportedObjectInventory`** (core, fixture-tested): scans exports into objects (type, Terraform name, display name, provenance flag) and prunes by whole resource blocks — matching import blocks follow their resources automatically. Wired into Adopt, block capture, and Clone.

## 2. How to test manually
1. Tenant with hand-made objects → **Adopt Existing Configuration…** → pick types → Discover → untick anything you don't want (block-created objects arrive unticked) → Stage → **Preview Changes**: every row reads "Adopt"; any first-plan differences are listed on the row → Deploy → Check for Changes reports in sync.
2. Export tab → "Clone to tenant" → select objects, choose a destination → Stage Clone → open the destination tenant → its baseline now contains a "Clone of …" block → Preview shows the objects as Creates with the destination's name prefix → Deploy.
3. Capture flow ("Building block") now also offers the object checklist after export.

## 3. Live verification (sandbox, via a throwaway tenant record)
- Discovery: **61 objects** (28 categories + 33 scripts), 0 provenance-tagged — a genuinely hand-configured tenant.
- Preview: **Adopt: 61 — zero creates/updates/removes** (the ideal case: no post-import differences at all on these types).
- Deploy: all imports applied, 0 failed; leftover import files: 0.
- Post-adopt drift check: **0 drifted objects** — the record matches the tenant exactly.
- Teardown: tenant record removed from the app; Jamf confirmed untouched (28 categories still present).
- Clone itself was live-proven in Phase 5 (demo → sandbox) through the same capture machinery; this phase adds the one-click flow.

### Compatibility finding (now encoded in tests)
jamformer 0.6.0 emits Terraform-1.12-style **identity imports** (`identity = { id = … }`); the provider's identity-import path returns *no state* under OpenTofu ("Import returned null resource"). `ExportedObjectInventory.normalizeImportBlocks` rewrites them to the provider-documented string-ID form, which imports flawlessly. The test fixture now uses the real identity syntax.

## 4. Remaining TODO(verify) / open items
- Matching adopted objects **back to catalog blocks** (by provenance tag) is detection-only for now: tagged objects are flagged and excluded by default; true re-binding to a block (after state loss) stays open.
- Adopted objects can be removed from the record only via Adopt re-staging or record removal; per-object "stop managing" (root-level `removed` blocks) joins the overrides editor in Phase 8.
- Composite-identity imports (identity objects with more than `id`) pass through unnormalized — none exist in today's provider; a warning would surface if they appear.
- Clone currently stages one block per clone in the "Cloned" source; dedup/cleanup of old clone blocks is manual.

## 5. Decisions needed
None. Next per the brief: **Phase 7 — Jamf Protect and Security Cloud** (Protect provider wiring, protect-baseline block, Protect exports, security-cloud blocks with entitlement messaging). Note: live Protect verification needs a Jamf Protect tenant + API client — tell me if you have one to test against, otherwise Phase 7 ships schema-verified with live checks deferred.
