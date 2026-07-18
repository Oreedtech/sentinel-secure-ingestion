resource "azurerm_eventhub_namespace" "this" {
  name                = "evhns-${var.prefix}-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard"
  capacity            = 1
  tags                = var.tags

  # The two settings that make this namespace private-only. Disabling local auth removes
  # SAS entirely, so Entra ID is not merely preferred -- it is the only remaining path.
  public_network_access_enabled = false
  local_authentication_enabled  = false

  minimum_tls_version      = "1.2"
  auto_inflate_enabled     = true
  maximum_throughput_units = 4

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_eventhub" "ingest" {
  name              = "evh-${var.prefix}-ingest"
  namespace_id      = azurerm_eventhub_namespace.this.id
  partition_count   = var.eventhub_partition_count
  message_retention = 7

  dynamic "capture_description" {
    for_each = var.eventhub_capture_enabled ? [1] : []

    content {
      enabled             = true
      encoding            = "Avro"
      interval_in_seconds = 300
      size_limit_in_bytes = 314572800
      skip_empty_archives = true

      destination {
        name                = "EventHubArchive.AzureBlockBlob"
        archive_name_format = "{Namespace}/{EventHub}/{PartitionId}/{Year}/{Month}/{Day}/{Hour}/{Minute}/{Second}"
        blob_container_name = azurerm_storage_container.capture.name
        storage_account_id  = azurerm_storage_account.capture.id
      }
    }
  }
}

# Dedicated consumer group so the ingestion function's checkpoint offsets are never shared
# with an operator running an ad-hoc read.
resource "azurerm_eventhub_consumer_group" "function" {
  name                = "cg-ingestion-function"
  namespace_name      = azurerm_eventhub_namespace.this.name
  eventhub_name       = azurerm_eventhub.ingest.name
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_private_endpoint" "eventhub" {
  name                = "pe-${var.prefix}-evhns"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-evhns"
    private_connection_resource_id = azurerm_eventhub_namespace.this.id
    subresource_names              = ["namespace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.this["eventhub"].id]
  }
}

resource "azurerm_monitor_diagnostic_setting" "eventhub" {
  name                       = "diag-to-workspace"
  target_resource_id         = azurerm_eventhub_namespace.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "OperationalLogs"
  }

  # Surfaces rejected SAS attempts against a namespace with local auth disabled.
  # See detections/eventhub-local-auth-attempt.kql.
  enabled_log {
    category = "RuntimeAuditLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

# Reads of the raw event archive are themselves security-relevant: this container holds
# unfiltered source events, so knowing who retrieved them matters as much as knowing who
# wrote them. Also satisfies CKV2_AZURE_21.
resource "azurerm_monitor_diagnostic_setting" "capture_blob" {
  name                       = "diag-capture-blob"
  target_resource_id         = "${azurerm_storage_account.capture.id}/blobServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "StorageRead"
  }

  enabled_log {
    category = "StorageWrite"
  }

  enabled_log {
    category = "StorageDelete"
  }
}
