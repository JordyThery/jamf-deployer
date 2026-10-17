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

module "enrollment" {
  source            = "../../Catalog/blocks/enrollment"
  name_prefix       = "JD - "
  managed_by_tag    = "Managed by Jamf Deployer · enrollment@1.0.0"
  ade_instance_name = "Apple Business Manager"
}

module "filevault" {
  source                  = "../../Catalog/blocks/filevault"
  name_prefix             = "JD - "
  managed_by_tag          = "Managed by Jamf Deployer · filevault@1.0.0"
  scope_jamf_pro_group_id = module.foundation.pilot_jamf_pro_id
  category_id             = module.foundation.category_security_id
}

module "software_updates" {
  source                    = "../../Catalog/blocks/software-updates"
  name_prefix               = "JD - "
  managed_by_tag            = "Managed by Jamf Deployer · software-updates@1.0.0"
  scope_platform_group_uuid = module.foundation.pilot_platform_uuid
}

module "compliance_cis_l1" {
  source                    = "../../Catalog/blocks/compliance-cis-l1"
  name_prefix               = "JD - "
  managed_by_tag            = "Managed by Jamf Deployer · compliance-cis-l1@1.0.0"
  scope_platform_group_uuid = module.foundation.pilot_platform_uuid
}

module "rosetta" {
  source                  = "../../Catalog/blocks/rosetta"
  name_prefix             = "JD - "
  managed_by_tag          = "Managed by Jamf Deployer · rosetta@1.0.0"
  scope_jamf_pro_group_id = module.foundation.apple_silicon_jamf_pro_id
  category_id             = module.foundation.category_applications_id
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
