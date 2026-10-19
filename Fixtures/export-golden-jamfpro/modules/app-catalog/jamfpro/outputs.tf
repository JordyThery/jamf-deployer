output "app_installer_ids" {
  value = { for name, installer in jamfpro_app_installer.app : name => installer.id }
}
