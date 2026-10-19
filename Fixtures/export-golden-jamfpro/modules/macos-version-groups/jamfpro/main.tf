resource "jamfpro_smart_computer_group_v2" "current" {
  name        = "${var.name_prefix}Macs on current macOS"
  description = var.managed_by_tag

  criteria {
    name        = "Operating System Version"
    search_type = "greater than or equal"
    value       = var.current_major_version
    and_or      = "and"
    priority    = 0
  }
}

resource "jamfpro_smart_computer_group_v2" "below_minimum" {
  name        = "${var.name_prefix}Macs below minimum macOS"
  description = var.managed_by_tag

  criteria {
    name        = "Operating System Version"
    search_type = "less than"
    value       = var.minimum_major_version
    and_or      = "and"
    priority    = 0
  }
}
