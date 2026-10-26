
resource "jamfplatform_pro_script" "zz_secret_scan_test" {
  provider = jamfplatform

  category_id     = "-1"
  info            = "Fake secret for Jamf Deployer secret-scan test"
  name            = "ZZ Secret Scan Test"
  priority        = "AFTER"
  script_contents = file("${path.module}/support_files/scripts/ZZ Secret Scan Test.zsh")
}
