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

output "fgt_port2_ip" {
  description = "Static private IP of FortiGate's port2 (internal) NIC - the next_hop_in_ip_address used by the spoke route tables"
  value       = local.fgt_port2_ip
}

output "vm_app_01_private_ip_addresses" {
  description = "Private IP addresses of app-01's NICs, keyed by mgmt/data"
  value       = module.vm_app_01.private_ip_addresses
}

#output "vm_app_01_fqdn" {
#  description = "FQDN of the DNS A record pointing at app-01's mgmt public IP - use this to connect"
#  value       = "${azapi_resource.vm_app_01_dns_record.name}.${var.dns_zone_name}"
#}

#output "fortigate_fqdn" {
#  description = "FQDN of the DNS A record pointing at FortiGate's port1 public IP - use this to connect"
#  value       = "${azapi_resource.fortigate_dns_record.name}.${var.dns_zone_name}"
#}

output "fortigate_public_ip" {
  description = "Public IP address of FortiGate's port1 - also the CN/SAN on FortiOS's self-signed admin UI certificate"
  value       = module.fortigate.port1_public_ip
}
