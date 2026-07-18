# The function's own content/state storage account. This is the dependency most often left
# public in otherwise-private designs -- an unlocked storage account here reopens the
# boundary regardless of how tightly the rest of the pipeline is closed.
resource "azurerm_storage_account" "function" {
  # checkov:skip=CKV_AZURE_36:Deliberately stricter than the check. It wants bypass to include AzureServices; this account is reached only over private endpoints from the integrated subnet, so a service bypass would widen the network posture for no functional gain.
  # checkov:skip=CKV_AZURE_206:ZRS is intentional over GRS. Cross-region replication of security telemetry is a data-residency decision, not a default; zone redundancy already covers the failure mode this account faces.
  # checkov:skip=CKV2_AZURE_1:Platform-managed keys. CMK with a private-endpoint Key Vault is recorded as gap 2 in docs/threat-model.md rather than silently omitted.
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

    container_delete_retention_policy {
      days = 7
    }
  }

  # The function host uses queues for its own state. Logging read/write/delete gives an
  # audit trail for that state independent of the pipeline it is running.
  queue_properties {
    logging {
      delete                = true
      read                  = true
      write                 = true
      version               = "1.0"
      retention_policy_days = 10
    }
  }
}

resource "azurerm_storage_account" "capture" {
  # checkov:skip=CKV_AZURE_206:ZRS is intentional over GRS. This account holds raw security events; replicating them to a paired region is a data-residency decision that belongs to the deploying org, not a module default.
  # checkov:skip=CKV_AZURE_33:No queues exist on this account. Capture writes blobs only, so queue logging would monitor a surface that is never used.
  # checkov:skip=CKV2_AZURE_1:Platform-managed keys. See gap 2 in docs/threat-model.md.
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

  # Soft delete on the archive matters more than on the function's state store: this is the
  # replay path, so an accidental delete here is the difference between a recoverable
  # incident and permanent loss of the raw events.
  blob_properties {
    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
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
