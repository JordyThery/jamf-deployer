variable "name_prefix" {
  type = string
}

variable "managed_by_tag" {
  type = string
}

variable "token" {
  type      = string
  sensitive = true
}
