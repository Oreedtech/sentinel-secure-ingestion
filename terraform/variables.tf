variable "subscription_id" {
  description = "Target Azure subscription ID."
  type        = string
}

variable "prefix" {
  description = "Short name prefix for all resources. Lowercase alphanumeric, 3-10 chars."
  type        = string
  default     = "sentingest"

  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.prefix))
    error_message = "Prefix must be 3-10 lowercase alphanumeric characters."
  }
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus2"
}

variable "vnet_address_space" {
  description = "Address space for the ingestion virtual network."
  type        = list(string)
  default     = ["10.60.0.0/22"]
}

variable "subnet_prefixes" {
  description = "Subnet CIDRs. The function subnet is delegated and cannot host private endpoints."
  type = object({
    private_endpoints = string
    function          = string
  })

  default = {
    private_endpoints = "10.60.0.0/24"
    function          = "10.60.1.0/24"
  }
}

variable "enable_forced_tunneling" {
  description = <<-EOT
    Route all egress (0.0.0.0/0) to a network virtual appliance. Requires firewall_private_ip.
    Disabled by default so the module can be deployed without an Azure Firewall, which costs
    roughly $900/month. See docs/cost-notes.md for the substitution.
  EOT
  type        = bool
  default     = false
}

variable "firewall_private_ip" {
  description = "Private IP of the Azure Firewall or NVA. Required when enable_forced_tunneling is true."
  type        = string
  default     = null

  validation {
    condition     = var.firewall_private_ip == null || can(cidrnetmask("${var.firewall_private_ip}/32"))
    error_message = "firewall_private_ip must be a valid IPv4 address."
  }
}

variable "eventhub_partition_count" {
  description = "Partition count for the ingestion event hub. Cannot be decreased after creation."
  type        = number
  default     = 4
}

variable "eventhub_capture_enabled" {
  description = <<-EOT
    Capture raw events to a private-endpoint storage account. This is the replay path: a
    private-only pipeline has no fallback, so an outage downstream of the hub becomes
    permanent log loss without it.
  EOT
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Log Analytics interactive retention in days."
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    workload = "sentinel-ingestion"
    exposure = "private-only"
  }
}
