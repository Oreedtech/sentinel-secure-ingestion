# The function's own content/state storage account. This is the dependency most often left
# public in otherwise-private designs -- an unlocked storage account here reopens the
# boundary regardless of how tightly the rest of the pipeline is closed.
resource "azurerm_storage_account" "function" {
  name                = "st${var.prefix}fn${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  account_tier             = "Standard"
  account_replication_type = "ZRS"
  account_kind             = "StorageV2"

  public_network_access_enabled   = false
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true

  network_rules {
    default_action = "Deny"
    bypass         = ["None"]
  }

  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }
}

resource "azurerm_storage_account" "capture" {
  name                = "st${var.prefix}cap${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  account_tier             = "Standard"
  account_replication_type = "ZRS"
  account_kind             = "StorageV2"

  public_network_access_enabled   = false
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true

  # Event Hubs Capture writes from the service fabric, not from inside the VNet, so it needs
  # the trusted-services bypass. The namespace still authenticates with its managed identity
  # and holds only Storage Blob Data Contributor on this account.
  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
  }
}

resource "azurerm_storage_container" "capture" {
  name                  = "raw-events"
  storage_account_id    = azurerm_storage_account.capture.id
  container_access_type = "private"
}

locals {
  function_storage_pe_subresources = ["blob", "file", "queue", "table"]
}

resource "azurerm_private_endpoint" "function_storage" {
  for_each = toset(local.function_storage_pe_subresources)

  name                = "pe-${var.prefix}-fnst-${each.key}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-fnst-${each.key}"
    private_connection_resource_id = azurerm_storage_account.function.id
    subresource_names              = [each.key]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.this[each.key].id]
  }
}

resource "azurerm_private_endpoint" "capture_storage" {
  name                = "pe-${var.prefix}-capst-blob"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-capst-blob"
    private_connection_resource_id = azurerm_storage_account.capture.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.this["blob"].id]
  }
}
