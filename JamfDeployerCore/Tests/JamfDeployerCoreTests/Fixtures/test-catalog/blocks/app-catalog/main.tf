locals {
  apps = { for app in jsondecode(var.apps_json) : app.titleName => app }
}

resource "jamfplatform_pro_app_installer" "app" {
  for_each = local.apps

  name            = "${var.name_prefix}${each.value.titleName}"
  app_title_name  = each.value.titleName
  deployment_type = each.value.deploymentType
  update_behavior = each.value.updateBehavior
  category_id     = var.category_id
  smart_group_id  = var.scope_jamf_pro_group_id
  enabled         = true

  install_predefined_config_profiles = false
  trigger_admin_notifications        = false
}
