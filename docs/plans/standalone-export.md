# Plan: export as a standalone Terraform repository

Status: design proven by hand, not yet implemented in the app. Part of the
on-ramp release: a tenant (or the fleet) managed by Jamf Deployer can leave the
app as an ordinary Terraform/OpenTofu repository that a team runs from Git and
CI, laid out the way Jamf's own reference projects are.

## Reference layouts

- **Jamf-Concepts/terraform-jamf-platform**, branch `ref-jamfprotect-msp`: the
  repository behind the JNUC 2026 session *Managing the Jamf Platform at Scale
  With IaC*. One shared module, `customers/<name>/` per tenant (`main.tf`,
  `terraform.tf` with the backend, `customer.auto.tfvars`, `outputs.tf`), a
  `_template/`, and workflows for plan, apply, destroy, handover, force-unlock,
  drift, remediate and reconcile (out-of-band objects via `terraform query`).
  Per-tenant state key and per-tenant GitHub Environment for credentials.
- Branches `ref-jamfplatform` and `ref-jamfpro`: single-tenant layouts
  (`environments/dev/` calling `modules/jamfplatform` or `modules/jamfpro`).
- neilmartin83/terraform-jamfpro-starter is **archived** and points to the
  branches above.
- Deployment Theory: root module per instance, shared child modules,
  configuration as data, data-driven `for_each` blocks.

## Export layout

```
modules/<block-id>/           block modules as deployed (connection variant only)
tenants/<tenant>/
  main.tf                     one module call per block, plus the wiring between blocks
  variables.tf                one typed object variable per block
  tenant.auto.tfvars          every setting value; the file that differs between tenants
  terraform.tf                version constraints and backend (one state object per tenant)
  providers.tf                provider settings; credentials from environment variables
  .terraform.lock.hcl
```

| App concept | Exported repository |
| --- | --- |
| Building block | child module in `modules/` |
| Baseline (selected blocks) | module calls in `tenants/<tenant>/main.tf` |
| Block settings | `tenant.auto.tfvars` |
| Block-to-block defaults (group, category) | references between module calls in `main.tf` |
| Encrypted state | one state object per tenant in the team's backend |
| Check for Changes, Keep or Restore | scheduled drift plan; a pull request to keep, an apply to restore |

Module names stay identical to the app's, so state addresses carry over
without `moved` blocks.

## Proof (2026-10-19)

On the Sandbox, every demo block plus the App Catalog was deployed by the app
(Scripts/run-catalog-ui-tests.sh, paused after its no-changes check):

1. `Scripts/prototypes/export_tenant.py` converted the generated workspace into
   the layout above. Output: `Fixtures/export-golden/` (18 blocks).
2. State was decrypted with the app's engine and piped into the new workspace,
   never written to disk decrypted outside the target backend:
   `tofu state pull | terraform state push -` (30 resources).
3. `terraform state replace-provider registry.opentofu.org/jamf/jamfplatform
   registry.terraform.io/jamf/jamfplatform`.
4. `terraform plan -detailed-exitcode` with Terraform 1.16.6: **exit 0, no
   changes**. The same export under OpenTofu 1.13.1 (provider address kept):
   **no changes**.

All proof state was deleted afterwards; the run then completed its own
removal and settings restore.

## Open items for the generator

- **Jamf Pro API tenants**: module source `modules/<id>/jamfpro`, provider
  `deploymenttheory/jamfpro`, `-parallelism=1` in the workflows.
- **Secret block settings**: declared as sensitive variables, supplied as
  `TF_VAR_*` from CI secrets; documented per tenant.
- **Adopted objects** (the app's adopted configuration) and **Protect /
  Security Cloud** connections: include their files and provider blocks.
- **Pending removals** (`removed` blocks for Stop Managing): export only once
  applied, or keep them with a note.
- **Fleet export**: one `modules/` shared by all tenants; block versions that
  differ between tenants need versioned module folders.
- **Team Mode state**: pull through the state backend instead of the local file.
- **Backend choice** in the export sheet (S3 example as in the reference,
  HCP Terraform, GitLab, or the Git backend the app already uses).
- **Differences from the reference to document**: providers are configured
  in the root module (Terraform's guidance) rather than inside a shared
  module; one module per block rather than one baseline module; the
  reference's out-of-band workflow needs Terraform 1.14 or later.

## Next steps

1. CI templates modelled on `ref-jamfprotect-msp`: plan on pull request with the
   plan as a comment, apply on merge as a per-tenant matrix with GitHub
   Environments, weekly drift with an issue. Live-test in a private repository
   against the Sandbox.
2. "Graduating to Terraform" guide built on the mapping table above.
3. The generator in JamfDeployerCore, tested against `Fixtures/export-golden/`.
