# Jamf tenants as code

<!-- status badges -->

This repository manages Jamf tenants with Terraform (or OpenTofu). It was
exported from Jamf Deployer: the tenants chosen in the app are here, with the
same objects and the same state, so nothing is recreated.

This README is how to set the repository up and run it. Why it is laid out
this way, and how to grow into it, is
[Graduating to Terraform](https://github.com/JordyThery/jamf-deployer/blob/main/docs/graduating.md#stage-3--many-tenants-git-and-reviews)
(stages 3 and 4).

```
modules/<block>/          one folder per building block: the Jamf Platform API
                          module, and its Jamf Pro API version in jamfpro/
tenants/<tenant>/         one directory per tenant
  main.tf                 the tenant's blocks and how they connect
  variables.tf            typed inputs
  tenant.auto.tfvars      every setting: the file that differs between tenants
  terraform.tf            versions and the state backend
  providers.tf            provider settings (credentials come from the environment)
  not-in-code.ignore      (optional) objects the Not in code check leaves alone
tenants/_template/        the starting point scripts/new-tenant.sh copies
scripts/                  new-tenant.sh and hand-over.sh, run on your Mac
.github/workflows/        plan, apply, check for changes, not in code, restore,
                          force unlock, destroy
.github/actions/          the state backend, tenant detection and secret settings the workflows share
.github/scripts/          the Not in code comparison
.github/pull_request_template.md   the questions every pull request answers
```

## How changes flow

1. **Change the code on a branch and open a pull request.** The Plan workflow
   formats and validates the repository, plans every affected tenant, and keeps
   one comment per tenant on the pull request with its plan.
2. **Review and merge.** The review is the approval: the Apply workflow applies
   the merged change to each tenant it touched. A change to a shared module
   plans and applies every tenant.
3. **Changes made in Jamf are caught weekly.** The Check for changes workflow
   plans every tenant on Monday morning (or on demand). When something was
   changed directly in Jamf, it opens an issue named `Changed in Jamf: <tenant>`
   with the plan. Keep the change by putting it in code with a pull request, or
   add the `restore-baseline` label to put the baseline back. Resolved issues
   close on the next check.
4. **Objects made outside the code are listed weekly.** The Not in code
   workflow (Monday, after the change check) lists the object types each
   tenant's code manages and opens `Not in code: <tenant>` for objects in Jamf
   the code does not know. The issue holds their configuration (a
   `resource` and an `import` block each) to paste into a new file in the
   tenant's directory in a pull request, and lines for the tenant's
   `not-in-code.ignore` to leave them alone. That configuration includes
   what the objects contain, such as script bodies and profile payloads, one
   more reason to keep the repository private. It uses `terraform query` (Terraform 1.14 or later) and skips
   tenants on the Jamf Pro API, whose plugin cannot list objects.
5. **Destroy** is manual: run the workflow and type the tenant name twice.

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

### 3. Create two GitHub Environments per tenant

Each workflow job runs in one of the tenant's Environments, so it can only
read that tenant's credentials:

- **`<tenant>`**, named after the tenant's directory, holds the credentials
  that change Jamf. Apply, Restore, Destroy, Check for Changes and Not in
  code use it, and its deployment branch policy allows only `main`.
- **`<tenant>-plan`** holds the credentials pull request plans use. Any branch
  can use it, so anyone who can push a branch can read these credentials:
  give it a read-only API client where you can.

`create-environments.sh` in the export folder sets both up. By hand:

```bash
gh api -X PUT repos/OWNER/REPO/environments/<tenant> --input - <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
gh api -X POST repos/OWNER/REPO/environments/<tenant>/deployment-branch-policies -f name=main
gh api -X PUT repos/OWNER/REPO/environments/<tenant>-plan

# For each of the two Environments:
gh variable set JAMFPLATFORM_BASE_URL       --env <environment> --body "https://us.api.jamfcloud.com"
gh variable set JAMFPLATFORM_ENVIRONMENT_ID --env <environment> --body "<environment UUID>"
gh secret   set JAMFPLATFORM_CLIENT_ID      --env <environment>
gh secret   set JAMFPLATFORM_CLIENT_SECRET  --env <environment>
```

`gh secret set` without `--body` reads the value from standard input, so it
never appears in your shell history. Older API clients scoped to a tenant
rather than an environment set `JAMFPLATFORM_TENANT_ID` instead of
`JAMFPLATFORM_ENVIRONMENT_ID`.

Applies and destroys make one change at a time, plans read ten at a time: Jamf Pro answers simultaneous configuration profile creates with server errors. The `PARALLELISM` variable overrides both.

Tenants connected through the **Jamf Pro API** use these instead. The Jamf Pro
API plugin needs one operation at a time, which `PARALLELISM` sets:

```bash
# For each of the two Environments:
gh variable set JAMFPRO_INSTANCE_FQDN --env <environment> --body "https://yourorg.jamfcloud.com"
gh variable set JAMFPRO_AUTH_METHOD   --env <environment> --body "oauth2"   # or "basic"
gh variable set PARALLELISM           --env <environment> --body "1"
gh secret   set JAMFPRO_CLIENT_ID     --env <environment>   # basic: JAMFPRO_BASIC_USERNAME
gh secret   set JAMFPRO_CLIENT_SECRET --env <environment>   # basic: JAMFPRO_BASIC_PASSWORD
```

The workflows read both sets; the one a tenant does not use stays empty.
Tenants with Jamf Protect blocks also set `JAMFPROTECT_URL` and the
`JAMFPROTECT_CLIENT_ID` and `JAMFPROTECT_CLIENT_SECRET` secrets, in both
Environments. Secret block
settings are `TF_VAR_<name>` secrets; every workflow hands them to Terraform
(`.github/actions/secret-settings`).

### 4. Protect `main`

In the repository settings, require a pull request with at least one approving
review, and require the **Plan result** status check. Without branch
protection, anyone with write access can push straight to `main` and the review
step is optional. Branch protection guards what reaches `main`; the
Environments' branch policy is what keeps the credentials that change Jamf
away from other branches.

### 5. Optional settings

| Variable | Purpose |
| --- | --- |
| `TERRAFORM_VERSION` | Pin the Terraform version the workflows use (default: latest; Not in code needs 1.14 or later). |

## Adding a tenant

```bash
scripts/new-tenant.sh contoso-production
```

The script copies `tenants/_template` (the first exported tenant's blocks and
values), creates the tenant's two Environments, asking for each secret with
typing hidden, waits while you set its values in `tenant.auto.tfvars`, and
opens a pull request. Its plan shows everything the new tenant gets before
anything is created. It needs git and the GitHub CLI, signed in. The template
uses the first tenant's connection; for a tenant on the other API, copy a
tenant directory of that kind instead.

The directory name ties a tenant to its state, Environments and issues.
Renaming the directory alone looks like a new, empty tenant, whose first
apply would create everything again: to rename one, also move
`tenants/<old>/terraform.tfstate` to the new name on the `terraform-state`
branch and create its two Environments under the new name (GitHub cannot
rename them), before merging.

## Stopping managing a tenant

```bash
scripts/hand-over.sh contoso-production
```

The script opens a pull request that removes the tenant's directory. When it
is merged, the Apply workflow moves the tenant's state to `handed-over/` on
the `terraform-state` branch: nothing plans against the tenant again, and its
objects stay in Jamf exactly as they are. Delete its two Environments
afterwards. To delete the objects as well, run the Destroy workflow first.
(With another backend, remove the tenant's state object there yourself.)

## A stuck lock

Every run locks the tenant's state and unlocks it when it ends. A cancelled
or crashed run can leave the lock behind, as a branch named
`locks/tenants/<tenant>/terraform.tfstate`. Every later run for that tenant
then fails at Init with "Error loading state: Failed to get state … giving
up". Check under Actions that no run is still working on the tenant, then run
the **Force unlock** workflow with the tenant's name, typed twice. It shows
who held the lock and when, deletes it, and waits for any run still in
progress on the tenant first, so a lock in use is never taken away.
