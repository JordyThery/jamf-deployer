output "extension_attribute_ids" {
  value = {
    "Baseline Marker" = jamfplatform_pro_computer_extension_attribute.baseline_marker.id
    "Deployment Ring" = jamfplatform_pro_computer_extension_attribute.deployment_ring.id
  }
}

output "extension_attribute_names" {
  value = {
    "Baseline Marker" = jamfplatform_pro_computer_extension_attribute.baseline_marker.name
    "Deployment Ring" = jamfplatform_pro_computer_extension_attribute.deployment_ring.name
  }
}
