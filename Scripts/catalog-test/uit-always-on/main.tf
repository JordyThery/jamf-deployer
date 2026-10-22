resource "jamfplatform_pro_category" "always_on" {
  name     = "${var.name_prefix}Always On"
  priority = 9
}
