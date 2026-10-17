variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "managed_by_tag" {
  description = "Provenance tag written into descriptions and notes."
  type        = string
}

variable "profile_name" {
  description = "Activation profile name (prefix added automatically)."
  type        = string
  default     = "Mac Security"
}

variable "content_controls" {
  description = "Enable content controls."
  type        = bool
  default     = true
}

variable "network_security" {
  description = "Enable network security."
  type        = bool
  default     = true
}

variable "device_risk_signaling" {
  description = "Send device risk levels back to Jamf Pro."
  type        = bool
  default     = true
}

variable "sync_interval_minutes" {
  description = "Device sync interval in minutes (Security Cloud accepts only its admin-UI intervals; 60 is always valid)."
  type        = number
  default     = 60
}
