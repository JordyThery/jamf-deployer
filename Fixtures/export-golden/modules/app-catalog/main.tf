locals {
  # Normalized so apps with and without their own category share one type.
  apps = {
    for app in jsondecode(var.apps_json) : app.titleName => {
      titleName      = app.titleName
      deploymentType = app.deploymentType
      updateBehavior = app.updateBehavior
      categoryId     = try(app.categoryId, null)
    }
  }
}

resource "jamfplatform_pro_app_installer" "app" {
  for_each = local.apps

  name            = "${var.name_prefix}${each.value.titleName}"
  app_title_name  = each.value.titleName
  deployment_type = each.value.deploymentType
  update_behavior = each.value.updateBehavior
  category_id     = coalesce(each.value.categoryId, var.category_id)
  smart_group_id  = var.scope_jamf_pro_group_id
  enabled         = true

  install_predefined_config_profiles = false
  trigger_admin_notifications        = false
}
