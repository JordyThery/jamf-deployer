output "app_installer_ids" {
  value = { for name, installer in jamfplatform_pro_app_installer.app : name => installer.id }
}
