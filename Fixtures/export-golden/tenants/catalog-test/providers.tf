# Credentials come from JAMFPLATFORM_* environment variables at run
# time. Nothing secret is ever written to this folder.
provider "jamfplatform" {
  impact_alerts = true
}
