resource "jamfplatform_device_group" "current" {
  name        = "${var.name_prefix}Macs on current macOS"
  description = var.managed_by_tag
  device_type = "computer"
  group_type  = "smart"
  criteria = [{
    and_or   = "and"
    criteria = "Operating System Version"
    operator = "greater than or equal"
    order    = 0
    value    = var.current_major_version
  }]
}

resource "jamfplatform_device_group" "below_minimum" {
  name        = "${var.name_prefix}Macs below minimum macOS"
  description = var.managed_by_tag
  device_type = "computer"
  group_type  = "smart"
  criteria = [{
    and_or   = "and"
    criteria = "Operating System Version"
    operator = "less than"
    order    = 0
    value    = var.minimum_major_version
  }]
}
