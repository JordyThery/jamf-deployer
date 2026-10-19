locals {
  profile_name = "${var.name_prefix}Passcode"
}

resource "jamfplatform_pro_mobile_device_configuration_profile" "passcode" {
  general = {
    name                = local.profile_name
    description         = var.managed_by_tag
    category_id         = var.category_id
    distribution_method = "Install Automatically"
    level               = "Device Level"
    payloads = templatefile("${path.module}/passcode.mobileconfig.tftpl", {
      name           = local.profile_name
      minimum_length = var.minimum_length
      max_inactivity = var.max_inactivity_minutes
    })
  }
  scope = {
    targets = {
      mobile_device_group_ids = [var.scope_jamf_pro_mobile_group_id]
    }
  }
}
