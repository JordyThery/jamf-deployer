data "jamfplatform_cbengine_baselines" "all" {}

locals {
  cis_l1_baseline_id = [
    for b in data.jamfplatform_cbengine_baselines.all.baselines :
    b.baseline_id if can(regex("(?i)cis.*level 1", b.title))
  ][0]
}

data "jamfplatform_cbengine_rules" "cis_l1" {
  baseline_id = local.cis_l1_baseline_id
}

resource "jamfplatform_cbengine_benchmark" "cis_l1" {
  title              = "${var.name_prefix}CIS Level 1"
  description        = var.managed_by_tag
  enforcement_mode   = var.enforcement_mode
  source_baseline_id = local.cis_l1_baseline_id

  selected_os_versions = [{
    os_type    = "MAC_OS"
    os_version = var.macos_major_version
  }]

  # Every rule, with the baseline's recommended organisation-defined values.
  # Per-rule overrides become settings in a later update.
  rules = [
    for r in data.jamfplatform_cbengine_rules.cis_l1.rules : {
      id        = r.id
      enabled   = true
      odv_value = r.odv_value
    }
  ]

  target_device_groups = [var.scope_platform_group_uuid]
}
