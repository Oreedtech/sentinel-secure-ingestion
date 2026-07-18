resource "azurerm_resource_group" "this" {
  name     = "rg-${var.prefix}-${var.location}"
  location = var.location
  tags     = var.tags
}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  suffix = random_string.suffix.result

  # Every private DNS zone this architecture depends on. Missing any one of these is the
  # most common failure mode: name resolution silently falls back to the public IP, the
  # egress firewall then drops the traffic, and it presents as an unrelated network fault.
  private_dns_zones = {
    eventhub = "privatelink.servicebus.windows.net"
    blob     = "privatelink.blob.core.windows.net"
    file     = "privatelink.file.core.windows.net"
    queue    = "privatelink.queue.core.windows.net"
    table    = "privatelink.table.core.windows.net"
    sites    = "privatelink.azurewebsites.net"
    monitor  = "privatelink.monitor.azure.com"
    oms      = "privatelink.oms.opinsights.azure.com"
    ods      = "privatelink.ods.opinsights.azure.com"
    agentsvc = "privatelink.agentsvc.azure-automation.net"
  }

  # Azure Monitor resolves across several zones behind a single private endpoint.
  ampls_dns_zone_keys = ["monitor", "oms", "ods", "agentsvc", "blob"]

  # Custom log table the DCR writes into. The _CL suffix is required by the Logs Ingestion API.
  custom_table_name = "SecureIngest_CL"
}
