output "vm_id" {
  description = "ID of the virtual machine"
  value       = var.os_type == "Linux" ? azurerm_linux_virtual_machine.this[0].id : azurerm_windows_virtual_machine.this[0].id
}

output "vm_name" {
  description = "Name of the virtual machine"
  value       = var.os_type == "Linux" ? azurerm_linux_virtual_machine.this[0].name : azurerm_windows_virtual_machine.this[0].name
}

output "nic_ids" {
  description = "Map of network_interfaces key to that NIC's ID"
  value       = { for key, nic in azurerm_network_interface.this : key => nic.id }
}

output "private_ip_addresses" {
  description = "Map of network_interfaces key to that NIC's private IP address"
  value       = { for key, nic in azurerm_network_interface.this : key => nic.private_ip_address }
}

output "public_ip_addresses" {
  description = "Map of network_interfaces key to that NIC's public IP address, for NICs with enable_public_ip"
  value       = { for key, pip in azurerm_public_ip.this : key => pip.ip_address }
}

output "primary_nic_id" {
  description = "ID of the primary NIC"
  value       = azurerm_network_interface.this[local.nic_keys_ordered[0]].id
}

output "primary_private_ip_address" {
  description = "Private IP address of the primary NIC"
  value       = azurerm_network_interface.this[local.nic_keys_ordered[0]].private_ip_address
}

output "management_nsg_ids" {
  description = "Map of network_interfaces key to the auto-created management NSG's ID, for public-IP NICs that didn't get an explicit NSG"
  value       = { for key, nsg in azurerm_network_security_group.management : key => nsg.id }
}
