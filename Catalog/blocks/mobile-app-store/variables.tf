variable "name_prefix" {
  description = "Prefix applied to every object name."
  type        = string
}

variable "managed_by_tag" {
  description = "Provenance tag written into descriptions and notes."
  type        = string
}

variable "category_id" {
  description = "Jamf Pro category for apps without their own."
  type        = string
  default     = "-1"
}

variable "vpp_location_name" {
  description = "Name of the Apps and Books (volume purchasing) location that holds the licenses."
  type        = string
}

variable "apps_json" {
  description = "JSON array of apps: [{adamId, name, deploymentType?, categoryId?}]. Produced by the App Store picker; an app without categoryId uses category_id."
  type        = string
  default     = "[]"

  validation {
    condition     = can(jsondecode(var.apps_json))
    error_message = "apps_json must be valid JSON."
  }
}

variable "scope_jamf_pro_mobile_group_id" {
  description = "Numeric Jamf Pro ID of the mobile device group the apps are scoped to."
  type        = string
}
