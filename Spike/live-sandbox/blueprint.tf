# Blueprint spike: software update settings delivered declaratively,
# targeted at the pilot device group's Platform UUID.

resource "jamfplatform_blueprints_blueprint" "software_updates" {
  name          = "${var.name_prefix}Software Updates"
  description   = "Managed by Jamf Deployer · software-updates@0.0.1"
  deployed      = true
  device_groups = [jamfplatform_device_group.pilot.id]

  component_blocks = [{
    name = "Software Update Settings"
    software_update_settings = {
      automatic_download                 = "AlwaysOn"
      automatic_install_os_updates       = "AlwaysOn"
      automatic_install_security_updates = "AlwaysOn"
      notifications_enabled              = true
      deferral_major_period_days         = 14
    }
  }]
}
