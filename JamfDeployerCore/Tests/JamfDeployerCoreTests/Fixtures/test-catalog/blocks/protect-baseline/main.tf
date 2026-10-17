resource "jamfprotect_telemetry" "baseline" {
  name        = "${var.name_prefix}Telemetry Baseline"
  description = var.managed_by_tag

  log_file_path = []

  log_access_and_authentication = true
  log_apple_security            = true
  log_applications_and_processes = true
  log_hardware_and_software    = true
  log_persistence              = true
  log_system                   = true
  log_users_and_groups         = true
  log_network                  = var.collect_network_telemetry

  collect_diagnostic_and_crash_reports = true
  collect_performance_metrics          = false
  file_hashes                          = true
}

resource "jamfprotect_action_configuration" "baseline" {
  name        = "${var.name_prefix}Alerts to Jamf Protect Cloud"
  description = var.managed_by_tag

  alert_data_collection = {
    binary_included_data_attributes                 = ["Sha1", "Sha256", "Signing Information"]
    download_event_included_data_attributes        = ["File"]
    file_included_data_attributes                  = ["Sha1", "Sha256"]
    file_system_event_included_data_attributes     = ["File", "Process", "User"]
    gatekeeper_event_included_data_attributes      = ["Blocked Process", "Blocked Binary"]
    group_included_data_attributes                 = ["Name"]
    keylog_register_event_included_data_attributes = ["Source Process", "Destination Process"]
    process_event_included_data_attributes         = ["Process"]
    process_included_data_attributes               = ["Args", "Signing Information"]
    screenshot_event_included_data_attributes      = ["File"]
    synthetic_click_event_included_data_attributes = ["Process", "User"]
    user_included_data_attributes                  = ["Name"]
  }

  jamf_protect_cloud_endpoint = {
    collect_alerts = ["high", "medium", "low", "informational"]
    collect_logs   = ["telemetry"]
  }
}

resource "jamfprotect_exception_set" "baseline" {
  name        = "${var.name_prefix}Exceptions"
  description = var.managed_by_tag
}

resource "jamfprotect_plan" "baseline" {
  name        = "${var.name_prefix}Baseline Plan"
  description = var.managed_by_tag

  action_configuration = jamfprotect_action_configuration.baseline.id
  telemetry            = jamfprotect_telemetry.baseline.id
  exception_sets       = [jamfprotect_exception_set.baseline.id]

  endpoint_threat_prevention = var.threat_mode
  advanced_threat_controls   = var.threat_mode
  tamper_prevention          = "Block and report"

  reporting_interval = var.reporting_interval
  auto_update        = var.auto_update
  log_level          = "Error"

  report_architecture   = true
  report_hostname       = true
  report_serial_number  = true
  report_model_name     = true
}
