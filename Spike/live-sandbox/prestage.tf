# Prestage spike, gated on an existing ADE instance in the sandbox.
# Also verifies token_expiration_date for the fleet dashboard.

data "jamfplatform_pro_automated_device_enrollment" "ade" {
  count = var.ade_instance_name == "" ? 0 : 1
  name  = var.ade_instance_name
}

resource "jamfplatform_pro_computer_prestage_enrollment" "spike" {
  count = var.ade_instance_name == "" ? 0 : 1

  display_name                          = "${var.name_prefix}Prestage"
  device_enrollment_program_instance_id = data.jamfplatform_pro_automated_device_enrollment.ade[0].id

  mandatory                           = true
  mdm_removable                       = false
  auto_advance_setup                  = false
  require_authentication              = false
  install_profiles_during_setup       = false
  keep_existing_site_membership       = false
  keep_existing_location_information  = false
  enable_device_based_activation_lock = false
  prevent_activation_lock             = true
}

output "ade_token_expiration" {
  value = var.ade_instance_name == "" ? null : data.jamfplatform_pro_automated_device_enrollment.ade[0].token_expiration_date
}
