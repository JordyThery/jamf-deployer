locals {
  categories = ["Applications", "Enrollment", "Maintenance", "Security"]
}

resource "jamfpro_category" "category" {
  for_each = toset(local.categories)
  name     = "${var.name_prefix}${each.value}"
  priority = 9
}
