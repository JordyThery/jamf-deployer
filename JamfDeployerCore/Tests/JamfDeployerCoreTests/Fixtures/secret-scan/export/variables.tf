variable "jamfplatform_base_url" {
  description = "Jamf Platform API gateway host (e.g. https://us.api.jamfcloud.com, or eu. / apac.)"
  type        = string
}

variable "jamfplatform_client_id" {
  description = "Jamf Platform API client ID"
  type        = string
  sensitive   = true
}

variable "jamfplatform_client_secret" {
  description = "Jamf Platform API client secret"
  type        = string
  sensitive   = true
}

variable "jamfplatform_environment_id" {
  description = "Jamf Platform environment ID — the Platform environment this API integration targets"
  type        = string
}
