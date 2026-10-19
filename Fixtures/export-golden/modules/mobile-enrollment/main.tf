data "jamfplatform_pro_automated_device_enrollment" "instance" {
  name = var.ade_instance_name
}

resource "jamfplatform_pro_mobile_device_prestage_enrollment" "standard" {
  display_name                          = "${var.name_prefix}${var.prestage_display_name}"
  device_enrollment_program_instance_id = data.jamfplatform_pro_automated_device_enrollment.instance.id
  timezone                              = "UTC"

  supervised                          = true
  mandatory                           = true
  mdm_removable                       = false
  allow_pairing                       = false
  prevent_activation_lock             = true
  enable_device_based_activation_lock = false
  install_apps_during_enrollment      = true
  default_prestage                    = var.default_prestage

  support_email_address = var.support_email == "" ? null : var.support_email
  support_phone_number  = var.support_phone == "" ? null : var.support_phone

  # Business Setup Assistant: skip consumer panes, keep language, Wi-Fi,
  # passcode and terms interactive.
  skip_setup_items = {
    apple_id              = true
    android               = true
    appearance            = true
    diagnostics           = true
    imessage_and_facetime = true
    intelligence          = true
    payment               = true
    restore               = true
    screen_time           = true
    siri                  = true
    transfer_data         = true
    watch_migration       = true
  }
}
