output "extension_attribute_ids" {
  value = {
    "Baseline Marker" = jamfpro_computer_extension_attribute.baseline_marker.id
    "Deployment Ring" = jamfpro_computer_extension_attribute.deployment_ring.id
  }
}

output "extension_attribute_names" {
  value = {
    "Baseline Marker" = jamfpro_computer_extension_attribute.baseline_marker.name
    "Deployment Ring" = jamfpro_computer_extension_attribute.deployment_ring.name
  }
}
