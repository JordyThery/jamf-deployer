
resource "jamfplatform_pro_macos_configuration_profile" "zz_secret_scan_test" {
  provider = jamfplatform

  general = {
    category_id         = "-1"
    description         = "Fake secret for Jamf Deployer secret-scan test"
    distribution_method = "Install Automatically"
    level               = "Computer Level"
    name                = "ZZ Secret Scan Test"
    payloads            = file("${path.module}/support_files/macos_configuration_profiles/ZZ Secret Scan Test.mobileconfig")
    redeploy_on_update  = "Newly Assigned"
    site_id             = "-1"
  }
  scope = {
    exclusions = {
      building_ids                          = []
      computer_group_ids                    = []
      computer_ids                          = []
      department_ids                        = []
      directory_service_or_local_user_names = []
      directory_service_user_group_names    = []
      ibeacon_ids                           = []
      network_segment_ids                   = []
      user_group_ids                        = []
      user_ids                              = []
    }
    limitations = {
      directory_service_or_local_user_names = []
      directory_service_user_group_names    = []
      ibeacon_ids                           = []
      network_segment_ids                   = []
    }
    targets = {
      all_computers      = false
      all_jss_users      = false
      building_ids       = []
      computer_group_ids = []
      computer_ids       = []
      department_ids     = []
      user_group_ids     = []
      user_ids           = []
    }
  }
  self_service = {
    install_button_text   = "Install"
    notification_location = "Self Service"
    removal_disallowed    = "Never"
  }
}
