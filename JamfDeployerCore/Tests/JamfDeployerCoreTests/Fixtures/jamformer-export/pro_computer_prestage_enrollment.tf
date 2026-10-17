resource "jamfplatform_pro_computer_prestage_enrollment" "default_prestage" {
  provider = jamfplatform

  auto_advance_setup                    = false
  default_prestage                      = true
  device_enrollment_program_instance_id = jamfplatform_pro_automated_device_enrollment.apple_business_manager.id
  display_name                          = "Default PreStage"
  enable_recovery_lock                  = true
  recovery_lock_password_type           = "MANUAL"
  enable_device_based_activation_lock   = false
  install_profiles_during_setup         = false
  keep_existing_location_information    = false
  keep_existing_site_membership         = false
  mandatory                             = true
  mdm_removable                         = false
  prevent_activation_lock               = true
  require_authentication                = false
}
