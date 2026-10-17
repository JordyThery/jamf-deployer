locals {
  categories = {
    security     = "Security"
    applications = "Applications"
    maintenance  = "Maintenance"
    enrollment   = "Enrollment"
  }
}

resource "jamfplatform_pro_category" "category" {
  for_each = local.categories
  name     = "${var.name_prefix}${each.value}"
  priority = 9
}

# One device group yields both IDs other blocks scope with: the Platform UUID
# (Blueprints, compliance benchmarks) and the numeric Jamf Pro ID (policies,
# profiles).
resource "jamfplatform_device_group" "pilot" {
  name        = "${var.name_prefix}Pilot"
  description = var.managed_by_tag
  device_type = "computer"
  group_type  = "static"
}

resource "jamfplatform_device_group" "all_macs" {
  name        = "${var.name_prefix}All Managed Macs"
  description = var.managed_by_tag
  device_type = "computer"
  group_type  = "smart"
  criteria = [{
    criteria = "Operating System"
    operator = "like"
    value    = "macOS"
  }]
}

resource "jamfplatform_device_group" "laptops" {
  name        = "${var.name_prefix}Laptops"
  description = var.managed_by_tag
  device_type = "computer"
  group_type  = "smart"
  criteria = [{
    criteria = "Model"
    operator = "like"
    value    = "Book"
  }]
}

resource "jamfplatform_device_group" "desktops" {
  name        = "${var.name_prefix}Desktops"
  description = var.managed_by_tag
  device_type = "computer"
  group_type  = "smart"
  criteria = [{
    criteria = "Model"
    operator = "not like"
    value    = "Book"
  }]
}

resource "jamfplatform_device_group" "apple_silicon" {
  name        = "${var.name_prefix}Apple Silicon Macs"
  description = var.managed_by_tag
  device_type = "computer"
  group_type  = "smart"
  criteria = [{
    criteria = "Apple Silicon"
    operator = "is"
    value    = "Yes"
  }]
}

resource "jamfplatform_pro_computer_extension_attribute" "baseline_marker" {
  name              = "${var.name_prefix}Baseline Marker"
  description       = var.managed_by_tag
  data_type         = "STRING"
  input_type        = "TEXT"
  inventory_display = "EXTENSION_ATTRIBUTES"
}

resource "jamfplatform_pro_computer_extension_attribute" "deployment_ring" {
  name               = "${var.name_prefix}Deployment Ring"
  description        = var.managed_by_tag
  data_type          = "STRING"
  input_type         = "POPUP"
  inventory_display  = "EXTENSION_ATTRIBUTES"
  popup_menu_choices = ["Pilot", "Production"]
}
