# Every grant below is to a managed identity principal. There are no service principal
# secrets, no SAS tokens, and no connection strings in this configuration -- policy check
# CKV_OREED_4 fails the build if one is introduced.

locals {
  function_principal_id  = azurerm_linux_function_app.this.identity[0].principal_id
  namespace_principal_id = azurerm_eventhub_namespace.this.identity[0].principal_id
}

# Read-only on the hub. The function never needs to send, and Data Receiver is the
# least-privileged built-in role that permits consuming a partition.
resource "azurerm_role_assignment" "function_eventhub_receiver" {
  scope                = azurerm_eventhub.ingest.id
  role_definition_name = "Azure Event Hubs Data Receiver"
  principal_id         = local.function_principal_id
}

# Scoped to the DCR, not the workspace. This principal can submit records through this one
# rule and cannot read, query, or alter anything already in Sentinel.
resource "azurerm_role_assignment" "function_dcr_publisher" {
  scope                = azurerm_monitor_data_collection_rule.this.id
  role_definition_name = "Monitoring Metrics Publisher"
  principal_id         = local.function_principal_id
}

# Required because shared_access_key_enabled is false on the function's storage account:
# the host authenticates to its own state store with the managed identity.
resource "azurerm_role_assignment" "function_storage_blob" {
  scope                = azurerm_storage_account.function.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = local.function_principal_id
}

resource "azurerm_role_assignment" "function_storage_queue" {
  scope                = azurerm_storage_account.function.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = local.function_principal_id
}

resource "azurerm_role_assignment" "function_storage_table" {
  scope                = azurerm_storage_account.function.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = local.function_principal_id
}

# Event Hubs Capture writes to the archive account as the namespace's own identity.
resource "azurerm_role_assignment" "namespace_capture_blob" {
  count = var.eventhub_capture_enabled ? 1 : 0

  scope                = azurerm_storage_account.capture.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = local.namespace_principal_id
}
