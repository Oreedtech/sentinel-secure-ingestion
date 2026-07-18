"""Custom Checkov policies asserting the security properties this architecture claims.

Each check maps to a control described in docs/architecture.md. They run against the
Terraform source in CI, so a change that quietly reopens the boundary fails the build
rather than shipping.

Run locally:
    checkov -d terraform --external-checks-dir policy/checkov
"""

from typing import Any

from checkov.common.models.enums import CheckCategories, CheckResult
from checkov.terraform.checks.resource.base_resource_check import BaseResourceCheck


def _is_false(conf: dict[str, Any], key: str) -> bool:
    """Terraform parses attributes into single-element lists."""
    return conf.get(key) == [False]


def _is_true(conf: dict[str, Any], key: str) -> bool:
    return conf.get(key) == [True]


class EventHubLocalAuthDisabled(BaseResourceCheck):
    """SAS keys must not be an available authentication path on the ingestion namespace."""

    def __init__(self) -> None:
        super().__init__(
            name="Event Hubs namespace disables local (SAS) authentication",
            id="CKV_OREED_1",
            categories=[CheckCategories.IAM],
            supported_resources=["azurerm_eventhub_namespace"],
        )

    def scan_resource_conf(self, conf: dict[str, Any]) -> CheckResult:
        return CheckResult.PASSED if _is_false(conf, "local_authentication_enabled") else CheckResult.FAILED


class DataPlanePublicAccessDisabled(BaseResourceCheck):
    """No data-plane resource may be reachable from the public internet."""

    def __init__(self) -> None:
        super().__init__(
            name="Data-plane resource disables public network access",
            id="CKV_OREED_2",
            categories=[CheckCategories.NETWORKING],
            supported_resources=[
                "azurerm_eventhub_namespace",
                "azurerm_storage_account",
                "azurerm_linux_function_app",
                "azurerm_monitor_data_collection_endpoint",
            ],
        )

    def scan_resource_conf(self, conf: dict[str, Any]) -> CheckResult:
        return CheckResult.PASSED if _is_false(conf, "public_network_access_enabled") else CheckResult.FAILED


class WorkspaceInternetIngestionDisabled(BaseResourceCheck):
    """Sentinel's workspace must accept ingestion over private link only."""

    def __init__(self) -> None:
        super().__init__(
            name="Log Analytics workspace disables internet ingestion and query",
            id="CKV_OREED_3",
            categories=[CheckCategories.NETWORKING],
            supported_resources=["azurerm_log_analytics_workspace", "azurerm_application_insights"],
        )

    def scan_resource_conf(self, conf: dict[str, Any]) -> CheckResult:
        ingestion_closed = _is_false(conf, "internet_ingestion_enabled")
        query_closed = _is_false(conf, "internet_query_enabled")
        return CheckResult.PASSED if ingestion_closed and query_closed else CheckResult.FAILED


class NoSharedKeyAuthentication(BaseResourceCheck):
    """Storage access keys are a credential this design must not possess."""

    def __init__(self) -> None:
        super().__init__(
            name="Storage account disables shared key authentication",
            id="CKV_OREED_4",
            categories=[CheckCategories.IAM],
            supported_resources=["azurerm_storage_account"],
        )

    def scan_resource_conf(self, conf: dict[str, Any]) -> CheckResult:
        return CheckResult.PASSED if _is_false(conf, "shared_access_key_enabled") else CheckResult.FAILED


class PrivateEndpointHasDnsZoneGroup(BaseResourceCheck):
    """A private endpoint without a DNS zone group resolves to the public IP.

    This is the highest-value check in the set. The resource still deploys cleanly, so the
    defect is invisible until traffic silently leaves the VNet or the firewall drops it.
    """

    def __init__(self) -> None:
        super().__init__(
            name="Private endpoint declares a private DNS zone group",
            id="CKV_OREED_5",
            categories=[CheckCategories.NETWORKING],
            supported_resources=["azurerm_private_endpoint"],
        )

    def scan_resource_conf(self, conf: dict[str, Any]) -> CheckResult:
        groups = conf.get("private_dns_zone_group")
        if not groups:
            return CheckResult.FAILED

        group = groups[0]
        if isinstance(group, list):
            group = group[0] if group else {}
        if not isinstance(group, dict):
            return CheckResult.FAILED

        zone_ids = group.get("private_dns_zone_ids")
        if isinstance(zone_ids, list) and len(zone_ids) == 1 and isinstance(zone_ids[0], list):
            zone_ids = zone_ids[0]

        return CheckResult.PASSED if zone_ids else CheckResult.FAILED


class FunctionRoutesAllTrafficThroughVnet(BaseResourceCheck):
    """Without vnet_route_all_enabled the NSG and route table never see egress traffic."""

    def __init__(self) -> None:
        super().__init__(
            name="Function app routes all outbound traffic through the integrated subnet",
            id="CKV_OREED_6",
            categories=[CheckCategories.NETWORKING],
            supported_resources=["azurerm_linux_function_app"],
        )

    def scan_resource_conf(self, conf: dict[str, Any]) -> CheckResult:
        site_config = conf.get("site_config")
        if not site_config:
            return CheckResult.FAILED

        config = site_config[0]
        if isinstance(config, list):
            config = config[0] if config else {}
        if not isinstance(config, dict):
            return CheckResult.FAILED

        value = config.get("vnet_route_all_enabled")
        if isinstance(value, list):
            value = value[0] if value else None

        return CheckResult.PASSED if value is True else CheckResult.FAILED


class RoleAssignmentTargetsManagedIdentity(BaseResourceCheck):
    """Grants must reference an identity block, never a hardcoded or secret-backed principal."""

    def __init__(self) -> None:
        super().__init__(
            name="Role assignment principal derives from a managed identity",
            id="CKV_OREED_7",
            categories=[CheckCategories.IAM],
            supported_resources=["azurerm_role_assignment"],
        )

    def scan_resource_conf(self, conf: dict[str, Any]) -> CheckResult:
        principal = conf.get("principal_id")
        if not principal:
            return CheckResult.FAILED

        rendered = str(principal[0])
        # A managed identity principal is always an unresolved reference at plan time.
        # A literal GUID or a var lookup means the credential came from somewhere else.
        return CheckResult.PASSED if "identity" in rendered or "principal_id" in rendered else CheckResult.FAILED


check_local_auth = EventHubLocalAuthDisabled()
check_public_access = DataPlanePublicAccessDisabled()
check_workspace_private = WorkspaceInternetIngestionDisabled()
check_shared_key = NoSharedKeyAuthentication()
check_dns_zone_group = PrivateEndpointHasDnsZoneGroup()
check_vnet_route_all = FunctionRoutesAllTrafficThroughVnet()
check_managed_identity = RoleAssignmentTargetsManagedIdentity()
