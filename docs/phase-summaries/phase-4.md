# Phase 4 — Maintain (U3)

Date: 2026-10-17 · Builds clean · JamfDeployerCore: 22 tests pass · Exit criterion met live: a category renamed via the console was flagged with a field-level diff, kept, then restored from the app; "Stop managing" left objects alive in Jamf; rollback restores a snapshot baseline.

## 1. What was built

### Changes made in Jamf (drift)
- **`DriftReportBuilder`** (core): refresh-only plan → per-object reports with **deep field paths** (a policy's echo reads `general.category_name`, not "general changed") and **computed-noise classification** — changes limited to Jamf-maintained attributes (`category_name`, `profile_uuid`, `member_count`, …) are informational, not actionable. Fixture-tested against the real drift capture.
- **`checkDrift(tenant:)`**: generate → init → `plan -refresh-only -out` → show → report stored on the tenant (with `lastDriftCheck`); it also refreshes ADE/VPP token expiry for the dashboard in the same pass.
- **Fleet check**: "Check All Tenants" runs deployed tenants in batches of three with live progress; ⌘R checks the selected tenant (or the whole fleet from the dashboard).
- **Tenant view — three actions**:
  - **Restore Baseline…** → the normal preview/deploy, which the live test confirmed reverts exactly the drifted field.
  - **Keep This Change** → the drifted value is acknowledged per field (persisted) and stops counting as drift; the preview still shows the revert if you later deploy. (A true "keep as tenant override" lands with the overrides system in the Adopt phase — see §4.)
  - **Stop managing** → below.
  - Computed-only changes show as "updated by Jamf itself — nothing to do".

### Stop managing / Remove / Hand over
- Generator emits **module-level `removed { destroy = false }` blocks** (verified offline with a spike and live). Unchecking a *deployed* block now asks: **Remove from Tenant** (objects deleted on deploy) vs **Stop Managing** (objects stay; the app forgets them), with the consequence spelled out; pending removals are badged on the block row and cancellable by re-selecting.
- **Hand over**: typed-name confirmation → every deployed block becomes a stop-managing removal → the user previews ("Stop managing: N") and deploys → the tenant archives (`handedOver`): banner shown, editing and deploys disabled, dashboard shows "Handed over".

### Baseline updates, rollback, dashboard
- Every deploy records `deployedBlockVersions` (+ a one-time migration seeds it for pre-Phase-4 tenants from history) and snapshots the block selection into the history entry.
- Dashboard **Baseline** column: "N blocks" + an **Update available** badge when the catalog has newer block versions than deployed; status column now: Handed over / Never deployed / "N changes made in Jamf" / **In sync** (only when checked within 24 h) / "Last checked …" — per the UX rule that In sync requires a recent check.
- **History → Roll Back…**: restores that entry's block selection (settings included); the next preview plans back to it against current state. Entries predating snapshots refuse with a clear message.
- Tenant menu is now live: ⌘R check, ⌘P preview, ⌘D deploy (opens the same preview flow — deploying always goes through a preview).

## 2. How to test manually
1. Rename any "JD -" object in the demo Jamf console → tenant → **Check for Changes** → the object appears under "Changes made in Jamf" with a − baseline / + now-in-Jamf diff; echoes on referencing objects show as informational.
2. Click **Keep This Change** (it stops counting) or **Restore Baseline…** → Deploy (the preview shows exactly the one field reverting).
3. Baseline → untick Rosetta 2 → choose **Stop Managing** → note the orange badge → Preview shows two "Stop managing" rows → Deploy → the script and policy are still in Jamf Pro, gone from the app's record.
4. Dashboard → **Check All Tenants** (watch the progress count); status flips to In sync / N changes.
5. History → **Roll Back…** on a recent entry → open the tenant → Preview shows the differences to that older baseline.
6. Hand over box at the bottom of a deployed tenant → type the name → preview lists "Stop managing" for everything → after deploy the tenant is archived.

## 3. Live verification (demo tenant)
- Console rename → drift: category flagged **actionable** (`name: JD - Security → JD - Security (renamed by admin)`), FileVault policy's `general.category_name` echo **informational**. Keep: outstanding 1 → 0. Restore deploy: exactly 1 update; drift after: 0 actionable.
- Stop managing rosetta: preview "Stop managing: 2, Unchanged: 18" → deploy → `pendingRemovals` cleared, rosetta out of the record — **policy 100 and script 143 still present in Jamf** (then deleted via API to simulate the taking-over admin, block re-added and redeployed; tenant back to a 20-object baseline).
- Rollback: snapshot-bearing entry restored and swapped back; pre-snapshot entries refuse gracefully.

## 4. Remaining TODO(verify) / open items
- "Keep this change" is acknowledgment, not a config override: deploys still revert kept values (the preview says so). Converting kept drift into a real tenant override joins the overrides.tf work in Phase 6; where a kept field maps to a block setting, auto-adopting it into the setting is a good follow-up.
- Per-block opt-in for baseline updates needs **pinned catalog versions**, which arrive with Git-tag catalog sources (the local source is always "latest"); the Update available badge and preview-the-whole-update flow work today.
- Concurrent runs on one tenant (e.g. fleet check during a manual preview) rely on the engine's state lock to fail safely rather than being prevented up front.
- The retry-on-409 adoption strategy for the Phase 2 policy-create quirk remains open (drift-checking makes it visible at least).

## 5. Decisions needed
None. Next per the brief: **Phase 5 — Export** (on-demand Terraform for jamformer, export options UI, capture-to-block post-processor, snapshot, as-built documentation).
