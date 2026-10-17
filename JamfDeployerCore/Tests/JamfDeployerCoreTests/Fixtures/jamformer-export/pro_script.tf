resource "jamfplatform_pro_script" "jd_install_rosetta_2" {
  provider = jamfplatform

  info            = "Managed by Jamf Deployer · rosetta@1.0.0"
  name            = "JD - Install Rosetta 2"
  priority        = "AFTER"
  script_contents = file("${path.module}/support_files/scripts/JD - Install Rosetta 2.zsh")
}
