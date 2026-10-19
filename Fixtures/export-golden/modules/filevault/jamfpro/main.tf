resource "jamfpro_disk_encryption_configuration" "individual" {
  name                     = "${var.name_prefix}FileVault — Individual Key"
  key_type                 = "Individual"
  file_vault_enabled_users = "Current or Next User"

  # Jamf Pro reports an empty recovery key section for individual keys,
  # and the plugin cannot create one with an empty section.
  lifecycle {
    ignore_changes = [institutional_recovery_key]
  }
}

resource "jamfpro_policy" "enable_filevault" {
  name          = "${var.name_prefix}Enable FileVault"
  enabled       = true
  frequency     = "Once per computer"
  trigger_login = true
  category_id   = tonumber(var.category_id)

  scope {
    all_computers      = false
    computer_group_ids = [tonumber(var.scope_jamf_pro_group_id)]
  }

  payloads {
    disk_encryption {
      action                           = "apply"
      disk_encryption_configuration_id = tonumber(jamfpro_disk_encryption_configuration.individual.id)
      auth_restart                     = var.auth_restart
    }

    maintenance {
      recon = true
    }
  }

  # The plugin fills in a remediation key type that Jamf Pro does not keep
  # for the "apply" action, which would show as a change on every preview.
  lifecycle {
    ignore_changes = [payloads[0].disk_encryption[0].remediate_key_type]
  }
}
