# Keyed by unprefixed name, so other blocks and presets can refer to
# "device-groups/Pilot" whatever prefix the tenant uses. Jamf Pro API groups
# have one ID, used for every kind of scope.
locals {
  groups = merge(
    { "Pilot" = jamfpro_static_computer_group.pilot },
    jamfpro_smart_computer_group_v2.smart,
  )
}

output "device_group_ids" {
  value = { for key, group in local.groups : key => group.id }
}

output "device_group_names" {
  value = { for key, group in local.groups : key => group.name }
}

output "device_group_jamf_pro_ids" {
  value = { for key, group in local.groups : key => group.id }
}
