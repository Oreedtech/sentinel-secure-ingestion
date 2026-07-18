resource "azurerm_log_analytics_workspace" "this" {
  name                = "law-${var.prefix}-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags

  internet_ingestion_enabled = false
  internet_query_enabled     = false

  local_authentication_disabled = true
}

resource "azurerm_sentinel_log_analytics_workspace_onboarding" "this" {
  workspace_id = azurerm_log_analytics_workspace.this.id
}

# Custom destination table. azurerm has no resource for creating a _CL table, so this drops
# to the ARM API directly -- the schema must exist before the DCR can reference the stream.
resource "azapi_resource" "custom_table" {
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = local.custom_table_name
  parent_id = azurerm_log_analytics_workspace.this.id

  body = {
    properties = {
      schema = {
        name = local.custom_table_name
        columns = [
          { name = "TimeGenerated", type = "datetime" },
          { name = "SourceSystem", type = "string" },
          { name = "EventId", type = "string" },
          { name = "Severity", type = "string" },
          { name = "SrcIpAddr", type = "string" },
          { name = "DstIpAddr", type = "string" },
          { name = "ActorUsername", type = "string" },
          { name = "EventMessage", type = "string" },
          { name = "RawEvent", type = "string" },
        ]
      }
      retentionInDays      = var.log_retention_days
      totalRetentionInDays = var.log_retention_days
    }
  }

  depends_on = [azurerm_sentinel_log_analytics_workspace_onboarding.this]
}

resource "azurerm_monitor_data_collection_endpoint" "this" {
  name                = "dce-${var.prefix}-${local.suffix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  kind                = "Linux"
  tags                = var.tags

  public_network_access_enabled = false
}

resource "azurerm_monitor_data_collection_rule" "this" {
  name                        = "dcr-${var.prefix}-${local.suffix}"
  location                    = azurerm_resource_group.this.location
  resource_group_name         = azurerm_resource_group.this.name
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.this.id
  tags                        = var.tags

  # kind is deliberately unset. The azurerm provider only accepts the agent-oriented kinds
  # (Linux, Windows, AgentDirectToStore, WorkspaceTransforms); a direct-ingestion DCR is
  # expressed by pairing stream_declaration with a data collection endpoint instead.

  stream_declaration {
    stream_name = "Custom-${local.custom_table_name}"

    column {
      name = "TimeGenerated"
      type = "datetime"
    }
    column {
      name = "SourceSystem"
      type = "string"
    }
    column {
      name = "EventId"
      type = "string"
    }
    column {
      name = "Severity"
      type = "string"
    }
    column {
      name = "SrcIpAddr"
      type = "string"
    }
    column {
      name = "DstIpAddr"
      type = "string"
    }
    column {
      name = "ActorUsername"
      type = "string"
    }
    column {
      name = "EventMessage"
      type = "string"
    }
    column {
      name = "RawEvent"
      type = "string"
    }
  }

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.this.id
      name                  = "sentinel-workspace"
    }
  }

  data_flow {
    streams      = ["Custom-${local.custom_table_name}"]
    destinations = ["sentinel-workspace"]

    # Transformation runs before storage: drop health-check noise and normalise severity.
    # Filtering here rather than at the source is what keeps ingestion cost predictable.
    transform_kql = <<-KQL
      source
      | where EventId !in ("heartbeat", "healthprobe")
      | extend Severity = tolower(Severity)
      | project TimeGenerated, SourceSystem, EventId, Severity, SrcIpAddr, DstIpAddr, ActorUsername, EventMessage, RawEvent
    KQL

    output_stream = "Custom-${local.custom_table_name}"
  }

  depends_on = [azapi_resource.custom_table]
}

# Azure Monitor Private Link Scope. PrivateOnly is the setting that makes "private link
# ingestion only" enforced rather than aspirational. Note it applies scope-wide: every
# workspace attached to this AMPLS inherits it.
resource "azurerm_monitor_private_link_scope" "this" {
  name                = "ampls-${var.prefix}-${local.suffix}"
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  ingestion_access_mode = "PrivateOnly"
  query_access_mode     = "PrivateOnly"
}

resource "azurerm_monitor_private_link_scoped_service" "workspace" {
  name                = "amplss-workspace"
  resource_group_name = azurerm_resource_group.this.name
  scope_name          = azurerm_monitor_private_link_scope.this.name
  linked_resource_id  = azurerm_log_analytics_workspace.this.id
}

resource "azurerm_monitor_private_link_scoped_service" "dce" {
  name                = "amplss-dce"
  resource_group_name = azurerm_resource_group.this.name
  scope_name          = azurerm_monitor_private_link_scope.this.name
  linked_resource_id  = azurerm_monitor_data_collection_endpoint.this.id
}

resource "azurerm_monitor_private_link_scoped_service" "app_insights" {
  name                = "amplss-appinsights"
  resource_group_name = azurerm_resource_group.this.name
  scope_name          = azurerm_monitor_private_link_scope.this.name
  linked_resource_id  = azurerm_application_insights.this.id
}

# One private endpoint fronts the whole scope, resolving across five DNS zones.
resource "azurerm_private_endpoint" "ampls" {
  name                = "pe-${var.prefix}-ampls"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-ampls"
    private_connection_resource_id = azurerm_monitor_private_link_scope.this.id
    subresource_names              = ["azuremonitor"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [for k in local.ampls_dns_zone_keys : azurerm_private_dns_zone.this[k].id]
  }
}
