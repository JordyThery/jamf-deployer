resource "jamfplatform_pro_script" "install_rosetta" {
  name            = "${var.name_prefix}Install Rosetta 2"
  category_id     = var.category_id
  info            = var.managed_by_tag
  script_contents = file("${path.module}/files/install-rosetta.sh")
  priority        = "AFTER"
}

resource "jamfplatform_pro_policy" "install_rosetta" {
  general = {
    name            = "${var.name_prefix}Install Rosetta 2"
    enabled         = true
    frequency       = "Once per computer"
    trigger_checkin = true
    category_id     = var.category_id
  }

  scope = {
    targets = {
      computer_group_ids = [var.scope_jamf_pro_group_id]
    }
  }

  scripts = {
    scripts = [{
      id       = jamfplatform_pro_script.install_rosetta.id
      priority = "After"
    }]
  }
}
