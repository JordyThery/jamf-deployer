output "uem_connect_id" {
  value = one(concat(
    jamfplatform_security_cloud_uem_connect.jamf_pro[*].id,
    data.jamfplatform_security_cloud_uem_connect.existing[*].id,
  ))
}

output "activation_profile_id" {
  value = jamfplatform_security_cloud_activation_profile.mac.id
}

output "enrollment_url" {
  description = "Enrollment link devices use; also embedded in the Jamf Trust configuration profile."
  value       = "https://e.wandera.com/${jamfplatform_security_cloud_activation_profile.mac.id}"
}
