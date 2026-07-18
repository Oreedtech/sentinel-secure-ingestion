resource "azurerm_service_plan" "this" {
  # checkov:skip=CKV_AZURE_225:Zone balancing requires a minimum of three instances. Enabling it triples the plan's cost, which puts the module out of reach of a trial subscription. Production deployments should set zone_balancing_enabled and worker_count >= 3; see docs/cost-notes.md.
  # checkov:skip=CKV_AZURE_212:Same tradeoff as CKV_AZURE_225. A single instance is a documented availability limitation of the lab default, not an oversight.
  name                = "asp-${var.prefix}-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  os_type             = "Linux"

  # Elastic Premium is required for regional VNet integration with private endpoints.
  # Consumption cannot reach a private-only Event Hubs namespace.
  sku_name = "EP1"
  tags     = var.tags
}

resource "azurerm_linux_function_app" "this" {
  name                = "func-${var.prefix}-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  service_plan_id     = azurerm_service_plan.this.id
  tags                = var.tags

  storage_account_name          = azurerm_storage_account.function.name
  storage_uses_managed_identity = true

  public_network_access_enabled = false
  https_only                    = true

  virtual_network_subnet_id = azurerm_subnet.function.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    ftps_state                             = "Disabled"
    minimum_tls_version                    = "1.2"
    application_insights_connection_string = azurerm_application_insights.this.connection_string

    # Forces every outbound call -- including platform calls -- through the integrated
    # subnet, where the NSG and route table apply. Without this, egress bypasses the
    # controls entirely and the design is private in name only.
    vnet_route_all_enabled = true

    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    # No connection strings anywhere. The host resolves the hub via the fully qualified
    # namespace and authenticates with the system-assigned identity.
    "EVENTHUB_FULLY_QUALIFIED_NAMESPACE" = "${azurerm_eventhub_namespace.this.name}.servicebus.windows.net"
    "EVENTHUB_NAME"                      = azurerm_eventhub.ingest.name
    "EVENTHUB_CONSUMER_GROUP"            = azurerm_eventhub_consumer_group.function.name
    "EVENTHUB_CONNECTION__credential"    = "managedidentity"

    "DCE_LOGS_INGESTION_ENDPOINT" = azurerm_monitor_data_collection_endpoint.this.logs_ingestion_endpoint
    "DCR_IMMUTABLE_ID"            = azurerm_monitor_data_collection_rule.this.immutable_id
    "DCR_STREAM_NAME"             = "Custom-${local.custom_table_name}"

    "WEBSITE_CONTENTOVERVNET"  = "1"
    "FUNCTIONS_WORKER_RUNTIME" = "python"
  }

  lifecycle {
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE"],
    ]
  }
}

resource "azurerm_application_insights" "this" {
  name                = "appi-${var.prefix}-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.this.id
  tags                = var.tags

  internet_ingestion_enabled = false
  internet_query_enabled     = false
}

resource "azurerm_private_endpoint" "function" {
  name                = "pe-${var.prefix}-func"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-func"
    private_connection_resource_id = azurerm_linux_function_app.this.id
    subresource_names              = ["sites"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [azurerm_private_dns_zone.this["sites"].id]
  }
}
