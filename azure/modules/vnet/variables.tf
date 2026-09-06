variable "name" {
  type        = string
  description = "Name of the virtual network"
}

variable "location" {
  type        = string
  description = "Azure region for the virtual network"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group in which to create the virtual network"
}

variable "address_space" {
  type        = list(string)
  description = "Address space for the virtual network"
}

variable "subnets" {
  type = map(object({
    address_prefixes = list(string)
  }))
  description = "Map of subnets to create, keyed by subnet name."
  default     = {}
}

variable "route_table_associations" {
  type        = map(string)
  description = "Map of subnet name to route table ID to associate. Only subnets present as keys get an association."
  default     = {}
}

variable "network_security_group_associations" {
  type        = map(string)
  description = "Map of subnet name to network security group ID to associate. Only subnets present as keys get an association."
  default     = {}
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to the virtual network"
  default     = {}
}
