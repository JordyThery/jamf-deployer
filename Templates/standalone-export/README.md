# Jamf tenants as code

This repository manages Jamf tenants with Terraform (or OpenTofu). It was
exported from Jamf Deployer: every tenant the app managed is here, with the
same objects and the same state, so nothing is recreated.

```
modules/<block>/          one module per building block
tenants/<tenant>/         one directory per tenant
  main.tf                 the tenant's blocks and how they connect
  variables.tf            typed inputs
  tenant.auto.tfvars      every setting: the file that differs between tenants
  terraform.tf            versions and the state backend
  providers.tf            provider settings (credentials come from the environment)
.github/workflows/        plan, apply, check for changes, restore, destroy
.github/actions/          the state backend and tenant detection the workflows share
```

## How changes flow

1. **Change the code on a branch and open a pull request.** The Plan workflow
   formats and validates the repository, plans every affected tenant, and keeps
   one comment per tenant on the pull request with its plan.
2. **Review and merge.** The review is the approval: the Apply workflow applies
   the merged change to each tenant it touched. A change to a shared module
   plans and applies every tenant.
3. **Changes made in Jamf are caught weekly.** The Check for Changes workflow
   plans every tenant on Monday morning (or on demand). When something was
   changed directly in Jamf, it opens an issue named `Changed in Jamf: <tenant>`
   with the plan. Keep the change by putting it in code with a pull request, or
   add the `restore-baseline` label to put the baseline back. Resolved issues
   close on the next check.
4. **Destroy** is manual: run the workflow and type the tenant name twice.

## Setting up

### 1. Push this repository to GitHub

Make it **private**. The workflows run from the default branch.

### 2. Choose where state lives

Each tenant's state is one object with its own lock.

- **As shipped:** a `terraform-state` branch of this repository, written by
  terraform-backend-git on the runner (`.github/actions/state-backend`). It
  needs no other account. Terraform stores state unencrypted, so anyone who can
  read this repository can read the state: keep it private, or use one of the
  options below.
- **S3:** replace `backend "http" {}` in each `tenants/*/terraform.tf` with
  ```hcl
  backend "s3" {
    bucket       = "your-state-bucket"
    key          = "tenants/<tenant>/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
  ```
  and replace the state-backend step in the workflows with your AWS
  credentials (OIDC role assumption is preferred over static keys).
- **OpenTofu** encrypts state on the client with a passphrase you keep in a
  secret (`TF_ENCRYPTION`); swap `hashicorp/setup-terraform` for
  `opentofu/setup-opentofu` and `terraform` for `tofu`.

### 3. Create one GitHub Environment per tenant

The Environment's name is the tenant's directory name. Each workflow job runs
in the tenant's Environment, so it can only read that tenant's credentials.

```bash
gh api -X PUT repos/OWNER/REPO/environments/<tenant>
gh variable set JAMFPLATFORM_BASE_URL       --env <tenant> --body "https://us.api.jamfcloud.com"
gh variable set JAMFPLATFORM_ENVIRONMENT_ID --env <tenant> --body "<environment UUID>"
gh secret   set JAMFPLATFORM_CLIENT_ID      --env <tenant>
gh secret   set JAMFPLATFORM_CLIENT_SECRET  --env <tenant>
```

`gh secret set` without `--body` reads the value from standard input, so it
never appears in your shell history. Tenants connected through the Jamf Pro
API use `JAMFPRO_INSTANCE_FQDN`, `JAMFPRO_AUTH_METHOD`, `JAMFPRO_CLIENT_ID`
and `JAMFPRO_CLIENT_SECRET` instead (set the same names in the workflows'
`env:` blocks), and must plan and apply with `-parallelism=1`. Secret block
settings arrive the same way, as `TF_VAR_<name>` secrets.

### 4. Protect `main`

In the repository settings, require a pull request with at least one approving
review, and require the **Plan result** status check. Without branch
protection, anyone with write access can push straight to `main` and the review
step is optional.

### 5. Optional settings

| Variable | Purpose |
| --- | --- |
| `TERRAFORM_VERSION` | Pin the Terraform version the workflows use (default: latest). |

## Adding a tenant

Copy an existing tenant directory, change `tenant.auto.tfvars`, create the
tenant's Environment, and open a pull request. The plan shows everything the
new tenant gets before anything is created.

## Stopping managing a tenant

To leave a tenant's objects in Jamf and stop managing them, delete its
directory in a pull request and remove its state object
(`tenants/<tenant>/terraform.tfstate` on the `terraform-state` branch, or in
your bucket). To delete its objects as well, run the Destroy workflow first.
