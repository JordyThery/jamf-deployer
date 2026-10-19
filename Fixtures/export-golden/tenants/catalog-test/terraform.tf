terraform {
  required_version = ">= 1.11.0"

  required_providers {
    jamfplatform = {
      source  = "jamf/jamfplatform"
      version = "1.5.0"
    }
  }

  # Replace with your team's backend: one state object per tenant, with
  # locking. For example, S3 with key = "tenants/catalog-test/terraform.tfstate",
  # encrypt = true and use_lockfile = true.
  backend "local" {
    path = "terraform.tfstate"
  }
}
