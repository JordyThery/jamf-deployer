# This tenant's baseline: one module call per building block, and how
# the blocks connect. Setting values live in tenant.auto.tfvars.

module "app_catalog" {
  source                  = "../../modules/app-catalog/jamfpro"
  name_prefix             = var.name_prefix
  managed_by_tag          = var.app_catalog.managed_by_tag
  scope_jamf_pro_group_id = module.device_groups.device_group_jamf_pro_ids["All Managed Macs"]
  category_id             = var.app_catalog.category_id
  apps_json               = var.app_catalog.apps_json
}

module "categories" {
  source         = "../../modules/categories/jamfpro"
  name_prefix    = var.name_prefix
  managed_by_tag = var.categories.managed_by_tag
}

module "checkin_inventory" {
  source                       = "../../modules/checkin-inventory/jamfpro"
  name_prefix                  = var.name_prefix
  managed_by_tag               = var.checkin_inventory.managed_by_tag
  check_in_frequency           = var.checkin_inventory.check_in_frequency
  run_startup_policies         = var.checkin_inventory.run_startup_policies
  run_login_policies           = var.checkin_inventory.run_login_policies
  collect_application_usage    = var.checkin_inventory.collect_application_usage
  include_home_directory_sizes = var.checkin_inventory.include_home_directory_sizes
}

module "device_groups" {
  source         = "../../modules/device-groups/jamfpro"
  name_prefix    = var.name_prefix
  managed_by_tag = var.device_groups.managed_by_tag
}

module "enrollment" {
  source                = "../../modules/enrollment/jamfpro"
  name_prefix           = var.name_prefix
  managed_by_tag        = var.enrollment.managed_by_tag
  ade_instance_name     = var.enrollment.ade_instance_name
  prestage_display_name = var.enrollment.prestage_display_name
  default_prestage      = var.enrollment.default_prestage
  auto_advance_setup    = var.enrollment.auto_advance_setup
  support_email         = var.enrollment.support_email
  support_phone         = var.enrollment.support_phone
}

module "extension_attributes" {
  source         = "../../modules/extension-attributes/jamfpro"
  name_prefix    = var.name_prefix
  managed_by_tag = var.extension_attributes.managed_by_tag
}

module "filevault" {
  source                  = "../../modules/filevault/jamfpro"
  name_prefix             = var.name_prefix
  managed_by_tag          = var.filevault.managed_by_tag
  scope_jamf_pro_group_id = module.device_groups.device_group_jamf_pro_ids["Pilot"]
  category_id             = module.categories.category_ids["Security"]
  auth_restart            = var.filevault.auth_restart
}

module "local_admin_password" {
  source                          = "../../modules/local-admin-password/jamfpro"
  name_prefix                     = var.name_prefix
  managed_by_tag                  = var.local_admin_password.managed_by_tag
  rotation_interval               = var.local_admin_password.rotation_interval
  rotation_after_viewing_interval = var.local_admin_password.rotation_after_viewing_interval
  include_prestage_accounts       = var.local_admin_password.include_prestage_accounts
}

module "macos_version_groups" {
  source                = "../../modules/macos-version-groups/jamfpro"
  name_prefix           = var.name_prefix
  managed_by_tag        = var.macos_version_groups.managed_by_tag
  current_major_version = var.macos_version_groups.current_major_version
  minimum_major_version = var.macos_version_groups.minimum_major_version
}

module "mobile_device_groups" {
  source         = "../../modules/mobile-device-groups/jamfpro"
  name_prefix    = var.name_prefix
  managed_by_tag = var.mobile_device_groups.managed_by_tag
}

module "mobile_enrollment" {
  source                = "../../modules/mobile-enrollment/jamfpro"
  name_prefix           = var.name_prefix
  managed_by_tag        = var.mobile_enrollment.managed_by_tag
  ade_instance_name     = var.mobile_enrollment.ade_instance_name
  prestage_display_name = var.mobile_enrollment.prestage_display_name
  default_prestage      = var.mobile_enrollment.default_prestage
  support_email         = var.mobile_enrollment.support_email
  support_phone         = var.mobile_enrollment.support_phone
}

module "mobile_passcode" {
  source                         = "../../modules/mobile-passcode/jamfpro"
  name_prefix                    = var.name_prefix
  managed_by_tag                 = var.mobile_passcode.managed_by_tag
  scope_jamf_pro_mobile_group_id = module.mobile_device_groups.device_group_jamf_pro_ids["Supervised iPads"]
  category_id                    = module.categories.category_ids["Security"]
  minimum_length                 = var.mobile_passcode.minimum_length
  max_inactivity_minutes         = var.mobile_passcode.max_inactivity_minutes
}

module "reenrollment" {
  source                     = "../../modules/reenrollment/jamfpro"
  name_prefix                = var.name_prefix
  managed_by_tag             = var.reenrollment.managed_by_tag
  clear_management_history   = var.reenrollment.clear_management_history
  clear_policy_logs          = var.reenrollment.clear_policy_logs
  clear_extension_attributes = var.reenrollment.clear_extension_attributes
  clear_location_information = var.reenrollment.clear_location_information
}

module "rosetta" {
  source                  = "../../modules/rosetta/jamfpro"
  name_prefix             = var.name_prefix
  managed_by_tag          = var.rosetta.managed_by_tag
  scope_jamf_pro_group_id = module.device_groups.device_group_jamf_pro_ids["Apple Silicon Macs"]
  category_id             = module.categories.category_ids["Applications"]
}

module "self_service_app" {
  source                = "../../modules/self-service-app/jamfpro"
  name_prefix           = var.name_prefix
  managed_by_tag        = var.self_service_app.managed_by_tag
  install_automatically = var.self_service_app.install_automatically
  default_landing_page  = var.self_service_app.default_landing_page
  notifications_enabled = var.self_service_app.notifications_enabled
  login_method          = var.self_service_app.login_method
  authentication_type   = var.self_service_app.authentication_type
}

module "self_service_maintenance" {
  source                  = "../../modules/self-service-maintenance/jamfpro"
  name_prefix             = var.name_prefix
  managed_by_tag          = var.self_service_maintenance.managed_by_tag
  scope_jamf_pro_group_id = module.device_groups.device_group_jamf_pro_ids["All Managed Macs"]
  category_id             = module.categories.category_ids["Maintenance"]
}
