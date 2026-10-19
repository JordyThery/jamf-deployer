output "current_jamf_pro_id" {
  value = jamfplatform_device_group.current.jamf_pro_id
}

output "below_minimum_jamf_pro_id" {
  value = jamfplatform_device_group.below_minimum.jamf_pro_id
}
