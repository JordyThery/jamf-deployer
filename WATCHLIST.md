# Jamf Deployer: watchlist

What this app is waiting for from Apple, Jamf or Microsoft, or must recheck. Check each item when the vendor ships an update.

Bundled versions are pinned in `Vendor/fetch.sh`; recheck the component items below whenever a version there changes.

- **Concurrent configuration profile creates (Jamf, jamfpro plugin):** concurrent creates draw 500s from Jamf (which creates them anyway), and the jamfpro plugin requires `-parallelism=1`. If both change, applies could run in parallel.
- **Create 500/504 but created (Jamf):** the Classic lookups must ask for JSON (`Accept`), or JTKit gets XML and finds nothing. Not live-verified again since that fix: recheck in a live run.
- **terraform-backend-git 0.1.12 (bundled):** keeps a PID file in `$TMPDIR`; a stale lock branch stops a fresh backend from reading state. If a newer version fixes these, the own TMPDIR, the leftover kill on launch and Force Unlock’s direct branch delete can be revisited.
- **jamformer 0.6.x (bundled):** emits Terraform-style identity imports that fail under OpenTofu (the app normalizes them); a settings-only selection fails with "No resources to query" (retried with a helper type).
- **jamfplatform PreStages (Jamf):** PreStages with `scope_serial_numbers = []` get a 500 on PUT; capture drops the attribute.
- **jamfpro plugin and missing privileges:** a missing read privilege makes the jamfpro plugin retry forever, so privilege probes are time-boxed.
- **jamfpro plugin can’t list objects:** the exported "Not in code" check relies on `terraform query` instead.
- **Security Cloud activation profiles (Jamf):** activation profiles can’t be imported (to remove one, the app seeds a state holding it and destroys).
