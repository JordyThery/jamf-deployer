# Graduating to Terraform

Jamf Deployer is a way in, not a place to stay. Underneath every preview and
deploy runs OpenTofu, a Terraform-compatible engine, against ordinary
configuration and an ordinary state file. This guide takes you from using the
app to running Terraform (or OpenTofu) yourself, with your Jamf configuration
in Git and changes reaching any number of instances through reviewed pull
requests, with or without the app.

It is one path in five stages. Each stage starts from what you did in the one
before, uses your own tenant rather than a toy example, and ends with a
checkpoint: when you can do what it describes, move on. You can stop at any
stage; the app keeps working throughout.

| Stage | You will | You need |
| --- | --- | --- |
| [0. What you already know](#stage-0--what-you-already-know) | Put names to what the app does | Nothing |
| [1. Watch the engine work](#stage-1--watch-the-engine-work) | Read a plan, then run one yourself | A tenant in the app |
| [2. Run one tenant yourself](#stage-2--run-one-tenant-yourself) | Plan and apply from the command line | Terraform, about an hour |
| [3. Many tenants, Git and reviews](#stage-3--many-tenants-git-and-reviews) | Change Jamf through a pull request | A private GitHub repository |
| [4. Run a fleet](#stage-4--run-a-fleet) | Change every instance at once, handle drift | Stage 3's repository |

**Not using Jamf Deployer?** Read stage 0 for the vocabulary, then start at
[stage 2b](#2b-start-from-scratch); the rest applies unchanged.

## Stage 0 — What you already know

Everything the app does has a Terraform name:

| In the app | In Terraform |
| --- | --- |
| Building block | A **module**: a folder of `.tf` files with inputs (`variables.tf`) and outputs |
| A tenant's baseline | The tenant's **root module**: one `module` call per block, in `main.tf` |
| Block settings | **Input variables**, with their values in a `.tfvars` file |
| A block filing into another block's category or group | A **reference** between modules: `module.categories.category_ids["Security"]` |
| Connection (Jamf Platform API or Jamf Pro API) | A **provider**: the `jamf/jamfplatform` or `deploymenttheory/jamfpro` plugin and its credentials |
| The tenant record of what is managed | The **state** file, one per tenant |
| Preview Changes | `terraform plan` |
| Deploy | `terraform apply` of the plan you approved |
| Check for Changes | `terraform plan`, run on a schedule, reporting changes made in Jamf |
| Restore Baseline | `terraform apply` |
| Keep This Change | Changing the code, so the next plan agrees with Jamf |
| Adopt | **Importing**: an `import` block tells Terraform an object already exists |
| Team Mode locks | **State locking** in the state backend |
| Baseline updates, rollout rings | **Module versions**: tenants move to a newer version of a module one by one |
| History | Git history and pull requests |

Three ideas carry everything else:

- **Configuration** says what should exist. It is text you edit and review.
- **State** records which real objects the configuration manages, so
  Terraform can tell creating apart from changing. Losing it does not delete
  anything in Jamf, but Terraform no longer knows what it manages.
- **A plan** compares the two with Jamf and lists exactly what an apply would
  change. Plans only read; applies write. Every safe workflow is "plan,
  review, then apply that plan".

**Where the tools sit.** Jamf's tooling runs from guided to build-your-own:
Onboarder sets up a new instance in one pass; Jamf Deployer gives you curated
building blocks and keeps state, so it can also run the instance afterwards;
the Terraform providers let you design everything yourself. This path moves
you from the middle to the end.

**Checkpoint:** you can explain, in your own words, what a plan, a state file
and a module are.

## Stage 1 — Watch the engine work

In **Settings → Show technical details**, turn the setting on. Every Preview
Changes now ends with **Behind this preview**:

- the engine commands the preview ran (`tofu init`, then `tofu plan`), and
  the one Deploy will run;
- the generated configuration: `main.tf`, with one module call per block,
  and `providers.tf`;
- **Show Workspace in Finder** and **Open in Terminal**, both opening the
  tenant's workspace: the folder the engine runs in.

Read `main.tf` next to the baseline in the app: each selected block is a
`module` block, and each setting you chose is an argument to it.

**Now run the plan yourself.** Choose **Open in Terminal** and run:

```sh
./plan.sh
```

`plan.sh` runs the same plan the preview ran, with the same engine,
configuration and state, and prints it the way Terraform prints plans. The
first time, macOS asks whether `security` may read the tenant's credentials
from your Keychain: the script reads them while it runs and never writes them
to a file. A plan only reads, so nothing in Jamf changes. Anything after
`./plan.sh` is passed to the plan: `./plan.sh -target=module.categories`
plans one block.

Read the output from the top: every object is listed with a symbol (`+`
create, `~` change in place, `-/+` replace, `-` destroy) and the summary line
counts them. Change a setting in the app, run `./plan.sh` again, and find
your change in the plan.

Two things to know: the app uses OpenTofu, whose commands are the same as
Terraform's (`tofu plan`, `terraform plan`); and in Team Mode `plan.sh`
explains why it cannot run, because the team's state sits behind the app's
own state backend. Use stage 3 instead.

**Checkpoint:** you ran a plan yourself and can say what it would change.

## Stage 2 — Run one tenant yourself

This stage takes one tenant to the command line. Start from the app (2a) or
from nothing (2b); both end with the same project.

**Install Terraform** from
[developer.hashicorp.com/terraform/install](https://developer.hashicorp.com/terraform/install)
(on a Mac: `brew tap hashicorp/tap && brew install hashicorp/tap/terraform`),
or OpenTofu from [opentofu.org](https://opentofu.org/docs/intro/install/)
(`brew install opentofu`). Terraform 1.14 or later lists existing objects
(stage 4 uses that); both work for everything else.

**Credentials are environment variables**, never files. For a tenant on the
Jamf Platform API:

```sh
export JAMFPLATFORM_BASE_URL="https://eu.api.jamfcloud.com"   # your region: us, eu or apac
export JAMFPLATFORM_ENVIRONMENT_ID="…"                        # older tenant-scope clients: JAMFPLATFORM_TENANT_ID
export JAMFPLATFORM_CLIENT_ID="…"
export JAMFPLATFORM_CLIENT_SECRET="…"
# Jamf Protect blocks also need JAMFPROTECT_URL, JAMFPROTECT_CLIENT_ID and JAMFPROTECT_CLIENT_SECRET.
```

For a tenant on the Jamf Pro API, through the community jamfpro plugin:

```sh
export JAMFPRO_INSTANCE_FQDN="https://yourorg.jamfcloud.com"
export JAMFPRO_AUTH_PROVIDER="direct"
export JAMFPRO_AUTH_METHOD="oauth2"            # or "basic" for a user account
export JAMFPRO_CLIENT_ID="…"                   # basic: JAMFPRO_BASIC_USERNAME
export JAMFPRO_CLIENT_SECRET="…"               # basic: JAMFPRO_BASIC_PASSWORD
```

That plugin needs one operation at a time: add `-parallelism=1` to its plans
and applies. Secret block settings arrive the same way, as `TF_VAR_<name>`
variables.

### 2a. Take a tenant out of the app

**1. Copy the workspace.** Solo installs keep it in
`~/Library/Application Support/Jamf Deployer/store/tenants/<id>/` (the tenant's
ID is in its record's `tenant.json`; **Show Workspace in Finder** opens
`generated/` inside it):

```sh
mkdir ~/my-tenant
cp -R "…/store/tenants/<id>/generated" ~/my-tenant/generated
cp -R "…/store/tenants/<id>/state"     ~/my-tenant/state
cd ~/my-tenant/generated
rm -rf .terraform .terraform.lock.hcl plan.bin drift.bin plan.sh
```

The lock file records checksums of the app's own provider copies, which the
public registries' packages do not match, so it goes. `providers.tf` points
the state at `../state/terraform.tfstate`, which the layout above keeps.

**Team installs** keep the state on the team space's `jamf-deployer-state`
branch. Copy it into `~/my-tenant/state`, and in `generated/providers.tf`
replace `backend "http" {}` with
`backend "local" { path = "../state/terraform.tfstate" }`:

```sh
mkdir -p ~/my-tenant/state
git -C "…/store" fetch origin jamf-deployer-state
git -C "…/store" show "origin/jamf-deployer-state:tenants/<id>/terraform.tfstate" \
  > ~/my-tenant/state/terraform.tfstate
```

(Or choose **Leave Team Mode…** on one Mac first: it moves every tenant's
state back into its workspace, encrypted with the tenant's own passphrase.)

**2. Decrypt the state once.** The app encrypts state with OpenTofu's state
encryption, using the passphrase on the tenant's recovery sheet (in Team
Mode, the team passphrase). HashiCorp Terraform cannot read encrypted state,
so decrypt it once with OpenTofu:

```sh
export TF_ENCRYPTION='
key_provider "pbkdf2" "passphrase" {
  passphrase = "<passphrase from the recovery sheet>"
}
method "aes_gcm" "old" {
  keys = key_provider.pbkdf2.passphrase
}
method "unencrypted" "plain" {}
state {
  method   = method.unencrypted.plain
  fallback { method = method.aes_gcm.old }
}
plan {
  method   = method.unencrypted.plain
  fallback { method = method.aes_gcm.old }
}'

tofu init
tofu apply -refresh-only   # reads the encrypted state, writes it back unencrypted
unset TF_ENCRYPTION
```

Staying on OpenTofu? Skip this step and keep a `TF_ENCRYPTION` with `aes_gcm`
as the active method, as `plan.sh` sets it.

**3. Move the providers to Terraform's registry.**

```sh
terraform init
terraform state replace-provider \
  registry.opentofu.org/jamf/jamfplatform registry.terraform.io/jamf/jamfplatform
```

Tenants with Jamf Protect blocks also move `jamf-concepts/jamfprotect` the
same way; tenants on the Jamf Pro API move `deploymenttheory/jamfpro` instead
of `jamf/jamfplatform`.

**4. Tell the app.** Remove the tenant from the app, or hand it over, so the
tenant has one owner. Nothing in Jamf changes either way.

### 2b. Start from scratch

**1. An API client.** In Jamf Account, create a Jamf Platform API
integration scoped to your environment, with the privileges the objects you
plan to manage need. Note its client ID and secret, your region's URL and the
environment ID; export them as above.

**2. A first configuration.** In an empty folder, `main.tf`:

```hcl
terraform {
  required_providers {
    jamfplatform = {
      source  = "jamf/jamfplatform"
      version = "~> 1.5"
    }
  }
}

provider "jamfplatform" {}   # credentials come from the environment

resource "jamfplatform_pro_category" "security" {
  name     = "Security"
  priority = 9
}
```

Run `terraform init`, then `terraform plan`: one category to add. Apply it
with `terraform apply` and find it in Jamf Pro.

**3. Bring in what already exists.** Most instances are not empty. Terraform
can list existing objects and write their configuration for you. Add
`existing.tfquery.hcl`:

```hcl
list "jamfplatform_pro_category" "all" {
  provider = jamfplatform
}
```

```sh
terraform query                                 # lists every category with its ID
terraform query -generate-config-out=existing.tf
```

`existing.tf` now holds a `resource` block and an `import` block per
category, including the one step 2 created. Delete that one: Terraform
already manages it, and importing it again would have two addresses manage
one category (the plan would say `2 to import` instead of `1`). Remove any
others you do not want to manage, rename the rest sensibly (`all_0` becomes
`printers`), and `terraform plan` shows them as imports, not creates.
`terraform apply` records them; Jamf does not change. For a whole instance at
once, [jamformer](https://github.com/Jamf-Concepts/jamformer) exports every
supported object type as a ready project.

**4. Use modules instead of one block per object.** Group related objects
into a module with inputs, so the same module serves every instance. Jamf
Deployer's demo catalog is a set of such modules you can use directly:

```hcl
module "categories" {
  source         = "git::https://github.com/JordyThery/jamf-deployer-catalog.git//blocks/categories?ref=v1.0.0"
  name_prefix    = ""
  managed_by_tag = "Managed by Terraform"
}
```

Every block takes `name_prefix` and `managed_by_tag`; its other inputs are in
its `variables.tf`. Tenants on the Jamf Pro API use the block's `jamfpro`
folder: `//blocks/categories/jamfpro?ref=v1.0.0`.

### Both: prove it, then change something

```sh
terraform plan   # "No changes. Your infrastructure matches the configuration."
```

A plan with no changes proves the configuration and state describe Jamf as
it is. Now make one small change (rename a category, change a setting),
`terraform plan` to see exactly that change, `terraform apply`, check Jamf,
then revert and apply again.

**Checkpoint:** you got a plan with no changes, and made and reverted one
change entirely from the command line.

## Stage 3 — Many tenants, Git and reviews

One tenant from a laptop works; a team and a fleet need the configuration in
Git, state that everyone shares, and changes that are reviewed before they
reach Jamf. That is the layout Jamf's own multi-tenant reference uses
([Jamf-Concepts/terraform-jamf-platform](https://github.com/Jamf-Concepts/terraform-jamf-platform)),
and the one **Export as Terraform…** writes:

```
modules/<block>/        one shared module per building block, used by every tenant
tenants/<tenant>/       the tenant's root module:
  main.tf                 its module calls and how they connect
  variables.tf            typed inputs
  tenant.auto.tfvars      its settings: the file that differs between tenants
  terraform.tf            versions and the state backend
  providers.tf            provider settings (credentials come from the environment)
tenants/_template/      a starting point for the next tenant
scripts/                adding and handing over tenants
.github/workflows/      plan, apply, checks, restore, unlock, destroy
README.md               how to set it up and run it
```

**Why each piece is there:**

- **Shared modules, thin tenant folders.** A tenant folder only says which
  modules it uses and with what values. Changing a module changes every
  tenant that uses it; changing a `tenant.auto.tfvars` changes one tenant.
- **One state per tenant,** each with its own lock, so a mistake or a stuck
  run touches one tenant, and plans stay fast. The repository's
  `terraform-state` branch holds them; S3 or HCP Terraform work too.
- **Credentials per tenant in GitHub Environments.** Each tenant has two:
  `<tenant>` with the credentials that change Jamf, usable only from `main`,
  and `<tenant>-plan` for pull request plans, which can take a read-only API
  client. A job only ever sees one tenant's secrets.
- **Pull requests are the approval.** The Plan workflow posts each affected
  tenant's plan on the pull request; a reviewer approves a diff, not a
  description of one; merging applies exactly that.

**From the app:** on the dashboard, choose **Export as Terraform…**, tick the
tenants and an empty folder. **Keep managing here** writes the repository to
read and run `terraform validate` against; nothing moves. **Move to a
repository** also moves each tenant's state to an empty private repository's
`terraform-state` branch, publishes the code as its first commit, and archives
the tenants in the app; every object stays in Jamf. Each tenant must have
nothing left to deploy and no changes made in Jamf, so the repository's first
plan shows no changes. In Team Mode, the app syncs first and refuses tenants
a teammate is working on.

**Without the app:** lay out stage 2's project the same way (your modules
under `modules/`, one folder per tenant, a backend per tenant) and copy the
workflows from an export, or from the Jamf-Concepts reference.

**Then set it up** as the repository's README describes: create each
tenant's Environments (`./create-environments.sh OWNER/REPOSITORY` in an
export folder), and protect `main` with a required review and the **Plan
result** check.

**Exercise: your first reviewed change.** On a branch, change one value in a
tenant's `tenant.auto.tfvars`, push, and open a pull request. Read the plan
comment: it should show that one change and nothing else. Merge it, watch the
Apply workflow, and check Jamf.

**Checkpoint:** a change reached Jamf through a reviewed pull request, and you
did not open the app.

## Stage 4 — Run a fleet

### Push one change to every instance

This is what the layout is for. Say every tenant should get a "Printers"
category. On a branch, add it to the shared module, in
`modules/categories/main.tf`:

```hcl
locals {
  categories = ["Applications", "Enrollment", "Maintenance", "Printers", "Security"]
}
```

A block comes in two versions, one per plugin: tenants on the Jamf Pro API
use the one in `modules/categories/jamfpro/`. Make the same change there,
or those tenants plan no changes.

Open the pull request. Because a module changed, the Plan workflow plans
**every** tenant, and posts one comment per tenant: each should read
`1 to add`. A tenant whose plan says something else is worth a look before
merging: it usually means that tenant differs from what the code says. Merge,
and the Apply workflow applies every tenant, one job each.

### Roll out in rings: version your modules

Applying everywhere at once is fine for a category; a new security policy
deserves a pilot. Keep two versions of the module side by side and move
tenants from one to the other:

```
modules/security-policy-v1/   what every tenant runs today
modules/security-policy-v2/   the new version
```

Point the pilot tenants' `source` at `../../modules/security-policy-v2` in
one pull request, check them, then move the rest in a second, and delete
`-v1` when nothing uses it. (The export writes this layout itself when
tenants run different versions of a block.) This is the app's baseline
updates and rollout rings, in Terraform.

When modules outgrow one repository, keep them in their own and tag
releases; tenants then pin a version with
`source = "git::https://github.com/<org>/<modules>.git//security-policy?ref=v2.0.0"`.
Workflows downloading from a private modules repository need a token that
can read it.

### Changes made in Jamf

The **Check for changes** workflow plans every tenant on Monday mornings.
When someone changed a managed object in Jamf, an issue titled `Changed in
Jamf: <tenant>` shows the plan. Then decide: **keep** the change by putting
it in code with a pull request, so the next plan agrees with Jamf; or
**undo** it by adding the `restore-baseline` label to the issue, which applies
the code again. The issue closes itself when a later check finds nothing.

### Objects made outside the code

The change check only sees objects the code manages. The **Not in code**
workflow (Mondays, after the change check) lists everything of the types a
tenant's code manages, and opens `Not in code: <tenant>` when Jamf has
objects the code does not know, such as a policy made by hand. To adopt
them, the issue holds their configuration, generated the way stage 2b did it:
a `resource` block and an `import` block each. Paste it into a new file in
the tenant's folder (`imported.tf`) in a pull request; the plan shows each
object as an import, and merging records them without changing Jamf. To
leave an object alone instead, copy its line from the issue into the
tenant's `not-in-code.ignore`. It needs Terraform 1.14 or later,
and skips tenants on the Jamf Pro API, whose plugin cannot list objects.

### Tenants come and go

A tenant's directory name is how the repository knows it: its state, its
Environments and its issues all use it. Renaming the directory alone looks
like a new, empty tenant, whose first apply would create everything again.
To rename one, also move its state file to the new name on the
`terraform-state` branch and create its two Environments under the new name
(GitHub cannot rename them), before merging.

- **Add one:** `scripts/new-tenant.sh contoso-production` copies
  `tenants/_template`, creates the tenant's two Environments (asking for each
  secret), lets you set its values, and opens a pull request whose plan shows
  everything the tenant would get.
- **Stop managing one:** `scripts/hand-over.sh contoso-production` opens a
  pull request that removes its folder. Once merged, its state moves to
  `handed-over/` on the state branch, and its objects stay in Jamf untouched.
  To delete the objects as well, run the **Destroy tenant** workflow first.
- **A stuck lock:** a cancelled run can leave a tenant's state locked, and
  later runs then fail at Init with "Failed to get state". Once you are sure
  no run is still working on the tenant, run the **Force unlock** workflow
  with the tenant's name: it shows who held the lock and since when, and
  removes it.

### Growing up

- **State:** the `terraform-state` branch needs nothing but the repository,
  but anyone who can read the repository can read the state, unencrypted.
  For more tenants or a stricter separation, move to S3 with encryption or
  HCP Terraform (`terraform init -migrate-state`, one tenant at a time); the
  repository's README shows the S3 backend.
- **What not to manage:** not everything belongs in code. Static group
  membership, break-glass accounts and anything that changes by the hour are
  better left to Jamf.
- **Keep plans readable:** lists and maps in `tenant.auto.tfvars`
  (`for_each` over them in the module) keep a fleet's configuration short;
  adding the 200th category should be a one-line diff.
- **Check what the app checked:** the app refused deploys while a preview was
  open, translated errors and kept history. In the repository, branch
  protection, required reviews and the Actions log do that job.

### Do you still need the app?

No. Everything in this stage runs from Git and your terminal. The app stays
useful for what is awkward to do by hand: capturing an instance's objects as
building blocks, adopting a hand-configured instance, the Day 0 steps an API
cannot do, and exploring a new instance before writing code for it. Use it
for those if you like, and let the repository own the tenants.

**Checkpoint:** you shipped one change to every tenant, rolled another out
ring by ring, and handled a change made in Jamf, all without the app.

## Further reading

Where to go next, and when:

- **[Jamf's Terraform resources](https://developer.jamf.com/platform-api/docs/resources-terraform-github-and-jamf-configurations)**:
  Jamf's overview of infrastructure as code for Jamf, with learning tracks.
  Good company for stage 0 and 1.
- **Provider documentation** on the Terraform registry:
  [jamf/jamfplatform](https://registry.terraform.io/providers/jamf/jamfplatform/latest/docs),
  [Jamf-Concepts/jamfprotect](https://registry.terraform.io/providers/Jamf-Concepts/jamfprotect/latest/docs) and
  [deploymenttheory/jamfpro](https://registry.terraform.io/providers/deploymenttheory/jamfpro/latest/docs).
  Every resource, its arguments and examples; keep it open from stage 2 on.
- **[Jamf-Concepts/terraform-jamf-platform](https://github.com/Jamf-Concepts/terraform-jamf-platform)**:
  Jamf's reference projects, single tenant and multi-tenant, with their
  workflows. Compare with your repository in stage 3.
- **[Deployment Theory's training repository](https://github.com/deploymenttheory/terraform-training-jamfpro)**:
  exercises for workplace engineers new to Terraform. Useful alongside
  stage 2.
- **[HashiCorp's Terraform tutorials](https://developer.hashicorp.com/terraform/tutorials)**
  and the [OpenTofu documentation](https://opentofu.org/docs/): the language
  itself, state, modules and backends.
- **[jamformer](https://github.com/Jamf-Concepts/jamformer)**: exports an
  existing instance as Terraform. Stage 2b, for a whole instance.
- **The MacAdmins Slack** ([macadmins.org/slack](https://macadmins.org/slack)),
  `#terraform-provider-jamfpro`: questions, answers and other people's layouts.

## Credits

The export, its layout and its pipeline follow what these JNUC 2026 sessions
shared from running Jamf as code in production (recordings to follow):

- **Managing the Jamf Platform at Scale With IaC**, by Kyle and Neil Martin
  (Jamf), and its reference project
  [Jamf-Concepts/terraform-jamf-platform](https://github.com/Jamf-Concepts/terraform-jamf-platform).
- **From ClickOps to GitOps: Migrating Jamf Pro at Enterprise Scale to
  Terraform**, by Joseph, Gordon and Dafydd (Lloyds Banking Group).
- **From Zero to GitOps: Training a Mac Team to Work Like DevOps Engineers**,
  by Joseph, Gordon and Dafydd (Lloyds Banking Group).
