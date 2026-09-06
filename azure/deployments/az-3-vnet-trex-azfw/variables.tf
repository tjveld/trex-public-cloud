# ==============================================================================
# General
# ==============================================================================

variable "environment" {
  type        = string
  description = "Deployment environment name"
  default     = "az-3"
}

variable "location" {
  type        = string
  description = "Azure region"
  default     = "westeurope"
}

variable "project_name" {
  type        = string
  description = "Project name for resource naming"
  default     = "comp70046"
}

variable "tags" {
  type        = map(string)
  description = "Additional tags to apply to all resources, merged with environment/project tags"
  default     = {}
}

variable "vm_admin_username" {
  type        = string
  description = "Admin username for VMs deployed in this configuration"
  default     = "tjveld"
}

variable "vm_admin_password" {
  type        = string
  description = "Admin password for VMs deployed in this configuration. No default - supply via a *.auto.tfvars file, -var, or TF_VAR_vm_admin_password so it isn't committed."
  sensitive   = true
}

# ==============================================================================
# Hub Virtual Network
# ==============================================================================

variable "hub_address_space" {
  type        = list(string)
  description = "Address space for the hub virtual network"
  default     = ["10.100.0.0/16"]
}

variable "hub_subnets" {
  type = map(object({
    address_prefixes = list(string)
  }))
  description = "Hub virtual network subnets"
  default = {
    # Azure Firewall (firewall.tf) - its private IP is only known after
    # apply, so spoke_1_subnets' routes below default next_hop_in_ip_address
    # to null; main.tf fills it in.
    "AzureFirewallSubnet" = {
      address_prefixes = ["10.100.0.0/24"]
    }
  }
}

# ==============================================================================
# Spoke 1 Virtual Network
# ==============================================================================

variable "spoke_1_address_space" {
  type        = list(string)
  description = "Address space for spoke 1 virtual network"
  default     = ["10.10.0.0/16"]
}

variable "spoke_1_subnets" {
  type = map(object({
    address_prefixes = list(string)
    routes = optional(list(object({
      name                   = string
      address_prefix         = string
      next_hop_type          = string
      next_hop_in_ip_address = optional(string)
    })), [])
  }))
  description = "Spoke 1 virtual network subnets. Each subnet gets its own dedicated route table, populated from that subnet's `routes` list."
  default = {
    # trex-01's mgmt NIC - no routes needed.
    "snet-mgmt-01" = {
      address_prefixes = ["10.10.0.0/24"]
    }
    # trex1 (client 16.0.0.0/8) - forces server-bound traffic through the
    # firewall.
    "snet-app-01" = {
      address_prefixes = ["10.10.1.0/24"]
      routes = [
        {
          name                   = "trex-servers-via-azfw"
          address_prefix         = "48.0.0.0/8"
          next_hop_type          = "VirtualAppliance"
          next_hop_in_ip_address = null # set in main.tf
        }
      ]
    }
    # trex2 (server 48.0.0.0/8) - mirrors snet-app-01's route, return
    # direction.
    "snet-app-02" = {
      address_prefixes = ["10.10.2.0/24"]
      routes = [
        {
          name                   = "trex-clients-via-azfw"
          address_prefix         = "16.0.0.0/8"
          next_hop_type          = "VirtualAppliance"
          next_hop_in_ip_address = null # set in main.tf
        }
      ]
    }
  }
}

# ==============================================================================
# DNS
# ==============================================================================

variable "dns_zone_name" {
  type        = string
  description = "Name of the pre-existing Azure DNS zone (e.g. az.domain.com) that this deployment's A records are created in"
}

variable "dns_zone_id" {
  type        = string
  description = "Resource ID of the pre-existing Azure DNS zone (Microsoft.Network/dnszones) that this deployment's A records are created in"
}
