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

module "app_catalog" {
  source                  = "../../Catalog/blocks/app-catalog"
  name_prefix             = "JD - "
  managed_by_tag          = "Managed by Jamf Deployer · app-catalog@1.0.0"
  scope_jamf_pro_group_id = module.foundation.all_macs_jamf_pro_id
  category_id             = module.foundation.category_applications_id
  apps_json               = "[{\"titleName\":\"Google Chrome\",\"publisher\":\"Google\",\"deploymentType\":\"SELF_SERVICE\",\"updateBehavior\":\"AUTOMATIC\"}]"
}

provider "jamfprotect" {
}

module "protect_baseline" {
  source         = "../../Catalog/blocks/protect-baseline"
  name_prefix    = "JD - "
  managed_by_tag = "Managed by Jamf Deployer · protect-baseline@1.0.0"
}

module "security_cloud" {
  source         = "../../Catalog/blocks/security-cloud"
  name_prefix    = "JD - "
  managed_by_tag = "Managed by Jamf Deployer · security-cloud@1.1.0"
}
