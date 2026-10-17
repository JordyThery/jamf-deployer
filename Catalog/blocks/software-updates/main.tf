resource "jamfplatform_blueprints_blueprint" "software_updates" {
  name          = "${var.name_prefix}Software Updates"
  description   = var.managed_by_tag
  deployed      = true
  device_groups = [var.scope_platform_group_uuid]

  component_blocks = [{
    name = "Software Update Settings"
    software_update_settings = {
      automatic_download                 = "AlwaysOn"
      automatic_install_os_updates       = "AlwaysOn"
      automatic_install_security_updates = "AlwaysOn"
      allow_standard_user_os_updates     = var.allow_standard_user_updates
      notifications_enabled              = var.notifications_enabled
      deferral_major_period_days         = var.deferral_major_days
      deferral_minor_period_days         = var.deferral_minor_days
      rapid_security_response_enabled    = true
    }
  }]
}
