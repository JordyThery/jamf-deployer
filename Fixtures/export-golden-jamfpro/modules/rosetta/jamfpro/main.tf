resource "jamfpro_script" "install_rosetta" {
  name            = "${var.name_prefix}Install Rosetta 2"
  category_id     = var.category_id
  info            = var.managed_by_tag
  script_contents = file("${path.module}/../files/install-rosetta.sh")
  priority        = "AFTER"
}

resource "jamfpro_policy" "install_rosetta" {
  name            = "${var.name_prefix}Install Rosetta 2"
  enabled         = true
  frequency       = "Once per computer"
  trigger_checkin = true
  category_id     = tonumber(var.category_id)

  scope {
    all_computers      = false
    computer_group_ids = [tonumber(var.scope_jamf_pro_group_id)]
  }

  payloads {
    scripts {
      id       = jamfpro_script.install_rosetta.id
      priority = "After"
    }
  }
}
