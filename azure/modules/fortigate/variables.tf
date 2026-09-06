variable "name" {
  type        = string
  description = "Name of the FortiGate VM. Also used to derive its NICs, public IP, NSG, and log disk names."
}

variable "location" {
  type        = string
  description = "Azure region for the VM and all its resources"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group to deploy into"
}

variable "port1_subnet_id" {
  type        = string
  description = "Subnet ID for port1 (external/WAN NIC - gets a public IP and the management NSG)"
}

variable "port1_private_ip_address" {
  type        = string
  description = "Static private IP for port1. Null (default) leaves it dynamically assigned."
  default     = null
}

variable "port2_subnet_id" {
  type        = string
  description = "Subnet ID for port2 (internal/LAN NIC - IP forwarding enabled for transit traffic)"
}

variable "port2_private_ip_address" {
  type        = string
  description = "Static private IP for port2. Null (default) leaves it dynamically assigned."
  default     = null
}

variable "management_source_address_prefix" {
  type        = string
  description = "Source IP or CIDR allowed to reach port1 on SSH (22) and HTTPS (443). Required - port1 always gets a public IP."
}

variable "license_type" {
  type        = string
  description = "FortiGate licensing model - \"payg\" (billed through the Azure subscription) or \"byol\" (own Fortinet license). Selects a var.fgt_sku key."
  default     = "payg"

  validation {
    condition     = contains(["payg", "byol"], var.license_type)
    error_message = "license_type must be either \"payg\" or \"byol\"."
  }
}

variable "publisher" {
  type        = string
  description = "Marketplace publisher for the FortiGate-VM image"
  default     = "fortinet"
}

variable "offer" {
  type        = string
  description = "Marketplace offer for the FortiGate-VM image."
  default     = "fortinet_fortigate-vm"
}

variable "fgt_sku" {
  type        = map(string)
  description = <<-EOT
    Marketplace plan (sku) per license_type. Defaults are the Hyper-V
    Generation 2 skus for the FortiOS 7.6 branch.
  EOT
  default = {
    byol = "fortinet_fg-vm_byol_76_g2"
    payg = "fortinet_fg-vm_payg_76_g2"
  }
}

variable "fgt_version" {
  type        = string
  description = "FortiOS image version, or \"latest\""
  default     = "latest"
}

variable "size" {
  type        = string
  description = "VM size. Must be x64 and match var.fgt_sku's Hyper-V generation (the \"_g2\" skus above are Gen2)."
  default     = "Standard_F2als_v7"
}

variable "admin_username" {
  type        = string
  description = "Admin username for the VM"
}

variable "admin_password" {
  type        = string
  description = "Admin password for the VM"
  sensitive   = true
}

variable "bootstrap_config" {
  type        = string
  description = "Plain FortiOS CLI config script to run on first boot - this module wraps it in the MIME envelope FortiGate's image expects. Null skips it."
  default     = null
}

variable "log_disk_size_gb" {
  type        = number
  description = "Size (GB) of a dedicated empty data disk for FortiGate's log storage, attached at LUN 0. Null skips creating one."
  default     = 30
}

variable "os_disk_storage_account_type" {
  type        = string
  description = "OS disk storage redundancy/performance tier"
  default     = "StandardSSD_LRS"
}

variable "log_disk_storage_account_type" {
  type        = string
  description = "Log data disk storage redundancy/performance tier"
  default     = "Standard_LRS"
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to the VM and all its NICs/public IP/disks"
  default     = {}
}
