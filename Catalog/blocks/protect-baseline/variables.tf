variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "managed_by_tag" {
  description = "Provenance tag written into descriptions and notes."
  type        = string
}

variable "threat_mode" {
  description = "Report only or Block and report."
  type        = string
  default     = "Report only"

  validation {
    condition     = contains(["Report only", "Block and report"], var.threat_mode)
    error_message = "Threat prevention must be \"Report only\" or \"Block and report\"."
  }
}

variable "reporting_interval" {
  description = "Reporting interval in minutes."
  type        = number
  default     = 15
}

variable "auto_update" {
  description = "Auto-update the Protect agent."
  type        = bool
  default     = true
}

variable "collect_network_telemetry" {
  description = "Collect network connection telemetry."
  type        = bool
  default     = false
}
