output "firewall_id" {
  description = "ID of the Azure Firewall"
  value       = azurerm_firewall.this.id
}

output "firewall_name" {
  description = "Name of the Azure Firewall"
  value       = azurerm_firewall.this.name
}

output "private_ip_address" {
  description = "Private IP address of the firewall's primary ip_configuration - the address spokes' route tables should use as next_hop_in_ip_address."
  value       = [for cfg in azurerm_firewall.this.ip_configuration : cfg.private_ip_address if cfg.name == local.primary_public_ip_key][0]
}

output "public_ip_ids" {
  description = "Map of public_ip_configurations key to that public IP's ID"
  value       = { for key, pip in azurerm_public_ip.this : key => pip.id }
}

output "public_ip_addresses" {
  description = "Map of public_ip_configurations key to that public IP's address"
  value       = { for key, pip in azurerm_public_ip.this : key => pip.ip_address }
}

output "firewall_policy_id" {
  description = "ID of the firewall policy in effect - either the one this module created, or var.firewall_policy_id when that was supplied"
  value       = local.firewall_policy_id
}
