terraform {
  required_version = ">= 1.11.0"

  required_providers {
    jamfpro = {
      source  = "deploymenttheory/jamfpro"
      version = "0.42.0"
    }
  }

  # Replace with your team's backend: one state object per tenant, with
  # locking. For example, S3 with key = "tenants/catalog-test-jp/terraform.tfstate",
  # encrypt = true and use_lockfile = true.
  backend "local" {
    path = "terraform.tfstate"
  }
}
