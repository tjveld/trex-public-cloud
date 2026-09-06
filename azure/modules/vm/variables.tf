variable "name" {
  type        = string
  description = "Name of the virtual machine. Also used to derive the NIC and public IP names."
}

variable "location" {
  type        = string
  description = "Azure region for the VM and its NIC"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group to deploy into"
}

variable "network_interfaces" {
  type = map(object({
    subnet_id                     = string
    private_ip_address            = optional(string)
    enable_accelerated_networking = optional(bool, true)
    enable_ip_forwarding          = optional(bool, false)
    enable_public_ip              = optional(bool, false)
    public_ip_sku                 = optional(string, "Standard")
    primary                       = optional(bool, false)
  }))
  description = <<-EOT
    NICs to create and attach, keyed by a short name (e.g. "primary", "mgmt").
    When more than one entry is given, exactly one must have primary = true.
  EOT

  validation {
    condition     = length(var.network_interfaces) > 0
    error_message = "At least one network interface must be defined."
  }

  validation {
    condition     = length(var.network_interfaces) == 1 || length([for k, v in var.network_interfaces : k if v.primary]) == 1
    error_message = "When more than one network_interfaces entry is given, exactly one must have primary = true."
  }
}

variable "network_security_group_associations" {
  type        = map(string)
  description = "Map of network_interfaces key to NSG ID to associate. Only NICs present as keys get an association."
  default     = {}
}

variable "management_source_address_prefix" {
  type        = string
  description = "Source IP or CIDR allowed to reach SSH/RDP/HTTP/HTTPS. Required when a public network_interfaces entry has no matching NSG association."
  default     = null
}

variable "size" {
  type        = string
  description = "VM size (SKU), e.g. Standard_B2s"
  default     = "Standard_B2s"
}

variable "zone" {
  type        = string
  description = "Availability zone to pin the VM to, e.g. \"1\". Null lets Azure place it without a zone."
  default     = null
}

variable "os_type" {
  type        = string
  description = "\"Linux\" or \"Windows\" - determines which VM resource type is created"

  validation {
    condition     = contains(["Linux", "Windows"], var.os_type)
    error_message = "os_type must be either \"Linux\" or \"Windows\"."
  }
}

variable "admin_username" {
  type        = string
  description = "Admin username for the VM"
}

variable "admin_password" {
  type        = string
  description = "Admin password. Required for Windows, and for Linux when disable_password_authentication is false (the default)."
  default     = null
  sensitive   = true
}

variable "admin_ssh_public_key" {
  type        = string
  description = "SSH public key for the admin user. Required for Linux when disable_password_authentication is true."
  default     = null
}

variable "disable_password_authentication" {
  type        = bool
  description = "Linux only: disable password auth in favour of admin_ssh_public_key. Defaults to false (password auth) - set true to require an SSH key instead."
  default     = false
}

variable "source_image_reference" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  description = "Marketplace image to deploy. Defaults to Ubuntu 24.04 LTS - override for Windows or a different distro."
  default = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}

variable "plan" {
  type = object({
    name      = string
    publisher = string
    product   = string
  })
  description = "Marketplace purchase plan, required by images with license terms (e.g. VyOS). Leave null for standard/free images."
  default     = null
}

variable "custom_data" {
  type        = string
  description = "Script or cloud-init config to run on first boot, as plain text - this module base64-encodes it. Changing it after creation forces VM replacement."
  default     = null
}

variable "os_disk_caching" {
  type        = string
  description = "OS disk caching mode"
  default     = "ReadWrite"
}

variable "os_disk_storage_account_type" {
  type        = string
  description = "OS disk storage redundancy/performance tier"
  default     = "StandardSSD_LRS"
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to the VM and all NICs/public IPs"
  default     = {}
}
