locals {
  groups = {
    "Supervised iPads"   = "iPad"
    "Supervised iPhones" = "iPhone"
  }
}

resource "jamfpro_smart_mobile_device_group_v1" "mobile" {
  for_each    = local.groups
  name        = "${var.name_prefix}${each.key}"
  description = var.managed_by_tag

  criteria {
    name        = "Model"
    search_type = "like"
    value       = each.value
    and_or      = "and"
    priority    = 0
  }

  criteria {
    name        = "Supervised"
    search_type = "is"
    value       = "Yes"
    and_or      = "and"
    priority    = 1
  }
}
