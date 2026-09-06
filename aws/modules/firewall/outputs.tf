output "firewall_id" {
  description = "ID of the AWS Network Firewall"
  value       = aws_networkfirewall_firewall.this.id
}

output "firewall_arn" {
  description = "ARN of the AWS Network Firewall"
  value       = aws_networkfirewall_firewall.this.arn
}

output "firewall_policy_arn" {
  description = "ARN of the policy in effect - created by this module, or var.firewall_policy_arn"
  value       = coalesce(var.firewall_policy_arn, try(aws_networkfirewall_firewall_policy.this[0].arn, null))
}

output "rule_group_arns" {
  description = "Map of rule_groups key to that rule group's ARN"
  value       = { for key, rg in aws_networkfirewall_rule_group.this : key => rg.arn }
}

# One VPC endpoint per subnet in firewall_subnet_ids (one per AZ) - each
# protected subnet's route table must target the endpoint in its own AZ.
output "endpoint_ids_by_subnet" {
  description = "Map of firewall subnet ID to that subnet's VPC endpoint ID - use as target_id for a \"vpc_endpoint\" route."
  value = {
    for state in aws_networkfirewall_firewall.this.firewall_status[0].sync_states :
    state.attachment[0].subnet_id => state.attachment[0].endpoint_id
  }
}
