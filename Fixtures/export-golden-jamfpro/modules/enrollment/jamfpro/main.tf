data "jamfpro_device_enrollments" "instance" {
  name = var.ade_instance_name
}

# The Jamf Pro API sets every PreStage field; those the Platform API leaves
# at Jamf Pro's defaults are spelled out here with the same values.
resource "jamfpro_computer_prestage_enrollment" "standard" {
  display_name                          = "${var.name_prefix}${var.prestage_display_name}"
  device_enrollment_program_instance_id = data.jamfpro_device_enrollments.instance.id

  mandatory                               = true
  mdm_removable                           = false
  auto_advance_setup                      = var.auto_advance_setup
  require_authentication                  = false
  authentication_prompt                   = ""
  install_profiles_during_setup           = false
  keep_existing_site_membership           = false
  keep_existing_location_information      = false
  enable_device_based_activation_lock     = false
  prevent_activation_lock                 = true
  default_prestage                        = var.default_prestage
  enable_recovery_lock                    = false
  recovery_lock_password_type             = "MANUAL"
  rotate_recovery_lock_password           = false
  prestage_minimum_os_target_version_type = "NO_ENFORCEMENT"
  prestage_installed_profile_ids          = []
  custom_package_ids                      = []
  custom_package_distribution_point_id    = "-1"
  site_id                                 = "-1"
  enrollment_site_id                      = "-1"
  department                              = ""
  language                                = ""
  region                                  = ""

  support_email_address = var.support_email
  support_phone_number  = var.support_phone

  location_information {
    username      = ""
    realname      = ""
    phone         = ""
    email         = ""
    room          = ""
    position      = ""
    department_id = "-1"
    building_id   = "-1"
  }

  purchasing_information {
    leased             = false
    purchased          = true
    apple_care_id      = ""
    po_number          = ""
    vendor             = ""
    purchase_price     = ""
    life_expectancy    = 0
    purchasing_account = ""
    purchasing_contact = ""
    lease_date         = "1970-01-01"
    po_date            = "1970-01-01"
    warranty_date      = "1970-01-01"
  }

  account_settings {
    payload_configured                           = false
    local_admin_account_enabled                  = false
    admin_username                               = ""
    admin_password                               = ""
    hidden_admin_account                         = false
    local_user_managed                           = false
    user_account_type                            = "ADMINISTRATOR"
    prefill_primary_account_info_feature_enabled = false
    prefill_type                                 = "CUSTOM"
    prefill_account_full_name                    = ""
    prefill_account_user_name                    = ""
    prevent_prefill_info_from_modification       = false
  }

  # Business-standard Setup Assistant: skip the consumer panes, keep the
  # essentials (language, Wi-Fi, FileVault pane stays interactive).
  skip_setup_items {
    apple_id                    = true
    biometric                   = false
    diagnostics                 = true
    icloud_diagnostics          = true
    icloud_storage              = true
    intelligence                = true
    location                    = false
    payment                     = true
    privacy                     = false
    registration                = true
    restore                     = true
    screen_time                 = true
    siri                        = true
    terms_of_address            = true
    tos                         = false
    wallpaper                   = true
    welcome                     = false
    accessibility               = false
    additional_privacy_settings = false
    appearance                  = false
    display_tone                = false
    enable_lockdown_mode        = false
    file_vault                  = false
    os_showcase                 = false
    software_update             = false
  }
}
