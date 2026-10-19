# Inputs for this tenant. Values live in tenant.auto.tfvars.

variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "app_catalog" {
  description = "Settings for the app_catalog block."
  type = object({
    managed_by_tag = string
    category_id    = string
    apps_json      = string
  })
}

variable "categories" {
  description = "Settings for the categories block."
  type = object({
    managed_by_tag = string
  })
}

variable "checkin_inventory" {
  description = "Settings for the checkin_inventory block."
  type = object({
    managed_by_tag               = string
    check_in_frequency           = string
    run_startup_policies         = bool
    run_login_policies           = bool
    collect_application_usage    = bool
    include_home_directory_sizes = bool
  })
}

variable "compliance_cis_l1" {
  description = "Settings for the compliance_cis_l1 block."
  type = object({
    managed_by_tag      = string
    enforcement_mode    = string
    macos_major_version = number
  })
}

variable "device_groups" {
  description = "Settings for the device_groups block."
  type = object({
    managed_by_tag = string
  })
}

variable "enrollment" {
  description = "Settings for the enrollment block."
  type = object({
    managed_by_tag        = string
    ade_instance_name     = string
    prestage_display_name = string
    default_prestage      = bool
    auto_advance_setup    = bool
    support_email         = string
    support_phone         = string
  })
}

variable "extension_attributes" {
  description = "Settings for the extension_attributes block."
  type = object({
    managed_by_tag = string
  })
}

variable "filevault" {
  description = "Settings for the filevault block."
  type = object({
    managed_by_tag = string
    auth_restart   = bool
  })
}

variable "local_admin_password" {
  description = "Settings for the local_admin_password block."
  type = object({
    managed_by_tag                  = string
    rotation_interval               = string
    rotation_after_viewing_interval = string
    include_prestage_accounts       = bool
  })
}

variable "macos_version_groups" {
  description = "Settings for the macos_version_groups block."
  type = object({
    managed_by_tag        = string
    current_major_version = string
    minimum_major_version = string
  })
}

variable "mobile_device_groups" {
  description = "Settings for the mobile_device_groups block."
  type = object({
    managed_by_tag = string
  })
}

variable "mobile_enrollment" {
  description = "Settings for the mobile_enrollment block."
  type = object({
    managed_by_tag        = string
    ade_instance_name     = string
    prestage_display_name = string
    default_prestage      = bool
    support_email         = string
    support_phone         = string
  })
}

variable "mobile_passcode" {
  description = "Settings for the mobile_passcode block."
  type = object({
    managed_by_tag         = string
    minimum_length         = number
    max_inactivity_minutes = number
  })
}

variable "reenrollment" {
  description = "Settings for the reenrollment block."
  type = object({
    managed_by_tag             = string
    clear_management_history   = string
    clear_policy_logs          = bool
    clear_extension_attributes = bool
    clear_location_information = bool
  })
}

variable "rosetta" {
  description = "Settings for the rosetta block."
  type = object({
    managed_by_tag = string
  })
}

variable "self_service_app" {
  description = "Settings for the self_service_app block."
  type = object({
    managed_by_tag        = string
    install_automatically = bool
    default_landing_page  = string
    notifications_enabled = bool
    login_method          = string
    authentication_type   = string
  })
}

variable "self_service_maintenance" {
  description = "Settings for the self_service_maintenance block."
  type = object({
    managed_by_tag = string
  })
}

variable "software_updates" {
  description = "Settings for the software_updates block."
  type = object({
    managed_by_tag              = string
    deferral_major_days         = number
    deferral_minor_days         = number
    allow_standard_user_updates = bool
    notifications_enabled       = bool
  })
}
