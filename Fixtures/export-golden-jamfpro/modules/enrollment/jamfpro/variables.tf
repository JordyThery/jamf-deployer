variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "managed_by_tag" {
  description = "Provenance tag written into descriptions and notes."
  type        = string
}

variable "ade_instance_name" {
  description = "Exact display name of the Automated Device Enrollment instance in Jamf Pro."
  type        = string

  validation {
    condition     = length(var.ade_instance_name) > 0
    error_message = "Enter the ADE instance name shown in Jamf Pro under Settings → Device Enrollment."
  }
}

variable "prestage_display_name" {
  description = "PreStage display name (prefix added automatically)."
  type        = string
  default     = "Standard Enrollment"
}

variable "default_prestage" {
  description = "Make this the tenant's default PreStage."
  type        = bool
  default     = false
}

variable "auto_advance_setup" {
  description = "Auto-advance through Setup Assistant (shared/lab devices)."
  type        = bool
  default     = false
}

variable "support_email" {
  description = "Support email shown during enrollment."
  type        = string
  default     = ""
}

variable "support_phone" {
  description = "Support phone shown during enrollment."
  type        = string
  default     = ""
}
