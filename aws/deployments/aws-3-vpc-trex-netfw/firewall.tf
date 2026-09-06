# ==============================================================================
# AWS Network Firewall - Hub
# ==============================================================================
# Native AWS Network Firewall in place of an NVA. Sits in the "firewall"
# subnet; its endpoint ID is the vpc_endpoint target wired into main.tf's
# routes for app-01/app-02.
#
# A policy with stateless_default_actions = ["aws:forward_to_sfe"] and no
# matching stateful rule falls through to DROP, so local.default_rule_groups
# ships a default allowing TRex client -> server traffic.

variable "firewall_rule_groups" {
  type        = any
  description = <<-EOT
    Stateful rule groups to create on the firewall policy. Left null (the
    default) to use local.default_rule_groups. Pass your own map to replace it.
  EOT
  default     = null
}

locals {
  # Default for module "firewall"'s rule_groups: allows TRex client ->
  # server traffic only. Without this, the policy's DROP default blocks it.
  default_rule_groups = {
    "clients-to-servers" = {
      capacity = 100
      stateful_rules = [
        {
          action           = "PASS"
          protocol         = "TCP"
          source           = local.trex_client_subnet
          destination      = local.trex_server_subnet
          destination_port = "[21,23,25,53,443,445,1935]"
          rule_options     = [{ keyword = "sid:1" }]
        },
        {
          action           = "PASS"
          protocol         = "UDP"
          source           = local.trex_client_subnet
          destination      = local.trex_server_subnet
          destination_port = "[12,53,1212]"
          rule_options     = [{ keyword = "sid:2" }]
        },
        {
          action       = "PASS"
          protocol     = "ICMP"
          source       = local.trex_client_subnet
          destination  = local.trex_server_subnet
          rule_options = [{ keyword = "sid:3" }]
        },
      ]
    }

    # HTTP (80/8080/8081) matches on Suricata's HTTP app-layer protocol
    # rather than raw TCP. 443 stays on the plain TCP rule above, since
    # TRex's test traffic carries no valid TLS certificate to match on.
    "web-filtering" = {
      capacity = 100
      stateful_rules = [
        {
          action           = "PASS"
          protocol         = "HTTP"
          source           = local.trex_client_subnet
          destination      = local.trex_server_subnet
          destination_port = "[80,8080,8081]"
          rule_options     = [{ keyword = "sid:4" }]
        },
      ]
    }
  }
}

# AWS Network Firewall + its auto-created policy, in the "firewall" subnet.
module "firewall" {
  source = "../../modules/firewall"

  name                = "netfw-${var.environment}"
  vpc_id              = module.hub.vpc_id
  firewall_subnet_ids = [module.hub.subnet_ids["firewall"]]
  tags                = local.tags

  rule_groups = coalesce(var.firewall_rule_groups, local.default_rule_groups)
}
