output "current_jamf_pro_id" {
  value = jamfpro_smart_computer_group_v2.current.id
}

output "below_minimum_jamf_pro_id" {
  value = jamfpro_smart_computer_group_v2.below_minimum.id
}
