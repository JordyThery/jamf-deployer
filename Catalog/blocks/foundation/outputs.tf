output "category_security_id" {
  value = jamfplatform_pro_category.category["security"].id
}

output "category_applications_id" {
  value = jamfplatform_pro_category.category["applications"].id
}

output "category_maintenance_id" {
  value = jamfplatform_pro_category.category["maintenance"].id
}

output "category_enrollment_id" {
  value = jamfplatform_pro_category.category["enrollment"].id
}

output "pilot_platform_uuid" {
  value = jamfplatform_device_group.pilot.id
}

output "pilot_jamf_pro_id" {
  value = jamfplatform_device_group.pilot.jamf_pro_id
}

output "all_macs_platform_uuid" {
  value = jamfplatform_device_group.all_macs.id
}

output "all_macs_jamf_pro_id" {
  value = jamfplatform_device_group.all_macs.jamf_pro_id
}

output "laptops_platform_uuid" {
  value = jamfplatform_device_group.laptops.id
}

output "laptops_jamf_pro_id" {
  value = jamfplatform_device_group.laptops.jamf_pro_id
}

output "desktops_platform_uuid" {
  value = jamfplatform_device_group.desktops.id
}

output "desktops_jamf_pro_id" {
  value = jamfplatform_device_group.desktops.jamf_pro_id
}

output "apple_silicon_platform_uuid" {
  value = jamfplatform_device_group.apple_silicon.id
}

output "apple_silicon_jamf_pro_id" {
  value = jamfplatform_device_group.apple_silicon.jamf_pro_id
}
