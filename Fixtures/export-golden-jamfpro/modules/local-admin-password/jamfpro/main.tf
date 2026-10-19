locals {
  rotation_seconds = {
    "7 days"   = 604800
    "30 days"  = 2592000
    "60 days"  = 5184000
    "180 days" = 15552000
  }
  after_viewing_seconds = {
    "1 hour"   = 3600
    "3 hours"  = 10800
    "12 hours" = 43200
    "1 day"    = 86400
    "3 days"   = 259200
    "7 days"   = 604800
  }
}

resource "jamfpro_local_admin_password_settings" "this" {
  auto_deploy_enabled                 = var.include_prestage_accounts
  auto_rotate_enabled                 = var.rotation_interval != "Never"
  auto_rotate_expiration_time_seconds = lookup(local.rotation_seconds, var.rotation_interval, 7776000)
  password_rotation_time_seconds      = local.after_viewing_seconds[var.rotation_after_viewing_interval]
}
