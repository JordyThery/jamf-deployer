variable "jamfplatform_base_url" {
  type = string
}

variable "pro_icon_icon_18_icon_file_source" {
  description = "Local file for icon 18"
  type        = string
  default     = "support_files/icons/icon_18.png"
}

variable "pro_icon_icon_12_icon_file_source" {
  description = "Local file for icon 12"
  type        = string
}

variable "pro_icon_icon_99_icon_file_source" {
  description = "Required value (the server returned an empty value, so it must be supplied here)"
  type        = string
}
