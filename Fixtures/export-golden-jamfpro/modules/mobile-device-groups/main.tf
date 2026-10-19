locals {
  groups = {
    "Supervised iPads"   = "iPad"
    "Supervised iPhones" = "iPhone"
  }
}

resource "jamfplatform_device_group" "mobile" {
  for_each    = local.groups
  name        = "${var.name_prefix}${each.key}"
  description = var.managed_by_tag
  device_type = "mobile"
  group_type  = "smart"
  criteria = [
    {
      and_or   = "and"
      criteria = "Model"
      operator = "like"
      value    = each.value
      order    = 0
    },
    {
      and_or   = "and"
      criteria = "Supervised"
      operator = "is"
      value    = "Yes"
      order    = 1
    },
  ]
}
