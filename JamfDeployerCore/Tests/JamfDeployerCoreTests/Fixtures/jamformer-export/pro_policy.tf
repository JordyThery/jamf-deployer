resource "jamfplatform_pro_policy" "jd_install_rosetta_2" {
  provider = jamfplatform

  general = {
    category_id     = "73"
    enabled         = true
    frequency       = "Once per computer"
    name            = "JD - Install Rosetta 2"
    trigger_checkin = true
  }

  scope = {
    exclusions = {
      computer_group_ids = []
    }
    targets = {
      computer_group_ids = [
        "69", # TODO: unresolved reference
      ]
    }
  }

  scripts = {
    scripts = [{
      id       = jamfplatform_pro_script.jd_install_rosetta_2.id
      priority = "After"
    }]
  }
}
