variable "name" {
  type        = string
  description = "Name of the Azure Firewall. Also used to derive the firewall policy and public IP names."
}

variable "location" {
  type        = string
  description = "Azure region for the firewall, its policy, and its public IPs"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group to deploy into"
}

variable "firewall_subnet_id" {
  type        = string
  description = "ID of the subnet to deploy the firewall into. Must be named exactly \"AzureFirewallSubnet\" and be /26 or larger."

  validation {
    condition     = can(regex("/subnets/AzureFirewallSubnet$", var.firewall_subnet_id))
    error_message = "firewall_subnet_id must reference a subnet named exactly \"AzureFirewallSubnet\"."
  }
}

variable "sku_name" {
  type        = string
  description = "Firewall deployment model. \"AZFW_Hub\" (Virtual WAN Secured Hubs) isn't supported by this module."
  default     = "AZFW_VNet"

  validation {
    condition     = contains(["AZFW_VNet", "AZFW_Hub"], var.sku_name)
    error_message = "sku_name must be either \"AZFW_VNet\" or \"AZFW_Hub\"."
  }
}

variable "sku_tier" {
  type        = string
  description = "Firewall pricing tier. Premium is required for TLS inspection/IDPS and always needs a firewall policy (see firewall_policy_id)."
  default     = "Standard"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.sku_tier)
    error_message = "sku_tier must be one of \"Basic\", \"Standard\", or \"Premium\"."
  }
}

variable "zones" {
  type        = list(string)
  description = "Availability zones to spread the firewall and its public IPs across, e.g. [\"1\", \"2\", \"3\"]. Empty list leaves it non-zonal."
  default     = []
}

variable "public_ip_configurations" {
  type = map(object({
    primary = optional(bool, false)
  }))
  description = "Public IP configurations to create, keyed by a short name. Exactly one entry must have primary = true."
  default = {
    "fw-pip" = { primary = true }
  }

  validation {
    condition     = length(var.public_ip_configurations) > 0
    error_message = "At least one public IP configuration must be defined."
  }

  validation {
    condition     = length([for k, v in var.public_ip_configurations : k if v.primary]) == 1
    error_message = "Exactly one public_ip_configurations entry must have primary = true."
  }
}

variable "firewall_policy_id" {
  type        = string
  description = "ID of an existing firewall policy to attach instead of creating one. Null creates a dedicated policy."
  default     = null
}

variable "threat_intelligence_mode" {
  type        = string
  description = "Threat intelligence-based filtering mode for the auto-created firewall policy. Ignored when firewall_policy_id is set."
  default     = "Alert"

  validation {
    condition     = contains(["Off", "Alert", "Deny"], var.threat_intelligence_mode)
    error_message = "threat_intelligence_mode must be one of \"Off\", \"Alert\", or \"Deny\"."
  }
}

variable "dns_servers" {
  type        = list(string)
  description = "Custom DNS servers for the firewall to use, set on the auto-created firewall policy's dns block. Null keeps Azure-provided DNS. Ignored when firewall_policy_id is set."
  default     = null
}

variable "dns_proxy_enabled" {
  type        = bool
  description = "Whether the firewall proxies DNS requests on its private IP - lets network rules use FQDNs. Set on the auto-created firewall policy. Ignored when firewall_policy_id is set."
  default     = false
}

variable "snat_private_ip_ranges" {
  type        = list(string)
  description = "IP prefixes SNAT is skipped for. Null keeps Azure's default (RFC1918 + 100.64.0.0/10); setting this REPLACES that default. Ignored when firewall_policy_id is set."
  default     = null
}

variable "rule_collection_groups" {
  type = list(object({
    name     = string
    priority = number

    application_rule_collections = optional(list(object({
      name     = string
      action   = string
      priority = number
      rules = list(object({
        name                  = string
        source_addresses      = optional(list(string), [])
        source_ip_groups      = optional(list(string), [])
        destination_fqdns     = optional(list(string), [])
        destination_fqdn_tags = optional(list(string), [])
        protocols = list(object({
          type = string
          port = number
        }))
      }))
    })), [])

    network_rule_collections = optional(list(object({
      name     = string
      action   = string
      priority = number
      rules = list(object({
        name                  = string
        protocols             = list(string)
        source_addresses      = optional(list(string), [])
        source_ip_groups      = optional(list(string), [])
        destination_addresses = optional(list(string), [])
        destination_ip_groups = optional(list(string), [])
        destination_fqdns     = optional(list(string), [])
        destination_ports     = list(string)
      }))
    })), [])

    nat_rule_collections = optional(list(object({
      name     = string
      action   = string
      priority = number
      rules = list(object({
        name                = string
        protocols           = list(string)
        source_addresses    = optional(list(string), [])
        source_ip_groups    = optional(list(string), [])
        destination_address = string
        destination_ports   = list(string)
        translated_address  = string
        translated_port     = string
      }))
    })), [])
  }))
  description = "Rule collection groups to create on the firewall policy. Mirrors azurerm_firewall_policy_rule_collection_group's schema directly."
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to the firewall, its policy, and its public IPs"
  default     = {}
}
