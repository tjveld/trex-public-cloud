# ==============================================================================
# VyOS NVA - Hub
# ==============================================================================
# VyOS router VM: wan (public IP, "mgmt" subnet) + lan1 ("firewall" subnet,
# IP forwarding enabled - the sole transit interface).

variable "vyos_image" {
  type = object({
    publisher = string
    offer     = string
    sku       = string
    version   = string
  })
  description = "VyOS Azure Marketplace image coordinates, PAYG VyOS Universal Router with Standard Support offer"
  default = {
    publisher = "sentriumsl"
    offer     = "vyos-1-2-lts-on-azure"
    sku       = "vyos-1-3"
    version   = "latest"
  }
}

# One-time marketplace terms acceptance, required before a VM can use this
# image. Tracked per (publisher, offer, plan) at the subscription level.
resource "azurerm_marketplace_agreement" "vyos" {
  publisher = var.vyos_image.publisher
  offer     = var.vyos_image.offer
  plan      = var.vyos_image.sku
}

# VyOS VM: wan (public IP) + lan1 (data-plane) NICs.
module "vyos" {
  source = "../../modules/vm"

  name                = "vm-${var.environment}-vyos-01"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name

  network_interfaces = {
    wan = {
      subnet_id            = module.hub.subnet_ids["mgmt"]
      private_ip_address   = cidrhost(module.hub.subnet_address_prefixes["mgmt"][0], 4)
      enable_ip_forwarding = false
      enable_public_ip     = true
      primary              = true
    }
    lan1 = {
      subnet_id            = module.hub.subnet_ids["firewall"]
      private_ip_address   = local.vyos_lan1_ip
      enable_ip_forwarding = true
    }
  }

  # No explicit NSG for "wan" - auto-created, SSH only (VyOS's management
  # port) from this address.
  management_source_address_prefix = trimspace(data.http.mgmt_from_public_ip.response_body)

  size    = "Standard_F2als_v7"
  os_type = "Linux"

  source_image_reference = {
    publisher = var.vyos_image.publisher
    offer     = var.vyos_image.offer
    sku       = var.vyos_image.sku
    version   = var.vyos_image.version
  }

  plan = {
    name      = var.vyos_image.sku
    publisher = var.vyos_image.publisher
    product   = var.vyos_image.offer
  }

  admin_username = var.vm_admin_username
  admin_password = var.vm_admin_password

  # First-boot interface/route bootstrap.
  custom_data = templatefile("${path.module}/vyos-config.sh.tftpl", {
    wan_gateway  = cidrhost(module.hub.subnet_address_prefixes["mgmt"][0], 1)
    lan1_gateway = cidrhost(module.hub.subnet_address_prefixes["firewall"][0], 1)
  })

  tags = local.tags

  depends_on = [azurerm_marketplace_agreement.vyos]
}
