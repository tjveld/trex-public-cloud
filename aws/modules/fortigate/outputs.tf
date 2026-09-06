output "instance_id" {
  description = "ID of the FortiGate EC2 instance"
  value       = module.vm.instance_id
}

output "name" {
  description = "Name of the FortiGate EC2 instance"
  value       = module.vm.name
}

output "port1_eni_id" {
  description = "ID of port1's (external) ENI"
  value       = module.vm.eni_ids["port1"]
}

output "port2_eni_id" {
  description = "ID of port2's (internal) ENI"
  value       = module.vm.eni_ids["port2"]
}

output "port1_public_ip" {
  description = "Elastic IP address of port1"
  value       = module.vm.public_ip_addresses["port1"]
}

output "port1_private_ip" {
  description = "Private IP address of port1"
  value       = module.vm.private_ip_addresses["port1"]
}

output "port2_private_ip" {
  description = "Private IP address of port2"
  value       = module.vm.private_ip_addresses["port2"]
}

output "management_security_group_id" {
  description = "ID of the auto-created management security group on port1"
  value       = aws_security_group.management.id
}
