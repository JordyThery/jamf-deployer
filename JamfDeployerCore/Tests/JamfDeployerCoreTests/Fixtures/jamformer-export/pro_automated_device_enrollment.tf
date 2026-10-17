resource "jamfplatform_pro_automated_device_enrollment" "apple_business_manager" {
  provider = jamfplatform

  name                    = "Apple Business Manager"
  server_token            = var.pro_automated_device_enrollment_apple_business_manager_server_token
  server_token_wo_version = 1
  site_id                 = "-1"
  supervision_identity_id = "-1"
}
