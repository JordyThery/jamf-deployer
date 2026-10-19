variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "managed_by_tag" {
  description = "Provenance tag written into descriptions and notes."
  type        = string
}

variable "scope_jamf_pro_mobile_group_id" {
  description = "Numeric Jamf Pro ID of the mobile device group this block targets."
  type        = string
}

variable "category_id" {
  description = "Jamf Pro category for the profile."
  type        = string
  default     = "-1"
}

variable "minimum_length" {
  description = "Minimum passcode length."
  type        = number
  default     = 6
}

variable "max_inactivity_minutes" {
  description = "Minutes of inactivity before the device locks."
  type        = number
  default     = 5
}
