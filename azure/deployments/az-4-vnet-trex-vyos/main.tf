
# Caller's public IP - scopes management access to just this address.
data "http" "mgmt_from_public_ip" {
  url = "https://api.ipify.org?format=text"
}

# ==============================================================================
# Resource Groups
# ==============================================================================

# Holds the hub VNet, VyOS, and their route tables.
resource "azurerm_resource_group" "hub" {
  name     = "${var.project_name}-${var.environment}-hub"
  location = var.location
  tags     = local.tags
}

# Holds the spoke VNet, trex VM, and its route tables.
resource "azurerm_resource_group" "spoke_1" {
  name     = "${var.project_name}-${var.environment}-spoke-1"
  location = var.location
  tags     = local.tags
}

# ==============================================================================
# Route Tables
# ==============================================================================

# Default route table for hub subnets other than "firewall".
resource "azurerm_route_table" "hub_rt" {
  name                = "udr-${var.environment}-hub"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  tags                = local.tags
}

# Dedicated table for the "firewall" subnet (VyOS's lan1 NIC), separate from
# hub_rt so these two routes don't also apply to "mgmt".
resource "azurerm_route_table" "hub_fw_rt" {
  name                = "udr-${var.environment}-hub-firewall"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  tags                = local.tags
}

# Forward TRex traffic from VyOS's lan1 on to the other trex NIC - works
# via enable_ip_forwarding = true on trex1/trex2.
resource "azurerm_route" "hub_fw_to_trex1" {
  name                   = "trex-clients-via-firewall"
  resource_group_name    = azurerm_resource_group.hub.name
  route_table_name       = azurerm_route_table.hub_fw_rt.name
  address_prefix         = "16.0.0.0/8"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = cidrhost(module.spoke_1.subnet_address_prefixes["snet-app-01"][0], 10)
}

# Return direction of hub_fw_to_trex1, toward trex2.
resource "azurerm_route" "hub_fw_to_trex2" {
  name                   = "trex-servers-via-firewall"
  resource_group_name    = azurerm_resource_group.hub.name
  route_table_name       = azurerm_route_table.hub_fw_rt.name
  address_prefix         = "48.0.0.0/8"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = cidrhost(module.spoke_1.subnet_address_prefixes["snet-app-02"][0], 10)
}

# TRex data-port ranges (distinct from the spoofed ranges above) - data
# port 0 via trex1, data port 1 via trex2.
resource "azurerm_route" "hub_fw_to_trex_data_port0" {
  name                   = "trex-data-port0-via-firewall"
  resource_group_name    = azurerm_resource_group.hub.name
  route_table_name       = azurerm_route_table.hub_fw_rt.name
  address_prefix         = "21.0.0.0/29"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = cidrhost(module.spoke_1.subnet_address_prefixes["snet-app-01"][0], 10)
}

# Return direction of hub_fw_to_trex_data_port0, toward trex2.
resource "azurerm_route" "hub_fw_to_trex_data_port1" {
  name                   = "trex-data-port1-via-firewall"
  resource_group_name    = azurerm_resource_group.hub.name
  route_table_name       = azurerm_route_table.hub_fw_rt.name
  address_prefix         = "22.0.0.0/29"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = cidrhost(module.spoke_1.subnet_address_prefixes["snet-app-02"][0], 10)
}

# One route table per subnet for independent routing; reserved subnet names
# excluded (local.reserved_subnet_names).
resource "azurerm_route_table" "spoke_1_rt" {
  for_each = {
    for name, subnet in var.spoke_1_subnets : name => subnet
    if !contains(local.reserved_subnet_names, name)
  }

  name                = "udr-${var.environment}-spoke-1-${each.key}"
  location            = azurerm_resource_group.spoke_1.location
  resource_group_name = azurerm_resource_group.spoke_1.name
  tags                = local.tags
}

# Routes from var.spoke_1_subnets. null next_hop_in_ip_address falls back
# to VyOS's lan1 static IP; an explicit value is left untouched.
resource "azurerm_route" "spoke_1_routes" {
  for_each = local.spoke_1_subnet_routes

  name                = each.value.name
  resource_group_name = azurerm_resource_group.spoke_1.name
  route_table_name    = azurerm_route_table.spoke_1_rt[each.value.subnet_name].name
  address_prefix      = each.value.address_prefix
  next_hop_type       = each.value.next_hop_type
  next_hop_in_ip_address = (
    each.value.next_hop_in_ip_address != null
    ? each.value.next_hop_in_ip_address
    : each.value.next_hop_type == "VirtualAppliance" ? local.vyos_lan1_ip : null
  )
}

# ==============================================================================
# Hub Virtual Network
# ==============================================================================

# Hub VNet: "firewall" (VyOS lan1) + "mgmt" subnets.
module "hub" {
  source = "../../modules/vnet"

  name                = "vnet-${var.environment}-hub"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  address_space       = var.hub_address_space
  tags                = local.tags

  subnets = var.hub_subnets

