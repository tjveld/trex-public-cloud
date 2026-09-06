# ==============================================================================
# Outputs
# ==============================================================================

output "hub_subnets" {
  description = "Hub subnet IDs and addresses"
  value       = module.hub.subnets
}

output "spoke_1_subnets" {
  description = "Spoke 1 subnet IDs and addresses"
  value       = module.spoke_1.subnets
}

output "vm_app_01_private_ip_addresses" {
  description = "Private IP addresses of app-01's NICs, keyed by mgmt/data"
  value       = module.vm_app_01.private_ip_addresses
}

output "vm_app_01_fqdn" {
  description = "FQDN of the DNS A record pointing at app-01's mgmt public IP - use this to connect"
  value       = "${azapi_resource.vm_app_01_dns_record.name}.${var.dns_zone_name}"
}
