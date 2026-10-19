resource "jamfplatform_pro_re_enrollment_settings" "this" {
  clear_management_history           = var.clear_management_history
  clear_policy_logs                  = var.clear_policy_logs
  clear_extension_attributes         = var.clear_extension_attributes
  clear_location_information         = var.clear_location_information
  clear_location_information_history = var.clear_location_information
  clear_software_update_plans        = true
}
