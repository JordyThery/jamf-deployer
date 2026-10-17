# Rosetta spike: script + policy + scope, end to end.

resource "jamfplatform_pro_script" "rosetta" {
  name            = "${var.name_prefix}Install Rosetta 2"
  category_id     = jamfplatform_pro_category.spike.id
  info            = "Managed by Jamf Deployer · rosetta@0.0.1"
  script_contents = file("${path.module}/files/install-rosetta.sh")
  priority        = "AFTER"
}

resource "jamfplatform_pro_policy" "rosetta" {
  general = {
    name            = "${var.name_prefix}Install Rosetta 2"
    enabled         = true
    frequency       = "Once per computer"
    trigger_checkin = true
    category_id     = jamfplatform_pro_category.spike.id
  }

  scope = {
    targets = {
      # Numeric Jamf Pro ID from the same platform device group.
      computer_group_ids = [jamfplatform_device_group.apple_silicon.jamf_pro_id]
    }
  }

  scripts = {
    scripts = [{
      id       = jamfplatform_pro_script.rosetta.id
      priority = "After"
    }]
  }
}
