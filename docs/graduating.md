# Graduating to Terraform

Jamf Deployer runs OpenTofu, a Terraform-compatible engine, for every tenant.
Everything the app does is ordinary infrastructure as code underneath, and a
team that is ready to work in Git and pull requests can take its tenants to a
plain Terraform repository at any time. Nothing in Jamf is recreated: the
objects, and the engine's record of them, carry over as they are.

## What the app does, in Terraform terms

| In the app | In Terraform |
| --- | --- |
| Building block | A **module**: a folder of `.tf` files with inputs (`variables.tf`) and outputs |
| A tenant's baseline | The tenant's **root module**: one `module` call per block, in `main.tf` |
| Block settings | **Input variables**, with their values in `tenant.auto.tfvars` |
| A block filing into another block's category or group | A **reference** between modules: `module.categories.category_ids["Security"]` |
| Connection (Jamf Platform API or Jamf Pro API) | A **provider**: the `jamf/jamfplatform` or `deploymenttheory/jamfpro` plugin and its credentials |
| The tenant record of what is managed | The **state** file, one per tenant |
| Preview Changes | `terraform plan` |
| Deploy | `terraform apply` of the plan you approved |
| Check for Changes | `terraform plan`, run on a schedule, reporting changes made in Jamf |
| Restore Baseline | `terraform apply` |
| Keep this change | Changing the code, so the next plan agrees with Jamf |
| Team Mode locks | **State locking** in the state backend |
| History | Git history and pull requests |

Turn on **Settings → Show technical details** to see this for yourself: every
preview then lists the commands it ran, the command Deploy runs, and the
generated configuration, with a button that opens the tenant's workspace in
Finder.

## Exporting tenants

On the dashboard, choose **Export as Terraform…**, tick the tenants, and
choose an empty folder. The folder becomes the repository:

```
modules/<block>/          one folder per building block, as the catalog ships it
tenants/<tenant>/         main.tf, variables.tf, tenant.auto.tfvars, terraform.tf, providers.tf
.github/workflows/        plan, apply, check for changes, restore baseline, destroy
README.md                 how the repository works and how to set it up
```

The layout follows Jamf's own multi-tenant reference project
(`ref-jamfprotect-msp` in
[Jamf-Concepts/terraform-jamf-platform](https://github.com/Jamf-Concepts/terraform-jamf-platform)):
one shared module per capability, one thin folder per tenant, one state file
per tenant, and credentials kept per tenant in GitHub Environments.

Then choose what happens to the tenants:

- **Keep managing here** writes the configuration only. Read it, run
  `terraform validate`, show it to a colleague. The tenants and their state
  stay in the app.
- **Move to a repository** also publishes the export to an empty private
  repository, moves each tenant's state to the repository's `terraform-state`
  branch, and stops managing the tenants in the app (they are archived there,
  and every object stays in Jamf). From then on the repository manages them.

## After moving

1. **Create each tenant's GitHub Environment.** In the export folder, run
   `./create-environments.sh OWNER/REPOSITORY`. It creates one Environment
   per tenant with its identifiers and asks for each secret (typing is
   hidden). The script holds no secrets and is not committed.
2. **Protect `main`**: require a pull request, one approving review, and the
   **Plan result** check.
3. **Make the next change with a pull request.** The Plan workflow comments
   the plan on the pull request; merging applies it. On Monday mornings the
   Check for Changes workflow opens an issue when something was changed
   directly in Jamf; add the `restore-baseline` label to put it back, or put
   the change in code.

## Good to know

- **State is unencrypted in Terraform.** With the repository's
  `terraform-state` branch as the backend, anyone who can read the repository
  can read the state, so keep it private. The README describes S3 with
  encryption, and OpenTofu with client-side encryption, as alternatives.
- **Tenants connected through the Jamf Pro API** use the community jamfpro
  plugin by Deployment Theory and one operation at a time (`PARALLELISM = 1`
  in their Environment, which the setup script sets).
- **Blocks waiting to be removed**, or a hand-over in progress, have to be
  deployed or cancelled first, so the export matches what is in Jamf.
- **Learning more:** the
  [Terraform tutorials](https://developer.hashicorp.com/terraform/tutorials),
  Deployment Theory's
  [training repository](https://github.com/deploymenttheory/terraform-training-jamfpro)
  for workplace engineers, and the `#terraform-provider-jamfpro` channel on
  the [MacAdmins Slack](https://macadmins.org/slack).
- **By hand:** [Switching to plain Terraform](ejecting.md) describes the same
  move step by step, for a single tenant without GitHub.
