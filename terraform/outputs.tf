output "resource_group_name" {
  description = "Resource group holding the ingestion pipeline."
  value       = azurerm_resource_group.this.name
}

output "eventhub_namespace_fqdn" {
  description = "Fully qualified namespace. Resolves to a private IP from inside the VNet only."
  value       = "${azurerm_eventhub_namespace.this.name}.servicebus.windows.net"
}

output "workspace_id" {
  description = "Log Analytics workspace resource ID backing Sentinel."
  value       = azurerm_log_analytics_workspace.this.id
}

output "dcr_immutable_id" {
  description = "Immutable ID the ingestion client passes to the Logs Ingestion API."
  value       = azurerm_monitor_data_collection_rule.this.immutable_id
}

output "logs_ingestion_endpoint" {
  description = "Private DCE endpoint the function posts records to."
  value       = azurerm_monitor_data_collection_endpoint.this.logs_ingestion_endpoint
}

output "function_principal_id" {
  description = "System-assigned identity holding every data-plane grant in this design."
  value       = local.function_principal_id
}

output "private_endpoint_ips" {
  description = "Private IPs assigned to each endpoint, for DNS resolution troubleshooting."
  value = {
    eventhub = azurerm_private_endpoint.eventhub.private_service_connection[0].private_ip_address
    ampls    = azurerm_private_endpoint.ampls.private_service_connection[0].private_ip_address
    function = azurerm_private_endpoint.function.private_service_connection[0].private_ip_address
  }
}
