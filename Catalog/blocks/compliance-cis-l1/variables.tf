variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "managed_by_tag" {
  description = "Provenance tag written into descriptions and notes."
  type        = string
}

variable "scope_platform_group_uuid" {
  description = "Platform UUID of the device group the benchmark targets."
  type        = string
}

variable "enforcement_mode" {
  description = "MONITOR or MONITOR_AND_ENFORCE. Immutable once created."
  type        = string
  default     = "MONITOR"

  validation {
    condition     = contains(["MONITOR", "MONITOR_AND_ENFORCE"], var.enforcement_mode)
    error_message = "Mode must be MONITOR or MONITOR_AND_ENFORCE."
  }
}

variable "macos_major_version" {
  description = "macOS major version the benchmark evaluates."
  type        = number
  default     = 26
}
