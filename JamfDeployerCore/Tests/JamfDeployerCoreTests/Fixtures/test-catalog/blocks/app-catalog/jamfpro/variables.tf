variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "managed_by_tag" {
  description = "Provenance tag written into descriptions and notes."
  type        = string
}

variable "scope_jamf_pro_group_id" {
  description = "Smart computer group ID the deployments are scoped to. App Installers require a smart group."
  type        = string
}

variable "category_id" {
  description = "Jamf Pro category for apps without their own."
  type        = string
  default     = "-1"
}

variable "apps_json" {
  description = "JSON array of apps: [{titleName, publisher, deploymentType, updateBehavior, categoryId?}]. Produced by the App Catalog picker; an app without categoryId uses category_id."
  type        = string
  default     = "[]"

  validation {
    condition     = can(jsondecode(var.apps_json))
    error_message = "apps_json must be valid JSON."
  }
}
