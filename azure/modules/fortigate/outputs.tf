output "vm_id" {
  description = "ID of the FortiGate virtual machine"
  value       = azurerm_linux_virtual_machine.this.id
}

output "vm_name" {
  description = "Name of the FortiGate virtual machine"
  value       = azurerm_linux_virtual_machine.this.name
}

output "port1_nic_id" {
  description = "ID of port1's (external) NIC"
  value       = azurerm_network_interface.port1.id
}

output "port2_nic_id" {
  description = "ID of port2's (internal) NIC"
  value       = azurerm_network_interface.port2.id
}

output "port1_public_ip" {
  description = "Public IP address of port1"
  value       = azurerm_public_ip.port1.ip_address
}

output "port1_private_ip" {
  description = "Private IP address of port1"
  value       = azurerm_network_interface.port1.private_ip_address
}

output "port2_private_ip" {
  description = "Private IP address of port2"
  value       = azurerm_network_interface.port2.private_ip_address
}

output "management_nsg_id" {
  description = "ID of the auto-created management NSG on port1"
  value       = azurerm_network_security_group.management.id
}

output "log_disk_id" {
  description = "ID of the log data disk, if var.log_disk_size_gb is set"
  value       = try(azurerm_managed_disk.log[0].id, null)
}
