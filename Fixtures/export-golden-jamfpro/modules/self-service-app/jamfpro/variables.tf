variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "managed_by_tag" {
  description = "Provenance tag written into descriptions and notes."
  type        = string
}

variable "install_automatically" {
  description = "Install the Self Service app automatically."
  type        = bool
  default     = true
}

variable "default_landing_page" {
  description = "HOME, BROWSE, HISTORY or NOTIFICATIONS."
  type        = string
  default     = "HOME"
}

variable "notifications_enabled" {
  description = "Show Self Service notifications."
  type        = bool
  default     = true
}

variable "login_method" {
  description = "NotRequired, Anonymous or Required."
  type        = string
  default     = "NotRequired"
}

variable "authentication_type" {
  description = "Basic or Saml."
  type        = string
  default     = "Basic"
}
