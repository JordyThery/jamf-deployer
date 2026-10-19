resource "jamfplatform_pro_computer_extension_attribute" "baseline_marker" {
  name              = "${var.name_prefix}Baseline Marker"
  description       = var.managed_by_tag
  data_type         = "STRING"
  input_type        = "TEXT"
  inventory_display = "EXTENSION_ATTRIBUTES"
}

resource "jamfplatform_pro_computer_extension_attribute" "deployment_ring" {
  name               = "${var.name_prefix}Deployment Ring"
  description        = var.managed_by_tag
  data_type          = "STRING"
  input_type         = "POPUP"
  inventory_display  = "EXTENSION_ATTRIBUTES"
  popup_menu_choices = ["Pilot", "Production"]
}
