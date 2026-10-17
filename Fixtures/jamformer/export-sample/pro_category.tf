
resource "jamfplatform_pro_category" "adobe" {
  provider = jamfplatform

  name     = "Adobe"
  priority = 3
}

resource "jamfplatform_pro_category" "apple" {
  provider = jamfplatform

  name     = "Apple"
  priority = 2
}

resource "jamfplatform_pro_category" "browsers" {
  provider = jamfplatform

  name     = "Browsers"
  priority = 5
}

resource "jamfplatform_pro_category" "cis_level_1" {
  provider = jamfplatform

  name     = "CIS Level 1"
  priority = 9
}

resource "jamfplatform_pro_category" "enrollment" {
  provider = jamfplatform

  name     = "Enrollment"
  priority = 1
}

resource "jamfplatform_pro_category" "jamf" {
  provider = jamfplatform

  name     = "Jamf"
  priority = 7
}

resource "jamfplatform_pro_category" "l9_spike_cis_l1_monitor" {
  provider = jamfplatform

  name     = "L9 Spike - CIS L1 Monitor"
  priority = 9
}

resource "jamfplatform_pro_category" "l9_spike_deployer" {
  provider = jamfplatform

  name     = "L9 Spike - Deployer"
  priority = 9
}

resource "jamfplatform_pro_category" "microsoft" {
  provider = jamfplatform

  name     = "Microsoft"
  priority = 4
}

resource "jamfplatform_pro_category" "networking" {
  provider = jamfplatform

  name     = "Networking"
  priority = 10
}

resource "jamfplatform_pro_category" "onboarding" {
  provider = jamfplatform

  name     = "Onboarding"
  priority = 1
}

resource "jamfplatform_pro_category" "other" {
  provider = jamfplatform

  name     = "Other"
  priority = 20
}

resource "jamfplatform_pro_category" "patch_management" {
  provider = jamfplatform

  name     = "Patch Management"
  priority = 17
}

resource "jamfplatform_pro_category" "pppc" {
  provider = jamfplatform

  name     = "PPPC"
  priority = 16
}

resource "jamfplatform_pro_category" "printers" {
  provider = jamfplatform

  name     = "Printers"
  priority = 12
}

resource "jamfplatform_pro_category" "security" {
  provider = jamfplatform

  name     = "Security"
  priority = 15
}

resource "jamfplatform_pro_category" "sequoia_cis_lvl2" {
  provider = jamfplatform

  name     = "Sequoia_cis_lvl2"
  priority = 9
}

resource "jamfplatform_pro_category" "tf_browsers" {
  provider = jamfplatform

  name     = "TF - Browsers"
  priority = 9
}

resource "jamfplatform_pro_category" "tf_enrollment" {
  provider = jamfplatform

  name     = "TF - Enrollment"
  priority = 9
}

resource "jamfplatform_pro_category" "tf_jamf" {
  provider = jamfplatform

  name     = "TF - Jamf"
  priority = 9
}

resource "jamfplatform_pro_category" "tf_microsoft" {
  provider = jamfplatform

  name     = "TF - Microsoft"
  priority = 9
}

resource "jamfplatform_pro_category" "tf_networking" {
  provider = jamfplatform

  name     = "TF - Networking"
  priority = 9
}

resource "jamfplatform_pro_category" "tf_onboarding" {
  provider = jamfplatform

  name     = "TF - Onboarding"
  priority = 9
}

resource "jamfplatform_pro_category" "tf_other" {
  provider = jamfplatform

  name     = "TF - Other"
  priority = 9
}

resource "jamfplatform_pro_category" "tf_patch_management" {
  provider = jamfplatform

  name     = "TF - Patch Management"
  priority = 9
}

resource "jamfplatform_pro_category" "tf_pppc" {
  provider = jamfplatform

  name     = "TF - PPPC"
  priority = 9
}

resource "jamfplatform_pro_category" "tf_printers" {
  provider = jamfplatform

  name     = "TF - Printers"
  priority = 9
}

resource "jamfplatform_pro_category" "tf_security" {
  provider = jamfplatform

  name     = "TF - Security"
  priority = 9
}

resource "jamfplatform_pro_category" "tf_troubleshooting" {
  provider = jamfplatform

  name     = "TF - Troubleshooting"
  priority = 9
}

resource "jamfplatform_pro_category" "troubleshooting" {
  provider = jamfplatform

  name     = "Troubleshooting"
  priority = 19
}
