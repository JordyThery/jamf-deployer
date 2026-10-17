resource "jamfplatform_pro_icon" "icon_18" {
  icon_file_source = var.pro_icon_icon_18_icon_file_source
}

resource "jamfplatform_pro_icon" "icon_12" {
  icon_file_source = var.pro_icon_icon_12_icon_file_source
}

resource "jamfplatform_pro_icon" "icon_99" {
  icon_file_source = var.pro_icon_icon_99_icon_file_source

  lifecycle {
    ignore_changes = [icon_file_source]
  }
}
