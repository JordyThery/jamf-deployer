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

## CI templates (2026-10-19)

`Templates/standalone-export/` holds the workflows the export ships with,
modelled on `ref-jamfprotect-msp`, plus a setup README:

| Workflow | Trigger | Does |
| --- | --- | --- |
| `plan.yml` | pull request into main | fmt and validate, plan each affected tenant, one updated comment per tenant, a single "Plan result" check |
| `apply.yml` | push to main (or manual, one tenant) | apply the tenants the merge changed, one job per tenant |
| `drift.yml` | Mondays 06:00 UTC, manual | plan every tenant; open, update or close a `Changed in Jamf: <tenant>` issue |
| `restore.yml` | `restore-baseline` label on that issue | permission check, apply, close the issue |
| `destroy.yml` | manual, tenant name typed twice | destroy one tenant |

Shared actions: `state-backend` (terraform-backend-git on the runner, state on
a `terraform-state` branch, created on first use) and `detect-tenants`
(changed tenants, every tenant when a module changed or there is no base).
Every job runs in the tenant's GitHub Environment and holds a per-tenant
concurrency group.

Live-tested in the private repository `jamf-deployer-export-test` against the
Sandbox (categories and extension attributes, prefix `UIT CI - `): plan comment
on the pull request, apply on merge (6 created and verified in Jamf), a clean
check with no issue, two console changes caught in one issue, a repeat check
commenting on the same issue, the label restoring both values and closing it,
an issue closing itself after a manual revert, the destroy guard skipping on a
mismatched name, and destroy removing all 6. Found and fixed during the test:
detection on a first push (no base commit), one plan comment per tenant instead
of one per push, and the comment naming the pushed commit rather than the merge
ref. The test Environment (and its credentials) was deleted afterwards.

Finding for the guide: Terraform keeps state unencrypted, so with the Git
backend the repository must stay private; S3 with encryption or OpenTofu with
client-side encryption are the alternatives, both described in the README.

## Jamf Pro API tenants (2026-10-19)

- **Export proof:** every demo block with a Jamf Pro API version (16 blocks, 26
  resources) deployed by the app through the Jamf Pro API, exported, state
  migrated (`replace-provider registry.opentofu.org/deploymenttheory/jamfpro
  registry.terraform.io/deploymenttheory/jamfpro`), `terraform plan
  -parallelism=1`: **no changes**. Output: `Fixtures/export-golden-jamfpro/`.
- **Layout decision:** `modules/<block>/` holds the whole block as the catalog
  ships it (Platform module at the root, `jamfpro/` inside, shared `files/`
  beside them); Jamf Pro tenants point at `modules/<block>/jamfpro`. A fleet
  mixing connections shares one folder per block, and the `../files`
  references in the Jamf Pro variants keep working unchanged. Both fixtures
  were rebuilt in this layout and validate.
- **Workflows:** one set serves both connections. Every job reads
  `JAMFPLATFORM_*` and `JAMFPRO_*` from the tenant's Environment (the unused
  set is empty) and `TF_CLI_ARGS_plan/apply/destroy` take
  `-parallelism=${{ vars.PARALLELISM || '10' }}`, so a Jamf Pro tenant sets
  `PARALLELISM=1`.
- **Live CI test** with a temporary, narrowly scoped Jamf Pro API client:
  plan on the pull request (the retired tenant skipped), apply (6 created),
  two console changes caught in one issue, restored by the label, destroyed,
  `-parallelism=1` confirmed in the run. Client, role and Environment deleted.

## Next steps

1. The generator in JamfDeployerCore, tested against both fixtures, writing the
   templates alongside each export.
2. "Graduating to Terraform" guide built on the mapping table above.
