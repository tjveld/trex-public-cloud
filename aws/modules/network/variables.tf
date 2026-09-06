variable "name" {
  type        = string
  description = "Name of the VPC (applied as its Name tag)"
}

variable "cidr_blocks" {
  type        = list(string)
  description = "CIDR block(s) for the VPC - first entry is primary (immutable); further entries are associated as secondary CIDR blocks."

  validation {
    condition     = length(var.cidr_blocks) > 0
    error_message = "At least one CIDR block must be provided."
  }
}

variable "subnets" {
  type = map(object({
    cidr_block        = string
    availability_zone = optional(string)
  }))
  description = "Subnets to create, keyed by name. AWS subnets are zonal - leave availability_zone null to let AWS pick, or pin it for HA across AZs."
  default     = {}
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to the VPC, its subnets, and the Internet Gateway"
  default     = {}
}
