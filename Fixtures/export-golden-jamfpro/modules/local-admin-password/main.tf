resource "jamfplatform_pro_local_admin_password_settings" "this" {
  rotation_interval                  = var.rotation_interval
  rotation_after_viewing_interval    = var.rotation_after_viewing_interval
  laps_for_prestage_accounts_enabled = var.include_prestage_accounts
}
