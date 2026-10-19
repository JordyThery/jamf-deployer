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

resource "jamfpro_static_computer_group" "pilot" {
  name = "${var.name_prefix}Pilot"
}

resource "jamfpro_smart_computer_group_v2" "smart" {
  for_each    = local.smart_groups
  name        = "${var.name_prefix}${each.key}"
  description = var.managed_by_tag

  criteria {
    name        = each.value.criteria
    search_type = each.value.operator
    value       = each.value.value
    and_or      = "and"
    priority    = 0
  }
}
