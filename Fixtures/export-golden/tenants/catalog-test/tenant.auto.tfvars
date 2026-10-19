# The only file that differs in substance between tenants. No secrets:
# credentials arrive as environment variables at run time.

name_prefix = "UIC - "

app_catalog = {
  managed_by_tag = "Managed by Jamf Deployer · app-catalog@1.0.0"
  category_id    = "-1"
  apps_json      = "[{\"deploymentType\":\"SELF_SERVICE\",\"publisher\":\"Google\",\"titleName\":\"Google Chrome\",\"updateBehavior\":\"AUTOMATIC\"}]"
}

categories = {
  managed_by_tag = "Managed by Jamf Deployer · categories@1.0.0"
}

checkin_inventory = {
  managed_by_tag               = "Managed by Jamf Deployer · checkin-inventory@1.0.0"
  check_in_frequency           = "15"
  run_startup_policies         = true
  run_login_policies           = true
  collect_application_usage    = true
  include_home_directory_sizes = false
}

compliance_cis_l1 = {
  managed_by_tag      = "Managed by Jamf Deployer · compliance-cis-l1@1.0.0"
  enforcement_mode    = "MONITOR"
  macos_major_version = 26
}

device_groups = {
  managed_by_tag = "Managed by Jamf Deployer · device-groups@1.0.0"
}

enrollment = {
  managed_by_tag        = "Managed by Jamf Deployer · enrollment@1.0.0"
  ade_instance_name     = "Apple Business Manager"
  prestage_display_name = "Standard Enrollment"
  default_prestage      = false
  auto_advance_setup    = false
  support_email         = ""
  support_phone         = ""
}

extension_attributes = {
  managed_by_tag = "Managed by Jamf Deployer · extension-attributes@1.0.0"
}

filevault = {
  managed_by_tag = "Managed by Jamf Deployer · filevault@1.0.0"
  auth_restart   = false
}

local_admin_password = {
  managed_by_tag                  = "Managed by Jamf Deployer · local-admin-password@1.0.0"
  rotation_interval               = "30 days"
  rotation_after_viewing_interval = "1 hour"
  include_prestage_accounts       = true
}

macos_version_groups = {
  managed_by_tag        = "Managed by Jamf Deployer · macos-version-groups@1.0.0"
  current_major_version = "26"
  minimum_major_version = "15"
}

mobile_device_groups = {
  managed_by_tag = "Managed by Jamf Deployer · mobile-device-groups@1.0.0"
}

mobile_enrollment = {
  managed_by_tag        = "Managed by Jamf Deployer · mobile-enrollment@1.0.0"
  ade_instance_name     = "Apple Business Manager"
  prestage_display_name = "iPad and iPhone Enrollment"
  default_prestage      = false
  support_email         = ""
  support_phone         = ""
}

mobile_passcode = {
  managed_by_tag         = "Managed by Jamf Deployer · mobile-passcode@1.0.0"
  minimum_length         = 6
  max_inactivity_minutes = 5
}

reenrollment = {
  managed_by_tag             = "Managed by Jamf Deployer · reenrollment@1.0.0"
  clear_management_history   = "DELETE_EVERYTHING_EXCEPT_ACKNOWLEDGED"
  clear_policy_logs          = true
  clear_extension_attributes = true
  clear_location_information = true
}

rosetta = {
  managed_by_tag = "Managed by Jamf Deployer · rosetta@1.0.0"
}

self_service_app = {
  managed_by_tag        = "Managed by Jamf Deployer · self-service-app@1.0.0"
  install_automatically = true
  default_landing_page  = "HOME"
  notifications_enabled = true
  login_method          = "NotRequired"
  authentication_type   = "Basic"
}

self_service_maintenance = {
  managed_by_tag = "Managed by Jamf Deployer · self-service-maintenance@1.0.0"
}

software_updates = {
  managed_by_tag              = "Managed by Jamf Deployer · software-updates@1.0.0"
  deferral_major_days         = 14
  deferral_minor_days         = 7
  allow_standard_user_updates = true
  notifications_enabled       = true
}
