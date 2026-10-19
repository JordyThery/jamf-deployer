locals {
  profile_name = "${var.name_prefix}Passcode"
}

resource "jamfpro_mobile_device_configuration_profile_plist" "passcode" {
  name               = local.profile_name
  description        = var.managed_by_tag
  category_id        = tonumber(var.category_id)
  deployment_method  = "Install Automatically"
  level              = "Device Level"
  redeploy_on_update = "Newly Assigned"
  payloads = templatefile("${path.module}/passcode.mobileconfig.tftpl", {
    name           = local.profile_name
    minimum_length = var.minimum_length
    max_inactivity = var.max_inactivity_minutes
  })

  scope {
    all_mobile_devices      = false
    mobile_device_group_ids = [tonumber(var.scope_jamf_pro_mobile_group_id)]
  }
}
