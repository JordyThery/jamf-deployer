variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "managed_by_tag" {
  description = "Provenance tag written into descriptions and notes."
  type        = string
}

variable "clear_management_history" {
  description = "DELETE_NOTHING, DELETE_ERRORS, DELETE_EVERYTHING_EXCEPT_ACKNOWLEDGED or DELETE_EVERYTHING."
  type        = string
  default     = "DELETE_EVERYTHING_EXCEPT_ACKNOWLEDGED"
}

variable "clear_policy_logs" {
  description = "Clear policy logs on re-enrollment."
  type        = bool
  default     = true
}

variable "clear_extension_attributes" {
  description = "Clear extension attribute values on re-enrollment."
  type        = bool
  default     = true
}

variable "clear_location_information" {
  description = "Clear user and location information and its history on re-enrollment."
  type        = bool
  default     = true
}
