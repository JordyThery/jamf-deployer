output "disk_encryption_configuration_id" {
  value = jamfpro_disk_encryption_configuration.individual.id
}

output "policy_id" {
  value = jamfpro_policy.enable_filevault.id
}
