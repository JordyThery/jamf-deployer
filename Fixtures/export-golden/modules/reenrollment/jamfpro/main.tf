resource "jamfpro_reenrollment" "this" {
  flush_mdm_queue                    = var.clear_management_history
  flush_policy_history               = var.clear_policy_logs
  flush_extension_attributes         = var.clear_extension_attributes
  flush_location_information         = var.clear_location_information
  flush_location_information_history = var.clear_location_information
  flush_software_update_plans        = true
}
