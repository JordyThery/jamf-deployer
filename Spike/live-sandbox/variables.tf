variable "name_prefix" {
  description = "Prefix applied to every object name this spike creates."
  type        = string
  default     = "JD Spike - "
}

variable "ade_instance_name" {
  description = "Exact display name of an ADE instance in the sandbox. Leave empty to skip the prestage check."
  type        = string
  default     = ""
}

variable "package_path" {
  description = "Local path to a .pkg to upload via the provider. Leave empty to skip the package-upload check."
  type        = string
  default     = ""
}
