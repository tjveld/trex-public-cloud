terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = "~> 2.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  # Avoid auto-registering every RP azurerm supports - this config only
  # needs Microsoft.Network/Resources, registered by default on most subscriptions.
  resource_provider_registrations = "none"

  features {}
}

# No subscription_id pinned, azapi picks up the same context as azurerm above.
provider "azapi" {}
