resource "jamfpro_script" "flush_dns" {
  name            = "${var.name_prefix}Flush DNS cache"
  category_id     = var.category_id
  info            = var.managed_by_tag
  script_contents = file("${path.module}/../files/flush-dns.sh")
  priority        = "AFTER"
}

resource "jamfpro_policy" "update_inventory" {
  name        = "${var.name_prefix}Update inventory"
  enabled     = true
  frequency   = "Ongoing"
  category_id = tonumber(var.category_id)

  scope {
    all_computers      = false
    computer_group_ids = [tonumber(var.scope_jamf_pro_group_id)]
  }

  self_service {
    use_for_self_service      = true
    self_service_display_name = "Update inventory"
    install_button_text       = "Update"
    reinstall_button_text     = "Update"
    self_service_description  = "Sends this Mac's current details to IT. Run it when support asks."
  }

  payloads {
    maintenance {
      recon = true
    }
  }
}

resource "jamfpro_policy" "flush_dns" {
  name        = "${var.name_prefix}Flush DNS cache"
  enabled     = true
  frequency   = "Ongoing"
  category_id = tonumber(var.category_id)

  scope {
    all_computers      = false
    computer_group_ids = [tonumber(var.scope_jamf_pro_group_id)]
  }

  self_service {
    use_for_self_service      = true
    self_service_display_name = "Flush DNS cache"
    install_button_text       = "Flush"
    reinstall_button_text     = "Flush"
    self_service_description  = "Clears cached website addresses. Helps when sites fail to load after a network change."
  }

  payloads {
    scripts {
      id       = jamfpro_script.flush_dns.id
      priority = "After"
    }
  }
}
