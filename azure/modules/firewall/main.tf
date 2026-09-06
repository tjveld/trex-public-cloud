# ==============================================================================
# Azure Firewall Module
# ==============================================================================
# Creates a native Azure Firewall plus, by default, a dedicated firewall
# policy and its rule collection groups. Deploys into an existing
# "AzureFirewallSubnet" (Azure's required exact name), taking its ID rather
# than creating it.

locals {
  primary_public_ip_key = [for key, cfg in var.public_ip_configurations : key if cfg.primary][0]
  zones                 = length(var.zones) > 0 ? var.zones : null

  # Attach to the supplied policy if given, otherwise the one this module creates.
  firewall_policy_id = coalesce(var.firewall_policy_id, try(azurerm_firewall_policy.this[0].id, null))
}

resource "azurerm_public_ip" "this" {
  for_each = var.public_ip_configurations

  name                = "${var.name}-${each.key}-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = local.zones
  tags                = var.tags
}

resource "azurerm_firewall_policy" "this" {
  count = var.firewall_policy_id == null ? 1 : 0

  name                     = "${var.name}-policy"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  sku                      = var.sku_tier
  threat_intelligence_mode = var.threat_intelligence_mode
  tags                     = var.tags

  # Plain top-level argument, not a nested block - azurerm_firewall_policy
  private_ip_ranges = var.snat_private_ip_ranges

  dynamic "dns" {
    for_each = var.dns_servers != null ? [var.dns_servers] : []
    content {
      servers       = dns.value
      proxy_enabled = var.dns_proxy_enabled
    }
  }
}

resource "azurerm_firewall" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  sku_name            = var.sku_name
  sku_tier            = var.sku_tier
  firewall_policy_id  = local.firewall_policy_id
  zones               = local.zones
  tags                = var.tags

  dynamic "ip_configuration" {
    for_each = var.public_ip_configurations
    content {
      name = ip_configuration.key
      # Only the primary configuration may carry subnet_id - Azure rejects the request if a second one also sets it.
      subnet_id            = ip_configuration.key == local.primary_public_ip_key ? var.firewall_subnet_id : null
      public_ip_address_id = azurerm_public_ip.this[ip_configuration.key].id
    }
  }
}

resource "azurerm_firewall_policy_rule_collection_group" "this" {
  for_each = { for group in var.rule_collection_groups : group.name => group }

  name               = each.value.name
  firewall_policy_id = local.firewall_policy_id
  priority           = each.value.priority

  dynamic "application_rule_collection" {
    for_each = each.value.application_rule_collections
    content {
      name     = application_rule_collection.value.name
      action   = application_rule_collection.value.action
      priority = application_rule_collection.value.priority

      dynamic "rule" {
        for_each = application_rule_collection.value.rules
        content {
          name                  = rule.value.name
          source_addresses      = rule.value.source_addresses
          source_ip_groups      = rule.value.source_ip_groups
          destination_fqdns     = rule.value.destination_fqdns
          destination_fqdn_tags = rule.value.destination_fqdn_tags

          dynamic "protocols" {
            for_each = rule.value.protocols
            content {
              type = protocols.value.type
              port = protocols.value.port
            }
          }
        }
      }
    }
  }

  dynamic "network_rule_collection" {
    for_each = each.value.network_rule_collections
    content {
      name     = network_rule_collection.value.name
      action   = network_rule_collection.value.action
      priority = network_rule_collection.value.priority

      dynamic "rule" {
        for_each = network_rule_collection.value.rules
        content {
          name                  = rule.value.name
          protocols             = rule.value.protocols
          source_addresses      = rule.value.source_addresses
          source_ip_groups      = rule.value.source_ip_groups
          destination_addresses = rule.value.destination_addresses
          destination_ip_groups = rule.value.destination_ip_groups
          destination_fqdns     = rule.value.destination_fqdns
          destination_ports     = rule.value.destination_ports
        }
      }
    }
  }

  dynamic "nat_rule_collection" {
    for_each = each.value.nat_rule_collections
    content {
      name     = nat_rule_collection.value.name
      action   = nat_rule_collection.value.action
      priority = nat_rule_collection.value.priority

      dynamic "rule" {
        for_each = nat_rule_collection.value.rules
        content {
          name                = rule.value.name
          protocols           = rule.value.protocols
          source_addresses    = rule.value.source_addresses
          source_ip_groups    = rule.value.source_ip_groups
          destination_address = rule.value.destination_address
          destination_ports   = rule.value.destination_ports
          translated_address  = rule.value.translated_address
          translated_port     = rule.value.translated_port
        }
      }
    }
  }
}
