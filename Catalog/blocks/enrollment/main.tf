data "jamfplatform_pro_automated_device_enrollment" "instance" {
  name = var.ade_instance_name
}

resource "jamfplatform_pro_computer_prestage_enrollment" "standard" {
  display_name                          = "${var.name_prefix}${var.prestage_display_name}"
  device_enrollment_program_instance_id = data.jamfplatform_pro_automated_device_enrollment.instance.id

  mandatory                           = true
  mdm_removable                       = false
  auto_advance_setup                  = var.auto_advance_setup
  require_authentication              = false
  install_profiles_during_setup       = false
  keep_existing_site_membership       = false
  keep_existing_location_information  = false
  enable_device_based_activation_lock = false
  prevent_activation_lock             = true
  default_prestage                    = var.default_prestage

  support_email_address = var.support_email == "" ? null : var.support_email
  support_phone_number  = var.support_phone == "" ? null : var.support_phone

  # Business-standard Setup Assistant: skip the consumer panes, keep the
  # essentials (language, Wi-Fi, FileVault pane stays interactive).
  skip_setup_items = {
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
  }
}
