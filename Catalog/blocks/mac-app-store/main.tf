locals {
  # Normalized so apps with and without optional fields share one type.
  apps = {
    for app in jsondecode(var.apps_json) : app.adamId => {
      deploymentType = try(app.deploymentType, "SELF_SERVICE")
      categoryId     = try(app.categoryId, null)
    }
  }
}

# App Store metadata is looked up per tenant, so name, version and bundle
# ID always match the current listing.
data "jamfplatform_apple_app_store_app" "app" {
  for_each = local.apps
  id       = each.key
  target   = "mac"
}

data "jamfplatform_pro_volume_purchasing_location" "location" {
  name = var.vpp_location_name
}

resource "jamfplatform_pro_mac_app_store_app" "app" {
  for_each = local.apps

  general = {
    name            = "${var.name_prefix}${data.jamfplatform_apple_app_store_app.app[each.key].name}"
    version         = data.jamfplatform_apple_app_store_app.app[each.key].version
    bundle_id       = data.jamfplatform_apple_app_store_app.app[each.key].bundle_id
    url             = data.jamfplatform_apple_app_store_app.app[each.key].url
    is_free         = data.jamfplatform_apple_app_store_app.app[each.key].is_free
    category_id     = coalesce(each.value.categoryId, var.category_id)
    deployment_type = each.value.deploymentType == "INSTALL_AUTOMATICALLY" ? "Install Automatically/Prompt Users to Install" : "Make Available in Self Service"
  }
  scope = {
    targets = {
      computer_group_ids = [var.scope_jamf_pro_group_id]
    }
  }
  vpp = {
    assign_vpp_device_based_licenses = true
    vpp_admin_account_id             = data.jamfplatform_pro_volume_purchasing_location.location.id
  }
}
