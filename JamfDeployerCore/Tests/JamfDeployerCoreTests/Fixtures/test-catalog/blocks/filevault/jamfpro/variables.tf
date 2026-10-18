variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "managed_by_tag" {
  description = "Provenance tag written into descriptions and notes."
  type        = string
}

variable "scope_jamf_pro_group_id" {
  description = "Numeric Jamf Pro ID of the computer group the policy targets."
  type        = string
}

variable "category_id" {
  description = "Jamf Pro category for the policy."
  type        = string
  default     = "-1"
}

variable "auth_restart" {
  description = "Use authenticated restart after enabling FileVault."
  type        = bool
  default     = false
}
