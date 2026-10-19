# Keyed by unprefixed name, so other blocks and presets can refer to
# "mobile-device-groups/Supervised iPads" whatever prefix the tenant uses.
output "device_group_ids" {
  value = { for key, group in jamfpro_smart_mobile_device_group_v1.mobile : key => group.id }
}

output "device_group_names" {
  value = { for key, group in jamfpro_smart_mobile_device_group_v1.mobile : key => group.name }
}

output "device_group_jamf_pro_ids" {
  value = { for key, group in jamfpro_smart_mobile_device_group_v1.mobile : key => group.id }
}
