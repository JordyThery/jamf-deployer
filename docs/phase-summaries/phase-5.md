# Phase 5 — Export (U4, U5)

Date: 2026-10-17 · Builds clean · JamfDeployerCore: 26 tests pass · Exit criterion met live: the Rosetta policy + script were captured from the demo tenant into a reusable block and deployed to the sandbox tenant (then removed again).

## 1. What was built

### Terraform on demand (never bundled)
- **`TerraformManager`**: downloads Terraform **1.16.6** (≥ 1.14 for `terraform query`) from HashiCorp on first export, **checksum-verified** against the published SHA256SUMS, stored under Application Support — outside the app bundle, per the BUSL licensing stance. The Export tab explains the licence and asks before downloading; deploys always run on the bundled OpenTofu.

### jamformer integration
- **`JamformerRunner`** (actor): runs the bundled jamformer with env-only credentials (`JAMF_URL` gateway + `JAMF_ENVIRONMENT_ID`/`JAMF_TENANT_ID`), maps the flags per the brief (`-include-resources`, `-skip-package-downloads`, `-terraform-path`, `-output`; the secret scan is **never** skipped), parses `-list-resources` into the 99-type checklist, and surfaces gitleaks findings in the UI and capture output.

### Export tab (per tenant)
Three export types behind one options panel (object-type checklist with filter/All/None, "Include package files" toggle, Terraform consent row, streaming log):
1. **Capture to building block** → `BlockCapture` post-processor (JamfDeployerCore, fixture-tested against real jamformer output):
   - names starting with the tenant's prefix → `"${var.name_prefix}…"`;
   - hard-coded scope group IDs (incl. jamformer's multi-line lists with `# TODO: unresolved reference` comments) → `var.scope_jamf_pro_group_id` / platform-UUID variants, with the matching block.json scope + `requires: [foundation]`;
   - **hard-coded category IDs → `var.category_id`** + `acceptsCategory` (added after the live run exposed it — see §3);
   - `support_files/` → `files/` with path rewrites; provider/variables/import files excluded;
   - block.json with permissions parsed from the export's PERMISSIONS.md, `reviewStatus: needsReview`; README seeded with provenance and any secret findings.
2. **Full tenant snapshot**: manifest.json (tenant, date, app/jamformer/provider versions) + zip via ditto, saved where the user chooses.
3. **As-built documentation**: `AsBuiltReport` renders Markdown (objects grouped by area with names, key settings, scope lines) from the export — a documentation-only scan, not a config parser.

### Custom catalog sources and review flow
- **`CatalogSourceStore`**: the official catalog plus any number of local folder sources (catalog.json created on add); `LoadedCatalog.merge` combines them (official wins on ID conflicts) with per-block source attribution.
- Captured blocks appear in Building Blocks and the baseline editor with a **"Review before use"** badge and their source name; the block detail sheet gains **Mark as Reviewed** (rewrites block.json).
- `TenantDeployService` now plans/deploys from the merged catalog, so captured blocks behave exactly like authored ones (drift, removal, history included).

## 2. How to test manually
1. Open a deployed tenant → **Export** tab → consent to the Terraform download (one-time).
2. Pick "Building block", tick `script` + `policy`, Export → watch the log → fill in block ID/name, choose (or create) a blocks folder → **Capture Building Block**.
3. **Building Blocks** library: the captured block shows "Review before use" + its source; open it → Mark as Reviewed.
4. On another tenant: select the captured block (foundation auto-selects), pick a scope → Preview → Deploy.
5. "Full snapshot" exports a zip (with manifest.json inside); "As-built documentation" saves a Markdown report.

## 3. Live verification (demo → sandbox)
- Terraform 1.16.6 downloaded and verified; 99 resource types listed; export of `script policy` from the demo tenant exited 0 with a **clean secret scan**; as-built Markdown generated (5 objects).
- Export pruned to the Rosetta objects (standing in for the per-object picker, see §4), captured into the "Captured Blocks" source: 2 objects, Jamf Pro scope parameterized, `needsReview`.
- Deploy to the **sandbox** tenant (prefix "JDX - "): foundation + captured block → first attempt 12/13 — the policy failed on the demo tenant's hard-coded **category 73**. Fixed properly in `BlockCapture` (category IDs now parameterized and foundation-wired), re-captured, re-deployed: **all green**. Teardown removed all 13 sandbox objects cleanly.
- Two real jamformer output quirks are now encoded in the test fixture: multi-line scope lists with trailing-comma + TODO comments, and literal category IDs.

## 4. Remaining TODO(verify) / open items
- **Per-object selection** within a type (brief: "picks object types, then specific objects") is not in the UI yet — exports currently take all objects of the chosen types; the verification pruned by resource-block surgery, which is exactly what the picker will do (parse `resource` headers from the export, let the user tick objects, drop the rest). Planned alongside Adopt (Phase 6), which needs the same object list.
- Secret findings are surfaced and written into the captured block's README; auto-converting them to sensitive variables remains manual.
- As-built is Markdown (+ zip/Quick Look-friendly); PDF rendering joins the Phase 8 polish pass.
- jamformer's `-exclude-resources`, `-compact` and Protect provider exports are wired at the runner level but not exposed in the UI (Protect waits for Phase 7).

## 5. Decisions needed
None. Next: **Phase 6 — Adopt and Clone** (adopt a hand-configured tenant with import blocks; clone tenant A→B), which builds directly on this phase's export machinery.
