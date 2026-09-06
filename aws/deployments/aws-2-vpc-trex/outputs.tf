# ==============================================================================
# Outputs
# ==============================================================================

output "vpc_subnets" {
  description = "Map of subnet name to ID and CIDR block"
  value = {
    for name, id in module.vpc.subnet_ids : name => {
      id   = id
      cidr = module.vpc.subnet_cidr_blocks[name]
    }
  }
}

output "vm_app_01_private_ip_addresses" {
  description = "Private IP addresses of trex-01's ENIs, keyed by mgmt/trex1/trex2"
  value       = module.vm_app_01.private_ip_addresses
}

output "vm_app_01_fqdn" {
  description = "FQDN of the DNS A record pointing at trex-01's mgmt public IP - use this to connect"
  value       = aws_route53_record.vm_app_01_dns_record.name
}
