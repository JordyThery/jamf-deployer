# Compliance benchmark spike: build a tiny monitor-mode benchmark from the
# CIS Level 1 baseline, targeted at the pilot device group's Platform UUID.

data "jamfplatform_cbengine_baselines" "all" {}

locals {
  cis_l1_candidates = [
    for b in data.jamfplatform_cbengine_baselines.all.baselines :
    b.baseline_id if can(regex("(?i)cis.*level 1", b.title))
  ]
  cis_l1_baseline_id = local.cis_l1_candidates[0]
}

data "jamfplatform_cbengine_rules" "cis_l1" {
  baseline_id = local.cis_l1_baseline_id
}

locals {
  # First three rules that need no organisation-defined value.
  spike_rules = slice([
    for r in data.jamfplatform_cbengine_rules.cis_l1.rules :
    { id = r.id, enabled = true }
    if r.odv_type == null || r.odv_type == ""
  ], 0, 3)
}

resource "jamfplatform_cbengine_benchmark" "spike" {
  title              = "${var.name_prefix}CIS L1 Monitor"
  description        = "Managed by Jamf Deployer · compliance-cis-l1@0.0.1"
  enforcement_mode   = "MONITOR"
  source_baseline_id = local.cis_l1_baseline_id
  rules              = local.spike_rules

  selected_os_versions = [{
    os_type    = "MAC_OS"
    os_version = 26
  }]

  target_device_groups = [jamfplatform_device_group.pilot.id]
}

output "baseline_titles" {
  value = [for b in data.jamfplatform_cbengine_baselines.all.baselines : b.title]
}
