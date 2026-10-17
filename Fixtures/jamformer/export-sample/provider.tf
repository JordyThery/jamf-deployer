terraform {
  required_providers {
    jamfplatform = {
      source  = "jamf/jamfplatform"
      version = ">= 1.5.0"
    }
  }
}

provider "jamfplatform" {
  base_url       = var.jamfplatform_base_url
  client_id      = var.jamfplatform_client_id
  client_secret  = var.jamfplatform_client_secret
  environment_id = var.jamfplatform_environment_id
}
