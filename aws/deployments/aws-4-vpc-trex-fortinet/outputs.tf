# ==============================================================================
# Outputs
# ==============================================================================

output "hub_subnets" {
  description = "Map of subnet name to ID and CIDR block"
  value = {
    for name, id in module.hub.subnet_ids : name => {
      id   = id
      cidr = module.hub.subnet_cidr_blocks[name]
    }
  }
}

output "vm_app_01_private_ip_addresses" {
  description = "Private IP addresses of trex-01's ENIs, keyed by mgmt/trex1/trex2"
  value       = module.vm_app_01.private_ip_addresses
}

output "fortinet_private_ip_addresses" {
  description = "Private IP addresses of the FortiGate's ENIs, keyed by port1/port2 - port2 is the next_hop_in_ip_address used by the spoke route tables"
  value = {
    port1 = module.fortigate.port1_private_ip
    port2 = module.fortigate.port2_private_ip
  }
}

output "vm_app_01_fqdn" {
  description = "FQDN of the DNS A record pointing at trex-01's mgmt public IP - use this to connect"
  value       = aws_route53_record.vm_app_01_dns_record.name
}

output "fortinet_fqdn" {
  description = "FQDN of the DNS A record pointing at FortiGate's port1 public IP - use this to connect"
  value       = aws_route53_record.fortigate_dns_record.name
}

output "fortinet_instance_id" {
  description = "ID of the FortiGate EC2 instance"
  value       = module.fortigate.instance_id
}

output "fortinet_public_ip" {
  description = "Elastic IP address of FortiGate's port1 - also the CN/SAN on FortiOS's self-signed admin UI certificate"
  value       = module.fortigate.port1_public_ip
}
