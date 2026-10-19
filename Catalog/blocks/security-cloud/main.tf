# UEM Connect binds Security Cloud to the Jamf Pro tenant this provider is
# scoped to — no manual API client needed on the platform. Security Cloud
# holds one integration per tenant: with uem_connect = "existing" the block
# reads the one already there and leaves it alone.
data "jamfplatform_pro_tenant_id" "current" {}

resource "jamfplatform_security_cloud_uem_connect" "jamf_pro" {
  count      = var.uem_connect == "create" ? 1 : 0
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

# Fails the plan when no integration exists yet, rather than deploying a
# profile nothing pushes to Jamf Pro.
data "jamfplatform_security_cloud_uem_connect" "existing" {
  count = var.uem_connect == "existing" ? 1 : 0
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
  depends_on = [
    jamfplatform_security_cloud_uem_connect.jamf_pro,
    data.jamfplatform_security_cloud_uem_connect.existing,
  ]
}
