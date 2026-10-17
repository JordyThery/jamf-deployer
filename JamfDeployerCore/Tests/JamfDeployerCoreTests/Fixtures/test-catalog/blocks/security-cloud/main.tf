# UEM Connect binds Security Cloud to the Jamf Pro tenant this provider is
# scoped to — no manual API client needed on the platform.
data "jamfplatform_pro_tenant_id" "current" {}

resource "jamfplatform_security_cloud_uem_connect" "jamf_pro" {
  uem_vendor = "JAMF_PRO"

  platform_tenant = {
    tenant_id = data.jamfplatform_pro_tenant_id.current.tenant_id
  }

  enabled                           = true
  device_risk_uem_signaling_enabled = var.device_risk_signaling
  scheduled_sync_enabled            = true
  sync_refresh_interval_minutes     = var.sync_interval_minutes
  disable_sync_on_auth_error        = true
  concurrent_device_sync_enabled    = true
}

resource "jamfplatform_security_cloud_activation_profile" "mac" {
  name      = "${var.name_prefix}${var.profile_name}"
  platforms = ["mac"]

  capabilities = {
    content_controls = var.content_controls
    network_security = var.network_security
    note             = var.managed_by_tag
  }

  # With UEM Connect in place, Security Cloud can push this profile's
  # enrollment configuration down to Jamf Pro.
  depends_on = [jamfplatform_security_cloud_uem_connect.jamf_pro]
}
