# Switching to plain Terraform

Jamf Deployer never locks you in. Every tenant workspace is a standard root
module, and the record of what the app manages is a standard state file.
This guide takes a tenant out of the app and into a plain **HashiCorp
Terraform** or **OpenTofu** workflow — command line or CI — with full
continuity: nothing is recreated, the state carries over.

## What you need

1. The tenant's workspace folder. Solo installs:
   `~/Library/Application Support/Jamf Deployer/store/tenants/<id>/`
   — team installs: the same path, on a Mac that has run a preview for the
   tenant (`generated/` is rebuilt locally and is not in the repository).
2. The tenant's **recovery sheet** (saved at first deploy). It holds the
   passphrase that encrypts the state file. Without it the state is
   unreadable — by anyone, including the app.
3. The tenant's Jamf API credentials (the app kept them in your Keychain;
   they never lived in any file).

## Step 1 — copy the workspace out

```sh
mkdir ~/my-tenant
cp -R "…/store/tenants/<id>/generated" ~/my-tenant/generated
cp -R "…/store/tenants/<id>/state"     ~/my-tenant/state
cd ~/my-tenant/generated
rm -rf .terraform .terraform.lock.hcl plan.bin drift.bin
```

Remove the lock file: it records checksums of the app's bundled provider
copies, which the public registries' packages do not match, so `init` would
refuse them. `generated/providers.tf` points the local backend at
`../state/terraform.tfstate`, which the layout above keeps intact. The providers are declared as `jamf/jamfplatform` and
`Jamf-Concepts/jamfprotect`, which resolve on **both** the Terraform and
OpenTofu public registries — the configuration itself needs no edits.

## Step 2 — provide the same environment the app provided

```sh
export JAMFPLATFORM_BASE_URL="https://eu.api.jamfcloud.com"   # your region
export JAMFPLATFORM_CLIENT_ID="…"
export JAMFPLATFORM_CLIENT_SECRET="…"
export JAMFPLATFORM_ENVIRONMENT_ID="…"                        # or JAMFPLATFORM_TENANT_ID
# Jamf Protect blocks additionally need:
# export JAMFPROTECT_URL=… JAMFPROTECT_CLIENT_ID=… JAMFPROTECT_CLIENT_SECRET=…
```

Secret-typed block settings (if any) arrive the same way, as `TF_VAR_…`
variables — `generated/main.tf` declares them at the top as sensitive
variables named `<block>_<setting>`.

## Step 3 — decrypt the state once

The app encrypts state with OpenTofu's native state encryption, which
HashiCorp Terraform cannot read. Decrypt it once with OpenTofu
(`brew install opentofu`), then it is an ordinary state file:

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
tofu apply -refresh-only   # reads encrypted, writes plaintext
unset TF_ENCRYPTION
```

Staying on OpenTofu instead? Skip this step and keep the original
`TF_ENCRYPTION` block (with `aes_gcm` as the active method) — everything
else in this guide applies unchanged.

## Step 4 — run it under Terraform

```sh
terraform init    # providers install from registry.terraform.io
terraform plan    # should report no changes if the tenant is in sync
```

The state still names the providers by their OpenTofu registry address, so
`terraform init` installs each one twice. Point the state at Terraform's
registry once to tidy that up:

```sh
terraform state replace-provider \
  registry.opentofu.org/jamf/jamfplatform registry.terraform.io/jamf/jamfplatform
```

From here it is an ordinary Terraform project: edit the HCL, move the state
to any backend (`terraform init -migrate-state`), wire the environment
variables through your CI's secret store, re-encrypt with your own tooling
if your pipeline calls for it.

## Good to know

- **You own the configuration now.** The app regenerated `generated/` from
  its model on every run; after switching, the HCL is yours to edit, and the
  app's record of that tenant should be removed or handed over so there is
  only one owner.
- **Building blocks become modules.** `generated/modules/` contains each
  block as a plain module — keep, rename or inline them as you prefer.
- **Adopted objects are plain files.** They sit at the root of `generated/`
  as `adopted-*.tf` (copied from `tenants/<id>/adopted/`) and come along
  with the rest of the workspace.
- **History stays readable.** `tenants/<id>/history/`, next to `generated/`,
  is plain JSON (sensitive values masked) and remains useful forever, with
  or without the app.
- **Credentials and permissions** are unchanged: the same API clients keep
  working, with the privileges listed in [Permissions](permissions.md).
