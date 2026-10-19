# Keyed by unprefixed name, so other blocks and presets can refer to
# "device-groups/Pilot" whatever prefix the tenant uses.
locals {
  groups = merge(
    { "Pilot" = jamfplatform_device_group.pilot },
    jamfplatform_device_group.smart,
  )
}

output "device_group_ids" {
  value = { for key, group in local.groups : key => group.id }
}

output "device_group_names" {
  value = { for key, group in local.groups : key => group.name }
}

output "device_group_jamf_pro_ids" {
  value = { for key, group in local.groups : key => group.jamf_pro_id }
}
