# ==============================================================================
# FortiGate-VM Module
# ==============================================================================
# Single-VM FortiGate NVA: a fixed port1 (external, public IP, management
# NSG)/port2 (internal, IP forwarding enabled) NIC pair, a marketplace
# agreement for the licensed image, the VM itself, and an optional dedicated
# log data disk.

locals {
  fgt_sku = var.fgt_sku[var.license_type]

  # FortiGate's Azure marketplace image only picks up custom_data if it's
  # wrapped in this multipart MIME envelope - a bare CLI script is silently
  # ignored.
  bootstrap_mime = var.bootstrap_config == null ? null : <<-EOT
    Content-Type: multipart/mixed; boundary="==AZURE=="
    MIME-Version: 1.0

    --==AZURE==
    Content-Type: text/x-shellscript; charset="us-ascii"
    MIME-Version: 1.0

    ${var.bootstrap_config}

    --==AZURE==--
  EOT
}

# One-time marketplace terms acceptance, required before a VM can use this
# image. Tracked per (publisher, offer, plan) at the subscription level.
resource "azurerm_marketplace_agreement" "this" {
  publisher = var.publisher
  offer     = var.offer
  plan      = local.fgt_sku
}

resource "azurerm_public_ip" "port1" {
  name                = "${var.name}-port1-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# Scopes inbound access on port1 to var.management_source_address_prefix -
# SSH (22) for the CLI, HTTPS (443) for the GUI.
resource "azurerm_network_security_group" "management" {
  name                = "${var.name}-mgmt-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  security_rule {
    name                       = "AllowSSHInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.management_source_address_prefix
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHTTPSInbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.management_source_address_prefix
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "port1" {
  name                = "${var.name}-port1-nic"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.port1_subnet_id
    private_ip_address_allocation = var.port1_private_ip_address != null ? "Static" : "Dynamic"
    private_ip_address            = var.port1_private_ip_address
    public_ip_address_id          = azurerm_public_ip.port1.id
  }
}

resource "azurerm_network_interface_security_group_association" "port1" {
  network_interface_id      = azurerm_network_interface.port1.id
  network_security_group_id = azurerm_network_security_group.management.id
}

# port2 is FortiGate's transit interface - IP forwarding enabled so it
# forwards traffic not addressed to itself.
resource "azurerm_network_interface" "port2" {
  name                  = "${var.name}-port2-nic"
  location              = var.location
  resource_group_name   = var.resource_group_name
  ip_forwarding_enabled = true
  tags                  = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.port2_subnet_id
    private_ip_address_allocation = var.port2_private_ip_address != null ? "Static" : "Dynamic"
    private_ip_address            = var.port2_private_ip_address
  }
}

resource "azurerm_linux_virtual_machine" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.size
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  tags                = var.tags

  # Azure determines the primary NIC by list order - port1 (external)
  # leads, matching upstream's primary_network_interface_id.
  network_interface_ids = [
    azurerm_network_interface.port1.id,
    azurerm_network_interface.port2.id,
  ]

  disable_password_authentication = false

  custom_data = local.bootstrap_mime != null ? base64encode(local.bootstrap_mime) : null

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_storage_account_type
  }

  source_image_reference {
    publisher = var.publisher
    offer     = var.offer
    sku       = local.fgt_sku
    version   = var.fgt_version
  }

  # Required for marketplace images with license terms - must match the
  # agreement above (azurerm_marketplace_agreement.this).
  plan {
    name      = local.fgt_sku
    publisher = var.publisher
    product   = var.offer
  }

  depends_on = [azurerm_marketplace_agreement.this]
}

# Dedicated log disk, at LUN 0.
resource "azurerm_managed_disk" "log" {
  count = var.log_disk_size_gb != null ? 1 : 0

  name                 = "${var.name}-log-disk"
  location             = var.location
  resource_group_name  = var.resource_group_name
  storage_account_type = var.log_disk_storage_account_type
  create_option        = "Empty"
  disk_size_gb         = var.log_disk_size_gb
  tags                 = var.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "log" {
  count = var.log_disk_size_gb != null ? 1 : 0

  managed_disk_id    = azurerm_managed_disk.log[0].id
  virtual_machine_id = azurerm_linux_virtual_machine.this.id
  lun                = 0
  # "None" rather than the os_disk-style "ReadWrite" - host caching doesn't
  # suit a write-heavy, rarely-reread log volume.
  caching = "None"
}
