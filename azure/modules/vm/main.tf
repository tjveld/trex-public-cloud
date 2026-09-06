# ==============================================================================
# Virtual Machine Module
# ==============================================================================
# Creates one or more NICs (each with an optional public IP and NSG
# association) and a single Linux or Windows VM attached to all of them,
# selected by var.os_type.

locals {
  # Azure determines the primary NIC by position (first = primary), not a
  # separate field - so the primary = true entry goes first.
  nic_keys_ordered = concat(
    [for key, nic in var.network_interfaces : key if nic.primary],
    [for key, nic in var.network_interfaces : key if !nic.primary]
  )
  network_interface_ids = [for key in local.nic_keys_ordered : azurerm_network_interface.this[key].id]

  # NICs needing an auto-created management NSG: public IP but no explicit
  # NSG for that key.
  public_ip_nics_needing_management_nsg = {
    for key, nic in var.network_interfaces : key => nic
    if nic.enable_public_ip && !contains(keys(var.network_security_group_associations), key)
  }
}

resource "azurerm_public_ip" "this" {
  for_each = { for key, nic in var.network_interfaces : key => nic if nic.enable_public_ip }

  name                = "${var.name}-${each.key}-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = each.value.public_ip_sku
  zones               = var.zone != null ? [var.zone] : null
  tags                = var.tags
}

resource "azurerm_network_interface" "this" {
  for_each = var.network_interfaces

  name                           = "${var.name}-${each.key}-nic"
  location                       = var.location
  resource_group_name            = var.resource_group_name
  accelerated_networking_enabled = each.value.enable_accelerated_networking
  ip_forwarding_enabled          = each.value.enable_ip_forwarding
  tags                           = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = each.value.subnet_id
    private_ip_address_allocation = each.value.private_ip_address != null ? "Static" : "Dynamic"
    private_ip_address            = each.value.private_ip_address
    public_ip_address_id          = each.value.enable_public_ip ? azurerm_public_ip.this[each.key].id : null
  }
}

resource "azurerm_network_interface_security_group_association" "this" {
  for_each = var.network_security_group_associations

  network_interface_id      = azurerm_network_interface.this[each.key].id
  network_security_group_id = each.value
}

# Auto-created management NSG for public-IP NICs without an explicit NSG -
# allows only var.management_source_address_prefix in on SSH/RDP/HTTP/HTTPS.
resource "azurerm_network_security_group" "management" {
  for_each = local.public_ip_nics_needing_management_nsg

  name                = "${var.name}-${each.key}-mgmt-nsg"
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
    name                       = "AllowRDPInbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = var.management_source_address_prefix
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHTTPInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = var.management_source_address_prefix
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHTTPSInbound"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.management_source_address_prefix
    destination_address_prefix = "*"
  }

  lifecycle {
    precondition {
      condition     = var.management_source_address_prefix != null
      error_message = "management_source_address_prefix must be set when a network_interfaces entry has enable_public_ip = true and no matching network_security_group_associations entry."
    }
  }
}

resource "azurerm_network_interface_security_group_association" "management" {
  for_each = local.public_ip_nics_needing_management_nsg

  network_interface_id      = azurerm_network_interface.this[each.key].id
  network_security_group_id = azurerm_network_security_group.management[each.key].id
}

resource "azurerm_linux_virtual_machine" "this" {
  count = var.os_type == "Linux" ? 1 : 0

  name                            = var.name
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.size
  zone                            = var.zone
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = var.disable_password_authentication
  network_interface_ids           = local.network_interface_ids
  custom_data                     = var.custom_data != null ? base64encode(var.custom_data) : null
  tags                            = var.tags

  dynamic "admin_ssh_key" {
    for_each = var.admin_ssh_public_key != null ? [var.admin_ssh_public_key] : []
    content {
      username   = var.admin_username
      public_key = admin_ssh_key.value
    }
  }

  os_disk {
    caching              = var.os_disk_caching
    storage_account_type = var.os_disk_storage_account_type
  }

  source_image_reference {
    publisher = var.source_image_reference.publisher
    offer     = var.source_image_reference.offer
    sku       = var.source_image_reference.sku
    version   = var.source_image_reference.version
  }

  # Required for marketplace images with license terms (e.g. VyOS) - must
  # match an agreement already accepted for the subscription.
  dynamic "plan" {
    for_each = var.plan != null ? [var.plan] : []
    content {
      name      = plan.value.name
      publisher = plan.value.publisher
      product   = plan.value.product
    }
  }

  lifecycle {
    precondition {
      condition     = var.disable_password_authentication ? var.admin_ssh_public_key != null : var.admin_password != null
      error_message = "Linux VMs need admin_ssh_public_key when disable_password_authentication is true, or admin_password when it's false."
    }
  }
}

resource "azurerm_windows_virtual_machine" "this" {
  count = var.os_type == "Windows" ? 1 : 0

  name                  = var.name
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = var.size
  zone                  = var.zone
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = local.network_interface_ids
  custom_data           = var.custom_data != null ? base64encode(var.custom_data) : null
  tags                  = var.tags

  os_disk {
    caching              = var.os_disk_caching
    storage_account_type = var.os_disk_storage_account_type
  }

  source_image_reference {
    publisher = var.source_image_reference.publisher
    offer     = var.source_image_reference.offer
    sku       = var.source_image_reference.sku
    version   = var.source_image_reference.version
  }

  lifecycle {
    precondition {
      condition     = var.admin_password != null
      error_message = "Windows VMs require admin_password to be set."
    }
  }
}
