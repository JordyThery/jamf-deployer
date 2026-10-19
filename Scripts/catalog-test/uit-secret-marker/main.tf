resource "jamfplatform_pro_category" "marker" {
  name     = "${var.name_prefix}Secret ${substr(sha256(var.token), 0, 8)}"
  priority = 9
}
