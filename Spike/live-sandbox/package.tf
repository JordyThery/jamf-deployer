# Package-upload spike, gated on a local .pkg path.
# Verifies the provider uploads binaries to the Jamf Cloud Distribution Point.

resource "jamfplatform_pro_package" "spike" {
  count = var.package_path == "" ? 0 : 1

  display_name        = "${var.name_prefix}Upload Test"
  file_name           = basename(var.package_path)
  package_file_source = var.package_path
  category_id         = jamfplatform_pro_category.spike.id
  notes               = "Managed by Jamf Deployer · spike@0.0.1"
}

output "package_transfer_status" {
  value = var.package_path == "" ? null : jamfplatform_pro_package.spike[0].cloud_transfer_status
}
