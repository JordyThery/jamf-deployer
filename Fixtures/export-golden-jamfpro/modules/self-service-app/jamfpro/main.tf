# The Jamf Pro API sets every Self Service option at once; those the block
# has no setting for get Jamf Pro's defaults (no remembered logins, no
# FIDO2, Bookmarks, All Items as the home category).
resource "jamfpro_self_service_settings" "this" {
  install_automatically    = var.install_automatically
  install_location         = "/Applications"
  default_landing_page     = var.default_landing_page
  notifications_enabled    = var.notifications_enabled
  user_login_level         = var.login_method
  allow_remember_me        = false
  use_fido2                = false
  auth_type                = var.authentication_type
  alert_user_approved_mdm  = true
  default_home_category_id = -1
  bookmarks_name           = "Bookmarks"
}
