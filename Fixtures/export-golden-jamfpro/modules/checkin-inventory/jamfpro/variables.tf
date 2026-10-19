variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "managed_by_tag" {
  description = "Provenance tag written into descriptions and notes."
  type        = string
}

variable "check_in_frequency" {
  description = "Recurring check-in frequency in minutes: 5, 15, 30 or 60."
  type        = number
  default     = 15
}

variable "run_startup_policies" {
  description = "Run policies with the Startup trigger."
  type        = bool
  default     = true
}

variable "run_login_policies" {
  description = "Run policies with the Login trigger."
  type        = bool
  default     = true
}

variable "collect_application_usage" {
  description = "Collect application usage information."
  type        = bool
  default     = true
}

variable "include_home_directory_sizes" {
  description = "Include home folder sizes in inventory."
  type        = bool
  default     = false
}
