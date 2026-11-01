
resource "jamfplatform_pro_script" "elevation_demote_current_user_to_standard" {
  provider = jamfplatform

  category_id     = jamfplatform_pro_category.security.id
  info            = "Demote current logged in user to standard user permanently."
  name            = "[elevation] Demote current user to standard"
  priority        = "AFTER"
  script_contents = file("${path.module}/support_files/scripts/[elevation] Demote current user to standard.sh")
}

resource "jamfplatform_pro_script" "elevation_promote_current_user_to_admin" {
  provider = jamfplatform

  category_id     = jamfplatform_pro_category.security.id
  info            = "Promotes current user to admin permanently."
  name            = "[elevation] Promote current user to admin"
  priority        = "AFTER"
  script_contents = file("${path.module}/support_files/scripts/[elevation] Promote current user to admin.sh")
}

resource "jamfplatform_pro_script" "compliance_benchmark_000000000000000000000a02_golden_gate_sh" {
  provider = jamfplatform

  category_id     = jamfplatform_pro_category.cis_level_1.id
  name            = "compliance_benchmark_000000000000000000000a02_golden_gate.sh"
  os_requirements = "27.x"
  priority        = "AFTER"
  script_contents = file("${path.module}/support_files/scripts/compliance_benchmark_000000000000000000000a02_golden_gate.sh.zsh")
}

resource "jamfplatform_pro_script" "compliance_benchmark_000000000000000000000a02_sequoia_sh" {
  provider = jamfplatform

  category_id     = jamfplatform_pro_category.cis_level_1.id
  name            = "compliance_benchmark_000000000000000000000a02_sequoia.sh"
  os_requirements = "15.x"
  priority        = "AFTER"
  script_contents = file("${path.module}/support_files/scripts/compliance_benchmark_000000000000000000000a02_sequoia.sh.zsh")
}

resource "jamfplatform_pro_script" "compliance_benchmark_000000000000000000000a02_tahoe_sh" {
  provider = jamfplatform

  category_id     = jamfplatform_pro_category.cis_level_1.id
  name            = "compliance_benchmark_000000000000000000000a02_tahoe.sh"
  os_requirements = "26.x"
  priority        = "AFTER"
  script_contents = file("${path.module}/support_files/scripts/compliance_benchmark_000000000000000000000a02_tahoe.sh.zsh")
}

resource "jamfplatform_pro_script" "compliance_benchmark_000000000000000000000a01_tahoe_sh" {
  provider = jamfplatform

  category_id     = jamfplatform_pro_category.jd_spike_cis_l1_monitor.id
  name            = "compliance_benchmark_000000000000000000000a01_tahoe.sh"
  os_requirements = "26.x"
  priority        = "AFTER"
  script_contents = file("${path.module}/support_files/scripts/compliance_benchmark_000000000000000000000a01_tahoe.sh.zsh")
}
