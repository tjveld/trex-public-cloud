# ==============================================================================
# FortiGate NVA - Hub
# ==============================================================================
# FortiGate-VM router VM (../../modules/fortigate): port1 (external, public
# IP, "mgmt" subnet) + port2 (internal, "firewall" subnet, IP forwarding
# enabled - the sole transit interface).

variable "fortigate_image" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  description = "FortiGate-VM Azure Marketplace image coordinates, single-VM PAYG (hourly) offer, Hyper-V Generation 2"
  # offer = "fortinet_fortigate-vm_v5" is a legacy/renamed id with a broken
  # Marketplace billing backend - use "fortinet_fortigate-vm" instead.
  default = {
    publisher = "fortinet"
    offer     = "fortinet_fortigate-vm"
    sku       = "fortinet_fg-vm_payg_76_g2"
    version   = "latest"
  }
}

# FortiGate-VM + its port1/port2 NICs.
module "fortigate" {
  source = "../../modules/fortigate"

  name                = "vm-${var.environment}-fgt-01"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name

  port1_subnet_id          = module.hub.subnet_ids["mgmt"]
  port1_private_ip_address = cidrhost(module.hub.subnet_address_prefixes["mgmt"][0], 4)
  port2_subnet_id          = module.hub.subnet_ids["firewall"]
  port2_private_ip_address = local.fgt_port2_ip

  # Auto-creates a management NSG on port1 allowing only this address in on
  # SSH (CLI) and HTTPS (GUI).
  management_source_address_prefix = trimspace(data.http.mgmt_from_public_ip.response_body)

  # var.fortigate_image already pins one (payg, Gen2) sku, so it's passed
  # straight through as the module's "payg" entry.
  publisher    = var.fortigate_image.publisher
  offer        = var.fortigate_image.offer
  license_type = "payg"
  fgt_sku      = { payg = var.fortigate_image.sku }
  fgt_version  = var.fortigate_image.version

  # Falsv7 (AMD EPYC, x64) is Gen2-only and supports 2 NICs + accelerated
  # networking, matching var.fortigate_image's Gen2 image.
  size = "Standard_F4als_v7"

  admin_username = var.vm_admin_username
  admin_password = var.vm_admin_password

  # Plain FortiOS CLI bootstrap - the module wraps it in the MIME envelope
  # FortiGate's image requires. Its CLI body is deliberately comment-free.
  bootstrap_config = templatefile("${path.module}/fgt-bootstrap.conf.tftpl", {
    port2_ip      = local.fgt_port2_ip
    port2_netmask = cidrnetmask(module.hub.subnet_address_prefixes["firewall"][0])
    wan_gateway   = cidrhost(module.hub.subnet_address_prefixes["mgmt"][0], 1)
    lan_gateway   = cidrhost(module.hub.subnet_address_prefixes["firewall"][0], 1)
  })

  tags = local.tags
}
