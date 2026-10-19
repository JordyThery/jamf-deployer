variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "managed_by_tag" {
  description = "Provenance tag written into descriptions and notes."
  type        = string
}

variable "rotation_interval" {
  description = "Never, 7 days, 30 days, 60 days or 180 days."
  type        = string
  default     = "30 days"
}

variable "rotation_after_viewing_interval" {
  description = "1 hour, 3 hours, 12 hours, 1 day, 3 days or 7 days."
  type        = string
  default     = "1 hour"
}

variable "include_prestage_accounts" {
  description = "Rotate PreStage-created admin accounts too."
  type        = bool
  default     = true
}
