# ==============================================================================
# Azure Firewall - Hub
# ==============================================================================
# Native Azure Firewall in place of an NVA. Sits in AzureFirewallSubnet; its
# private IP is the next_hop_in_ip_address wired into main.tf's routes.

variable "firewall_rule_collection_groups" {
  type        = any
  description = <<-EOT
    Rule collection groups for the firewall policy. If null, defaults to
    local.default_firewall_rule_collection_groups.
  EOT
  default     = null
}

# Azure Firewall + its auto-created policy, in AzureFirewallSubnet.
module "firewall" {
  source = "../../modules/firewall"

  name                = "azfw-${var.environment}-hub"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  firewall_subnet_id  = module.hub.subnet_ids["AzureFirewallSubnet"]

  # Premium required for TLS inspection/IDPS; module.firewall ties the
  # auto-created policy's sku to this same value.
  sku_name = "AZFW_VNet"
  sku_tier = "Standard"

  threat_intelligence_mode = "Alert"

  # TRex's spoofed ranges aren't RFC1918, so Azure Firewall SNATs them to
  # its own IP by default - excluded here so the server sees the real client IP.
  snat_private_ip_ranges = concat(
    local.default_snat_private_ip_ranges,
    [local.trex_client_subnet, local.trex_server_subnet, "21.0.0.0/29", "22.0.0.0/29"]
  )

  tags = local.tags

  rule_collection_groups = coalesce(
    var.firewall_rule_collection_groups,
    local.default_firewall_rule_collection_groups
  )

  # Same ordering requirement as module "hub" - the mandatory default route
  # must exist first.
  depends_on = [azurerm_route.hub_azfw_default_to_internet]
}

# Full resource ID, not a name lookup - no subscription_id is pinned, so a
# name lookup would resolve against whatever subscription is active. No default.
variable "log_analytics_workspace_id" {
  type        = string
  description = "Resource ID of the existing Log Analytics workspace diagnostic logs are sent to"
}

# Resource-specific table logs, not the legacy shared AzureDiagnostics table -
# queryable as their own AZFWNetworkRule/AZFWApplicationRule tables.
resource "azurerm_monitor_diagnostic_setting" "firewall" {
  name                       = "diag-${var.environment}-azfw"
  target_resource_id         = module.firewall.firewall_id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "AZFWNetworkRule"
  }

  enabled_log {
    category = "AZFWApplicationRule"
  }
}
