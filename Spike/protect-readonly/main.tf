# READ-ONLY verification against a production Jamf Protect tenant.
# Data sources only: this configuration cannot create, change or remove
# anything, by construction.
terraform {
  required_providers {
    jamfprotect = {
      source  = "Jamf-Concepts/jamfprotect"
      version = "0.12.0"
    }
  }
}

provider "jamfprotect" {
}

data "jamfprotect_plans" "all" {}
data "jamfprotect_action_configurations" "all" {}
data "jamfprotect_exception_sets" "all" {}
data "jamfprotect_telemetries" "all" {}

output "plan_count" {
  value = length(data.jamfprotect_plans.all.plans)
}

output "plan_names" {
  value = [for p in data.jamfprotect_plans.all.plans : p.name]
}

output "action_configuration_count" {
  value = length(data.jamfprotect_action_configurations.all.action_configs)
}

output "exception_set_count" {
  value = length(data.jamfprotect_exception_sets.all.exception_sets)
}

output "telemetry_count" {
  value = length(data.jamfprotect_telemetries.all.telemetries)
}
