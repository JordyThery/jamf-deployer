# Foundation spike: category, device groups (static pilot + smart Apple silicon),
# extension attribute. Verifies the dual-ID convention: one jamfplatform_device_group
# yields a Platform UUID (id) for Blueprints/benchmarks and a numeric jamf_pro_id
# for policy/profile scoping.

resource "jamfplatform_pro_category" "spike" {
  name     = "${var.name_prefix}Deployer"
  priority = 9
}

resource "jamfplatform_device_group" "pilot" {
  name        = "${var.name_prefix}Pilot"
  description = "Managed by Jamf Deployer · foundation@0.0.1"
  device_type = "computer"
  group_type  = "static"
}

resource "jamfplatform_device_group" "apple_silicon" {
  name        = "${var.name_prefix}Apple Silicon Macs"
  description = "Managed by Jamf Deployer · foundation@0.0.1"
  device_type = "computer"
  group_type  = "smart"

  criteria = [{
    criteria = "Apple Silicon"
    operator = "is"
    value    = "Yes"
  }]
}

resource "jamfplatform_pro_computer_extension_attribute" "marker" {
  name              = "${var.name_prefix}Deployer Marker"
  description       = "Managed by Jamf Deployer · foundation@0.0.1"
  data_type         = "STRING"
  input_type        = "TEXT"
  inventory_display = "EXTENSION_ATTRIBUTES"
}

output "pilot_platform_uuid" {
  value = jamfplatform_device_group.pilot.id
}

output "pilot_jamf_pro_id" {
  value = jamfplatform_device_group.pilot.jamf_pro_id
}

output "apple_silicon_platform_uuid" {
  value = jamfplatform_device_group.apple_silicon.id
}

output "apple_silicon_jamf_pro_id" {
  value = jamfplatform_device_group.apple_silicon.jamf_pro_id
}
