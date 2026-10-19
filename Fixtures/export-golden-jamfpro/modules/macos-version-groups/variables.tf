variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "managed_by_tag" {
  description = "Provenance tag written into descriptions and notes."
  type        = string
}

variable "current_major_version" {
  description = "Major macOS version considered current."
  type        = string
  default     = "26"
}

variable "minimum_major_version" {
  description = "Lowest supported major macOS version."
  type        = string
  default     = "15"
}
