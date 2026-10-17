terraform {
  required_providers {
    jamfplatform = {
      source  = "jamf/jamfplatform"
      version = "1.5.0"
    }
  }
}

# base_url, client_id, client_secret and environment_id all come from
# JAMFPLATFORM_* environment variables set by run.sh — never from files.
provider "jamfplatform" {
  impact_alerts = true
}
