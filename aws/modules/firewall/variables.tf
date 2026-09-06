variable "name" {
  type        = string
  description = "Name of the AWS Network Firewall. Also used to derive the firewall policy's and each rule group's names."
}

variable "vpc_id" {
  type        = string
  description = "VPC to deploy the firewall into"
}

variable "firewall_subnet_ids" {
  type        = list(string)
  description = "Subnet(s) to deploy Network Firewall endpoints into, one per AZ."

  validation {
    condition     = length(var.firewall_subnet_ids) > 0
    error_message = "At least one firewall subnet must be supplied."
  }
}

variable "rule_groups" {
  type = map(object({
    capacity = number
    stateful_rules = list(object({
      action           = string # PASS, DROP, ALERT, or REJECT
      protocol         = string # e.g. "IP", "TCP", "UDP", "ICMP"
      source           = string # CIDR, or "ANY"
      source_port      = optional(string, "ANY")
      destination      = string # CIDR, or "ANY"
      destination_port = optional(string, "ANY")
      direction        = optional(string, "FORWARD") # "FORWARD" or "ANY"
      rule_options = optional(list(object({
        keyword  = string
        settings = optional(list(string))
      })), [])
    }))
  }))
  description = <<-EOT
    Stateful rule groups to create, keyed by a short name. capacity must be
    set explicitly and can't change without replacing the rule group.
  EOT
  default     = {}
}

variable "firewall_policy_arn" {
  type        = string
  description = "ARN of an existing firewall policy to attach instead of creating one. Leave null (the default) to have this module create a dedicated policy from rule_groups."
  default     = null
}

variable "stateless_default_actions" {
  type        = list(string)
  description = "Default actions for traffic that doesn't match a stateless rule. \"aws:forward_to_sfe\" sends everything to rule_groups. Ignored when firewall_policy_arn is set."
  default     = ["aws:forward_to_sfe"]
}

variable "stateless_fragment_default_actions" {
  type        = list(string)
  description = "Same as stateless_default_actions, for fragmented packets - required by AWS even when identical. Ignored when firewall_policy_arn is set."
  default     = ["aws:forward_to_sfe"]
}

variable "delete_protection" {
  type        = bool
  description = "Whether to block deletion of the firewall via the AWS API/console."
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Tags to apply to the firewall, its policy, and its rule groups"
  default     = {}
}
