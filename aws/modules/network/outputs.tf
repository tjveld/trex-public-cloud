output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "Primary CIDR block of the VPC"
  value       = aws_vpc.this.cidr_block
}

output "vpc_secondary_cidr_blocks" {
  description = "Associated secondary CIDR blocks, if any"
  value       = [for assoc in aws_vpc_ipv4_cidr_block_association.this : assoc.cidr_block]
}

output "internet_gateway_id" {
  description = "ID of the VPC's Internet Gateway"
  value       = aws_internet_gateway.this.id
}

output "subnet_ids" {
  description = "Map of subnet name to subnet ID"
  value       = { for name, subnet in aws_subnet.this : name => subnet.id }
}

output "subnet_cidr_blocks" {
  description = "Map of subnet name to its CIDR block - for cidrhost()/cidrsubnet() calls in callers."
  value       = { for name, subnet in aws_subnet.this : name => subnet.cidr_block }
}
