terraform {
  required_providers {
    jamfplatform = {
      source  = "jamf/jamfplatform"
      version = "1.5.0"
    }
    jamfprotect = {
      source  = "Jamf-Concepts/jamfprotect"
      version = "0.12.0"
    }
  }
}

provider "jamfplatform" {
  impact_alerts = true
}

module "foundation" {
  source         = "../../Catalog/blocks/foundation"
  name_prefix    = "JD - "
  managed_by_tag = "Managed by Jamf Deployer · foundation@1.0.0"
}
