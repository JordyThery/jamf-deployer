resource "jamfpro_computer_extension_attribute" "baseline_marker" {
  name                   = "${var.name_prefix}Baseline Marker"
  description            = var.managed_by_tag
  enabled                = true
  data_type              = "STRING"
  input_type             = "TEXT"
  inventory_display_type = "EXTENSION_ATTRIBUTES"
}

resource "jamfpro_computer_extension_attribute" "deployment_ring" {
  name                   = "${var.name_prefix}Deployment Ring"
  description            = var.managed_by_tag
  enabled                = true
  data_type              = "STRING"
  input_type             = "POPUP"
  inventory_display_type = "EXTENSION_ATTRIBUTES"
  popup_menu_choices     = ["Pilot", "Production"]
}
