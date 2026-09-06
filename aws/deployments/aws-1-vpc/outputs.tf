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
