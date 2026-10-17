
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

resource "jamfplatform_pro_script" "compliance_benchmark_6ac1eb687d59fd2f1238db72_golden_gate_sh" {
  provider = jamfplatform

  category_id     = jamfplatform_pro_category.cis_level_1.id
  name            = "compliance_benchmark_6ac1eb687d59fd2f1238db72_golden_gate.sh"
  os_requirements = "27.x"
  priority        = "AFTER"
  script_contents = file("${path.module}/support_files/scripts/compliance_benchmark_6ac1eb687d59fd2f1238db72_golden_gate.sh.zsh")
}

resource "jamfplatform_pro_script" "compliance_benchmark_6ac1eb687d59fd2f1238db72_sequoia_sh" {
  provider = jamfplatform

  category_id     = jamfplatform_pro_category.cis_level_1.id
  name            = "compliance_benchmark_6ac1eb687d59fd2f1238db72_sequoia.sh"
  os_requirements = "15.x"
  priority        = "AFTER"
  script_contents = file("${path.module}/support_files/scripts/compliance_benchmark_6ac1eb687d59fd2f1238db72_sequoia.sh.zsh")
}

resource "jamfplatform_pro_script" "compliance_benchmark_6ac1eb687d59fd2f1238db72_tahoe_sh" {
  provider = jamfplatform

  category_id     = jamfplatform_pro_category.cis_level_1.id
  name            = "compliance_benchmark_6ac1eb687d59fd2f1238db72_tahoe.sh"
  os_requirements = "26.x"
  priority        = "AFTER"
  script_contents = file("${path.module}/support_files/scripts/compliance_benchmark_6ac1eb687d59fd2f1238db72_tahoe.sh.zsh")
}

resource "jamfplatform_pro_script" "compliance_benchmark_6ad2dac512daba130f642175_tahoe_sh" {
  provider = jamfplatform

  category_id     = jamfplatform_pro_category.l9_spike_cis_l1_monitor.id
  name            = "compliance_benchmark_6ad2dac512daba130f642175_tahoe.sh"
  os_requirements = "26.x"
  priority        = "AFTER"
  script_contents = file("${path.module}/support_files/scripts/compliance_benchmark_6ad2dac512daba130f642175_tahoe.sh.zsh")
}
