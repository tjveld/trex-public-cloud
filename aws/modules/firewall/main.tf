# ==============================================================================
# AWS Network Firewall Module
# ==============================================================================
# Creates one or more stateful rule groups, a firewall policy referencing
# them, and the AWS Network Firewall itself, deployed into caller-supplied
# firewall subnet(s) (one per AZ).

resource "aws_networkfirewall_rule_group" "this" {
  for_each = var.rule_groups

  name     = "${var.name}-${each.key}"
  type     = "STATEFUL"
  capacity = each.value.capacity
  tags     = var.tags

  rule_group {
    rules_source {
      dynamic "stateful_rule" {
        for_each = each.value.stateful_rules
        content {
          action = stateful_rule.value.action

          header {
            protocol         = stateful_rule.value.protocol
            source           = stateful_rule.value.source
            source_port      = stateful_rule.value.source_port
            destination      = stateful_rule.value.destination
            destination_port = stateful_rule.value.destination_port
            direction        = stateful_rule.value.direction
          }

          dynamic "rule_option" {
            for_each = stateful_rule.value.rule_options
            content {
              keyword  = rule_option.value.keyword
              settings = rule_option.value.settings
            }
          }
        }
      }
    }
  }
}

# Only created when var.firewall_policy_arn isn't already supplying one -
# lets multiple firewalls share a single policy.
resource "aws_networkfirewall_firewall_policy" "this" {
  count = var.firewall_policy_arn == null ? 1 : 0

  name = "${var.name}-policy"
  tags = var.tags

  firewall_policy {
    stateless_default_actions          = var.stateless_default_actions
    stateless_fragment_default_actions = var.stateless_fragment_default_actions

    dynamic "stateful_rule_group_reference" {
      for_each = aws_networkfirewall_rule_group.this
      content {
        resource_arn = stateful_rule_group_reference.value.arn
      }
    }
  }
}

resource "aws_networkfirewall_firewall" "this" {
  name                = var.name
  vpc_id              = var.vpc_id
  firewall_policy_arn = coalesce(var.firewall_policy_arn, try(aws_networkfirewall_firewall_policy.this[0].arn, null))
  delete_protection   = var.delete_protection
  tags                = var.tags

  dynamic "subnet_mapping" {
    for_each = var.firewall_subnet_ids
    content {
      subnet_id = subnet_mapping.value
    }
  }
}
