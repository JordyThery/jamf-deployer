# Read-only entitlement probe: data source only.
terraform {
  required_providers {
    jamfplatform = {
      source  = "jamf/jamfplatform"
      version = "1.5.0"
    }
  }
}

provider "jamfplatform" {
}

data "jamfplatform_security_cloud_device_groups" "all" {}

output "group_count" {
  value = length(data.jamfplatform_security_cloud_device_groups.all.device_groups)
}
