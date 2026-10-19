resource "jamfplatform_pro_computer_check_in_settings" "this" {
  check_in_frequency                  = var.check_in_frequency
  create_startup_script               = var.run_startup_policies
  startup_policies                    = var.run_startup_policies
  startup_log                         = var.run_startup_policies
  startup_ssh                         = false
  create_login_hook                   = var.run_login_policies
  login_hook_policies                 = var.run_login_policies
  login_hook_log                      = var.run_login_policies
  allow_network_state_change_triggers = false
}

resource "jamfplatform_pro_computer_inventory_collection_settings" "this" {
  collect_application_usage_information            = var.collect_application_usage
  include_home_directory_sizes                     = var.include_home_directory_sizes
  collect_available_software_updates               = true
  collect_local_user_accounts                      = true
  collect_package_receipts                         = true
  collect_printers                                 = true
  collect_active_services                          = true
  collect_unmanaged_certificates                   = true
  collect_synced_mobile_device_backup_dates        = false
  collect_user_and_location_from_directory_service = false
  allow_jamf_binary_user_and_location_changes      = true
  include_hidden_accounts                          = true
  monitor_beacon_regions                           = false
  use_unix_user_paths                              = true
  application_search_paths                         = []
}
