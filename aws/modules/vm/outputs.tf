output "instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.this.id
}

output "name" {
  description = "Name of the EC2 instance (var.name passed through)"
  value       = var.name
}

output "eni_ids" {
  description = "Map of network_interfaces key to that ENI's ID"
  value       = { for key, eni in aws_network_interface.this : key => eni.id }
}

output "private_ip_addresses" {
  description = "Map of network_interfaces key to that ENI's private IP address"
  value       = { for key, eni in aws_network_interface.this : key => eni.private_ip }
}

output "public_ip_addresses" {
  description = "Map of network_interfaces key to that ENI's Elastic IP address, for ENIs with enable_public_ip"
  value       = { for key, eip in aws_eip.this : key => eip.public_ip }
}

output "primary_eni_id" {
  description = "ID of the primary ENI (device_index 0)"
  value       = aws_network_interface.this[local.nic_keys_ordered[0]].id
}

output "primary_private_ip_address" {
  description = "Private IP address of the primary ENI"
  value       = aws_network_interface.this[local.nic_keys_ordered[0]].private_ip
}

output "management_security_group_ids" {
  description = "Map of network_interfaces key to the auto-created management security group's ID, for public-IP ENIs that didn't get an explicit security_group_ids entry"
  value       = { for key, sg in aws_security_group.management : key => sg.id }
}
