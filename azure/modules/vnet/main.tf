# ==============================================================================
# Virtual Network Module
# ==============================================================================
# Creates a virtual network with an arbitrary set of subnets, optionally
# associating subnets with a network security group and/or route table via
# separate maps keyed on subnet name (not yet-unknown resource IDs).

resource "azurerm_virtual_network" "this" {
  name                = var.name
  address_space       = var.address_space
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_subnet" "this" {
  for_each             = var.subnets
  name                 = each.key
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = each.value.address_prefixes
}

resource "azurerm_subnet_network_security_group_association" "this" {
  for_each = var.network_security_group_associations

  subnet_id                 = azurerm_subnet.this[each.key].id
  network_security_group_id = each.value
}

resource "azurerm_subnet_route_table_association" "this" {
  for_each = var.route_table_associations

  subnet_id      = azurerm_subnet.this[each.key].id
  route_table_id = each.value
}
