output "disk_encryption_configuration_id" {
  value = jamfplatform_pro_disk_encryption_configuration.individual.id
}

output "policy_id" {
  value = jamfplatform_pro_policy.enable_filevault.id
}
