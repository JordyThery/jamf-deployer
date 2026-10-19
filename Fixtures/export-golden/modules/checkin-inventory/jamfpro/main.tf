resource "jamfpro_client_checkin" "this" {
  check_in_frequency                  = var.check_in_frequency
  create_startup_script               = var.run_startup_policies
  startup_policies                    = var.run_startup_policies
  startup_log                         = var.run_startup_policies
  startup_ssh                         = false
  create_hooks                        = var.run_login_policies
  hook_policies                       = var.run_login_policies
  hook_log                            = var.run_login_policies
  allow_network_state_change_triggers = false
  enable_local_configuration_profiles = false
}

resource "jamfpro_computer_inventory_collection_settings" "this" {
  computer_inventory_collection_preferences {
    monitor_application_usage                          = var.collect_application_usage
    calculate_sizes                                    = var.include_home_directory_sizes
    include_software_updates                           = true
    include_software_id                                = true
    include_accounts                                   = true
    include_packages                                   = true
    include_printers                                   = true
    include_services                                   = true
    collect_unmanaged_certificates                     = true
    collect_synced_mobile_device_info                  = false
    update_ldap_info_on_computer_inventory_submissions = false
    allow_changing_user_and_location                   = true
    include_hidden_accounts                            = true
    monitor_beacons                                    = false
    use_unix_user_paths                                = true
  }
}
