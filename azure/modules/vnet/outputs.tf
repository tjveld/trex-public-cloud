output "vnet_id" {
  description = "ID of the virtual network"
  value       = azurerm_virtual_network.this.id
}

output "vnet_name" {
  description = "Name of the virtual network"
  value       = azurerm_virtual_network.this.name
}

output "subnet_ids" {
  description = "Map of subnet name to subnet ID"
  value       = { for name, subnet in azurerm_subnet.this : name => subnet.id }
}

output "subnets" {
  description = "Map of subnet name to subnet ID and address prefixes"
  value = {
    for name, subnet in azurerm_subnet.this : name => {
      id               = subnet.id
      address_prefixes = subnet.address_prefixes
    }
  }
}

output "subnet_address_prefixes" {
  description = "Map of subnet name to its full list of address prefixes - for cidrhost()/cidrsubnet() calls in callers."
  value       = { for name, subnet in azurerm_subnet.this : name => subnet.address_prefixes }
}