  route_table_associations = merge(
    {
      for name, subnet in var.hub_subnets : name => azurerm_route_table.hub_rt.id
      if name != "firewall"
    },
    contains(keys(var.hub_subnets), "firewall") ? {
      "firewall" = azurerm_route_table.hub_fw_rt.id
    } : {}
  )
}

# ==============================================================================
# Spoke 1 Virtual Network
# ==============================================================================

# Spoke VNet: trex VM's mgmt/app-01/app-02 subnets.
module "spoke_1" {
  source = "../../modules/vnet"

  name                = "vnet-${var.environment}-spoke-1"
  location            = azurerm_resource_group.spoke_1.location
  resource_group_name = azurerm_resource_group.spoke_1.name
  address_space       = var.spoke_1_address_space
  tags                = local.tags

  subnets = var.spoke_1_subnets

  route_table_associations = {
    for name, subnet in var.spoke_1_subnets : name => azurerm_route_table.spoke_1_rt[name].id
    if !contains(local.reserved_subnet_names, name)
  }
}

# ==============================================================================
# Virtual Network Peering - Hub to Spoke1
# ==============================================================================
# A sub-resource of the local vnet's resource group; references the remote
# vnet by ID.

# Hub -> spoke direction of the peering.
resource "azurerm_virtual_network_peering" "hub_to_spoke_1" {
  name                      = "hub-to-spoke-1"
  resource_group_name       = azurerm_resource_group.hub.name
  virtual_network_name      = module.hub.vnet_name
  remote_virtual_network_id = module.spoke_1.vnet_id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

# Spoke -> hub direction of the peering.
resource "azurerm_virtual_network_peering" "spoke_1_to_hub" {
  name                      = "spoke-1-to-hub"
  resource_group_name       = azurerm_resource_group.spoke_1.name
  virtual_network_name      = module.spoke_1.vnet_name
  remote_virtual_network_id = module.hub.vnet_id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

# ==============================================================================
# Virtual Machines
# ==============================================================================

# TRex VM: mgmt (public IP) + trex1/trex2 data-plane NICs.
module "vm_app_01" {
  source = "../../modules/vm"

  name                = "vm-${var.environment}-trex-01"
  location            = azurerm_resource_group.spoke_1.location
  resource_group_name = azurerm_resource_group.spoke_1.name

  network_interfaces = {
    mgmt = {
      subnet_id                     = module.spoke_1.subnet_ids["snet-mgmt-01"]
      private_ip_address            = cidrhost(module.spoke_1.subnet_address_prefixes["snet-mgmt-01"][0], 100)
      enable_accelerated_networking = false
      enable_public_ip              = true
      primary                       = true
    }
    trex1 = {
      subnet_id                     = module.spoke_1.subnet_ids["snet-app-01"]
      private_ip_address            = cidrhost(module.spoke_1.subnet_address_prefixes["snet-app-01"][0], 10)
      enable_accelerated_networking = true
      enable_ip_forwarding          = true
    }
    trex2 = {
      subnet_id                     = module.spoke_1.subnet_ids["snet-app-02"]
      private_ip_address            = cidrhost(module.spoke_1.subnet_address_prefixes["snet-app-02"][0], 10)
      enable_accelerated_networking = true
      enable_ip_forwarding          = true
    }
  }

  # No explicit NSG for "mgmt" - auto-created, SSH/RDP only from this
  # address. trimspace strips ipify's trailing newline.
  management_source_address_prefix = trimspace(data.http.mgmt_from_public_ip.response_body)

  # B-series (module default) doesn't support accelerated networking, which
  # both NICs here request.
  size = "Standard_F8als_v7"

  os_type = "Linux"

  source_image_reference = {
    publisher = "Canonical"
    offer     = "ubuntu-22_04-lts"
    sku       = "server"
    version   = "latest"
  }

  admin_username = var.vm_admin_username
  admin_password = var.vm_admin_password

  # Runs at first boot via cloud-init. Defaults to eth1/eth2 for the data NICs.
  custom_data = file("${path.module}/../../scripts/az-trex-install.sh")

  tags = local.tags
}

# ==============================================================================
# DNS
# ==============================================================================
# A record per instance's public IP, named after the instance, in the
# pre-existing zone from var.dns_zone_id/dns_zone_name.

resource "azapi_resource" "vm_app_01_dns_record" {
  type      = "Microsoft.Network/dnszones/A@2018-05-01"
  name      = module.vm_app_01.vm_name
  parent_id = var.dns_zone_id

  body = {
    properties = {
      TTL = 300
      ARecords = [
        {
          ipv4Address = module.vm_app_01.public_ip_addresses["mgmt"]
        }
      ]
    }
  }
}

# A record for VyOS's wan public IP.
resource "azapi_resource" "vyos_dns_record" {
  type      = "Microsoft.Network/dnszones/A@2018-05-01"
  name      = module.vyos.vm_name
  parent_id = var.dns_zone_id

  body = {
    properties = {
      TTL = 300
      ARecords = [
        {
          ipv4Address = module.vyos.public_ip_addresses["wan"]
        }
      ]
    }
  }
}
