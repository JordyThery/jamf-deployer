locals {
  smart_groups = {
    "All Managed Macs" = {
      criteria = "Operating System"
      operator = "like"
      value    = "macOS"
    }
    "Laptops" = {
      criteria = "Model"
      operator = "like"
      value    = "Book"
    }
    "Desktops" = {
      criteria = "Model"
      operator = "not like"
      value    = "Book"
    }
    "Apple Silicon Macs" = {
      criteria = "Apple Silicon"
      operator = "is"
      value    = "Yes"
    }
  }
}

# One device group yields both IDs other blocks scope with: the Platform UUID
# (Blueprints, compliance benchmarks) and the numeric Jamf Pro ID (policies,
# profiles, App Installers).
resource "jamfplatform_device_group" "pilot" {
  name        = "${var.name_prefix}Pilot"
  description = var.managed_by_tag
  device_type = "computer"
  group_type  = "static"
}

resource "jamfplatform_device_group" "smart" {
  for_each    = local.smart_groups
  name        = "${var.name_prefix}${each.key}"
  description = var.managed_by_tag
  device_type = "computer"
  group_type  = "smart"
  criteria = [{
    criteria = each.value.criteria
    operator = each.value.operator
    value    = each.value.value
  }]
}
