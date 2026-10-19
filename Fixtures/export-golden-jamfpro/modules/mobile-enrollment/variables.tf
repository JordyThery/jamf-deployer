variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "managed_by_tag" {
  description = "Provenance tag written into descriptions and notes."
  type        = string
}

variable "ade_instance_name" {
  description = "Name of the tenant's Automated Device Enrollment instance."
  type        = string
}

variable "prestage_display_name" {
  description = "Display name of the PreStage (the name prefix is added)."
  type        = string
  default     = "iPad and iPhone Enrollment"
}

variable "default_prestage" {
  description = "Whether new devices land in this PreStage automatically."
  type        = bool
  default     = false
}

variable "support_email" {
  description = "Support email shown during enrollment."
  type        = string
  default     = ""
}

variable "support_phone" {
  description = "Support phone number shown during enrollment."
  type        = string
  default     = ""
}
