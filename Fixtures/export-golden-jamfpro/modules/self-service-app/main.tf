resource "jamfplatform_pro_self_service_macos_settings" "this" {
  install_automatically = var.install_automatically
  install_location      = "/Applications"
  default_landing_page  = var.default_landing_page
  notifications_enabled = var.notifications_enabled
  login_method          = var.login_method
  authentication_type   = var.authentication_type
}
