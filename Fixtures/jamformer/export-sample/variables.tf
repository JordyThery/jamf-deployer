variable "jamfplatform_base_url" {
  description = "Jamf Platform API gateway host (e.g. https://us.api.jamfcloud.com, or eu. / apac.)"
  type        = string
}

variable "jamfplatform_client_id" {
  description = "Jamf Platform API client ID"
  type        = string
  sensitive   = true
}

variable "jamfplatform_client_secret" {
  description = "Jamf Platform API client secret"
  type        = string
  sensitive   = true
}

variable "jamfplatform_environment_id" {
  description = "Jamf Platform environment ID — the Platform environment this API integration targets"
  type        = string
}

variable "pro_icon_icon_19_icon_file_source" {
  description = "Required value for jamfplatform_pro_icon.icon_19 icon_file_source (the server returned an empty value, so it must be supplied here)"
  type        = string
}

variable "pro_icon_icon_18_icon_file_source" {
  description = "Required value for jamfplatform_pro_icon.icon_18 icon_file_source (the server returned an empty value, so it must be supplied here)"
  type        = string
}

variable "pro_icon_icon_14_icon_file_source" {
  description = "Required value for jamfplatform_pro_icon.icon_14 icon_file_source (the server returned an empty value, so it must be supplied here)"
  type        = string
}

variable "pro_icon_icon_10_icon_file_source" {
  description = "Required value for jamfplatform_pro_icon.icon_10 icon_file_source (the server returned an empty value, so it must be supplied here)"
  type        = string
}

variable "pro_icon_icon_13_icon_file_source" {
  description = "Required value for jamfplatform_pro_icon.icon_13 icon_file_source (the server returned an empty value, so it must be supplied here)"
  type        = string
}

variable "pro_icon_icon_7_icon_file_source" {
  description = "Required value for jamfplatform_pro_icon.icon_7 icon_file_source (the server returned an empty value, so it must be supplied here)"
  type        = string
}

variable "pro_icon_icon_3_icon_file_source" {
  description = "Required value for jamfplatform_pro_icon.icon_3 icon_file_source (the server returned an empty value, so it must be supplied here)"
  type        = string
}

variable "pro_icon_icon_39_icon_file_source" {
  description = "Required value for jamfplatform_pro_icon.icon_39 icon_file_source (the server returned an empty value, so it must be supplied here)"
  type        = string
}

variable "pro_icon_icon_12_icon_file_source" {
  description = "Required value for jamfplatform_pro_icon.icon_12 icon_file_source (the server returned an empty value, so it must be supplied here)"
  type        = string
}

variable "pro_icon_icon_20_icon_file_source" {
  description = "Required value for jamfplatform_pro_icon.icon_20 icon_file_source (the server returned an empty value, so it must be supplied here)"
  type        = string
}

variable "pro_icon_icon_21_icon_file_source" {
  description = "Required value for jamfplatform_pro_icon.icon_21 icon_file_source (the server returned an empty value, so it must be supplied here)"
  type        = string
}

variable "pro_icon_icon_34_icon_file_source" {
  description = "Required value for jamfplatform_pro_icon.icon_34 icon_file_source (the server returned an empty value, so it must be supplied here)"
  type        = string
}
