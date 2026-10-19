resource "jamfplatform_pro_disk_encryption_configuration" "individual" {
  name                     = "${var.name_prefix}FileVault — Individual Key"
  key_type                 = "Individual"
  file_vault_enabled_users = "Current or Next User"
}

resource "jamfplatform_pro_policy" "enable_filevault" {
  general = {
    name          = "${var.name_prefix}Enable FileVault"
    enabled       = true
    frequency     = "Once per computer"
    trigger_login = true
    category_id   = var.category_id
  }

  scope = {
    targets = {
      computer_group_ids = [var.scope_jamf_pro_group_id]
    }
  }

  disk_encryption = {
    action                           = "apply"
    disk_encryption_configuration_id = tonumber(jamfplatform_pro_disk_encryption_configuration.individual.id)
    auth_restart                     = var.auth_restart
  }

  maintenance = {
    recon = true
  }
}
