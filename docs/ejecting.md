# Leaving Jamf Deployer: running your tenants on plain OpenTofu

Jamf Deployer never locks you in. Every tenant workspace is a standard
OpenTofu root module, and the record of what the app manages is a standard
(encrypted) state file. This guide takes a tenant from the app to a plain
command-line or CI setup with full continuity — nothing is recreated.

## What you need

1. The tenant's workspace folder. Solo installs:
   `~/Library/Application Support/Jamf Deployer/store/tenants/<id>/`
   — team installs: the same path inside the team repository.
2. The tenant's **recovery sheet** (saved when you first deployed). It holds
   the passphrase that encrypts the state file. Without it, the state is
   unreadable — by anyone, including the app.
3. The tenant's Jamf API credentials (Jamf Deployer kept them in your
   Keychain; they never lived in any file).
4. OpenTofu 1.13 or newer (`brew install opentofu`).

## Steps

```sh
# 1. Copy the configuration and the record out of the app's store.
cp -R "…/store/tenants/<id>/generated" ~/my-tenant
cp -R "…/store/tenants/<id>/state"     ~/my-tenant-state
cd ~/my-tenant

# 2. Point the configuration at the copied record.
#    generated/providers.tf already contains:
#      backend "local" { path = "../state/terraform.tfstate" }
#    Adjust the path if you placed the state elsewhere.

# 3. Provide the same environment the app provided.
export JAMFPLATFORM_BASE_URL="https://eu.api.jamfcloud.com"   # your region
export JAMFPLATFORM_CLIENT_ID="…"
export JAMFPLATFORM_CLIENT_SECRET="…"
export JAMFPLATFORM_ENVIRONMENT_ID="…"                        # or JAMFPLATFORM_TENANT_ID
# Jamf Protect blocks additionally need:
# export JAMFPROTECT_URL=… JAMFPROTECT_CLIENT_ID=… JAMFPROTECT_CLIENT_SECRET=…

export TF_ENCRYPTION='
key_provider "pbkdf2" "passphrase" {
  passphrase = "<passphrase from the recovery sheet>"
}
method "aes_gcm" "default" {
  keys = key_provider.pbkdf2.passphrase
}
state {
  method   = method.aes_gcm.default
  enforced = true
}
plan {
  method   = method.aes_gcm.default
  enforced = true
}'

# 4. Initialize and verify.
tofu init          # providers install from the public OpenTofu registry
tofu plan          # should report no changes if the tenant is in sync
```

From here on it is ordinary OpenTofu: edit the HCL, plan, apply, move the
state to any backend you like (`tofu init -migrate-state`).

## Good to know

- **You own the configuration now.** The app regenerated `generated/` from
  its model on every run; after ejecting, the HCL is yours to edit and the
  app's record of that tenant should be removed (or handed over) to avoid
  two owners.
- **OpenTofu, not HashiCorp Terraform.** The state is encrypted with
  OpenTofu's native state encryption, which HashiCorp Terraform cannot
  read. To move to Terraform, first migrate the encryption off
  (an OpenTofu encryption `fallback` migration to an unencrypted target),
  then treat the usual OpenTofu→Terraform compatibility notes as applying.
- **Secrets stay yours.** The app never wrote credentials to disk; wire the
  environment variables through your CI's secret store the same way.
- **History**: the `history/` folders next to the workspace are plain JSON
  and remain readable forever, with or without the app.
