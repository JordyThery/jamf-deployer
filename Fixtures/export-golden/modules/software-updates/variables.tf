variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "managed_by_tag" {
  description = "Provenance tag written into descriptions and notes."
  type        = string
}

variable "scope_platform_group_uuid" {
  description = "Platform UUID of the device group the Blueprint targets."
  type        = string
}

variable "deferral_major_days" {
  description = "Days to defer major upgrades (1-90)."
  type        = number
  default     = 14

  validation {
    condition     = var.deferral_major_days >= 1 && var.deferral_major_days <= 90
    error_message = "Major-upgrade deferral must be between 1 and 90 days."
  }
}

variable "deferral_minor_days" {
  description = "Days to defer minor updates (1-90)."
  type        = number
  default     = 7

  validation {
    condition     = var.deferral_minor_days >= 1 && var.deferral_minor_days <= 90
    error_message = "Minor-update deferral must be between 1 and 90 days."
  }
}

variable "allow_standard_user_updates" {
  description = "Allow standard users to install OS updates."
  type        = bool
  default     = true
}

variable "notifications_enabled" {
  description = "Show update notifications to users."
  type        = bool
  default     = true
}
