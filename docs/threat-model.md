# Threat model

STRIDE applied to each trust boundary in [the architecture](architecture.svg). The point of
this document is not to enumerate every conceivable threat — it is to record which controls
in the Terraform exist for which reason, and to be explicit about what this design does
*not* address.

## Trust boundaries

| # | Boundary | Crossing |
|---|----------|----------|
| B1 | Source network → Event Hubs | Log producers authenticate and send |
| B2 | Event Hubs → ingestion function | Function consumes a partition |
| B3 | Function → Azure Monitor | Records posted to the Logs Ingestion API |
| B4 | Ingestion VNet → internet | Any outbound call from compute |
| B5 | Operator → control plane | ARM writes against pipeline resources |

## B1 — Source network to Event Hubs

| Threat | Vector | Control |
|--------|--------|---------|
| Spoofing | Attacker with a leaked SAS token sends forged events | `local_authentication_enabled = false` removes SAS as a mechanism. Entra ID tokens are short-lived and revocable; a SAS key is neither. |
| Tampering | Events modified in transit | TLS 1.2 minimum enforced at the namespace. |
| Repudiation | No record of who sent what | `RuntimeAuditLogs` diagnostic category captures authentication events, including rejected ones. |
| Information disclosure | Namespace enumerable and reachable from the internet | `public_network_access_enabled = false` plus a private endpoint. The namespace has no public DNS resolution path from outside the VNet. |
| Denial of service | Flood of events exhausts throughput | Auto-inflate to 4 TU absorbs bursts. **Residual risk:** a determined flood from a compromised authorized source still degrades ingestion. Rate limiting per producer is not implemented. |
| Elevation of privilege | Producer identity gains read access | Producers hold `Azure Event Hubs Data Sender` only; the receiver grant is separate and scoped to the function. |

## B2 — Event Hubs to ingestion function

| Threat | Vector | Control |
|--------|--------|---------|
| Spoofing | Rogue consumer reads the event stream | `Azure Event Hubs Data Receiver` scoped to the single hub, granted to one system-assigned identity. No secret exists to steal. |
| Tampering | Consumer checkpoint manipulated to skip events | Dedicated consumer group isolates the function's offsets from any ad-hoc reader. **Residual risk:** an operator with data-plane rights can still reset offsets. Detected via `detections/private-link-config-drift.kql` only if done through ARM. |
| Repudiation | Silent event loss | Event Hubs Capture archives raw events to blob independently of the function, providing a replay source and an out-of-band record. |
| Information disclosure | Traffic leaves the VNet | Private endpoint plus `privatelink.servicebus.windows.net` DNS zone. Missing the zone is the realistic failure — covered by policy check `CKV_OREED_5`. |

## B3 — Function to Azure Monitor

| Threat | Vector | Control |
|--------|--------|---------|
| Spoofing | Forged records injected into Sentinel | `Monitoring Metrics Publisher` scoped to the DCR, not the workspace. The identity can submit through one rule and cannot read or alter existing data. |
| Tampering | Log fields manipulated before storage | DCR `transform_kql` runs server-side and projects an explicit column list. Fields outside the schema are dropped rather than trusted. |
| Information disclosure | Ingestion traverses the public Monitor endpoint | AMPLS with `ingestion_access_mode = "PrivateOnly"`, plus `internet_ingestion_enabled = false` on the workspace. |
| Elevation of privilege | Publisher grant widened to workspace scope | **Not prevented by design.** Requires the drift detection plus Azure Policy at the management-group level. See gaps below. |

## B4 — Ingestion VNet to internet

| Threat | Vector | Control |
|--------|--------|---------|
| Information disclosure | Compromised function exfiltrates collected logs | `vnet_route_all_enabled` forces all egress through the integrated subnet; NSG denies internet outbound; UDR sends 0.0.0.0/0 to the firewall for FQDN inspection. |
| Tampering | Malicious dependency pulled at runtime | Package deployment is immutable via `WEBSITE_RUN_FROM_PACKAGE`. **Residual risk:** the supply chain of that package is out of scope here. |

This is the boundary most often left open. A design can have flawless inbound controls and
still allow a compromised workload to post everything it collected to an external host.
`vnet_route_all_enabled` is the setting that makes the NSG and route table apply at all;
without it, egress bypasses both, which is why it has a dedicated policy check.

## B5 — Operator to control plane

| Threat | Vector | Control |
|--------|--------|---------|
| Tampering | Public access re-enabled on a data-plane resource | Detected by `detections/private-link-config-drift.kql`. **Detection, not prevention** — see gaps. |
| Repudiation | Change made without attribution | `AzureActivity` captures caller, IP, and correlation ID. |
| Elevation of privilege | Standing owner rights on the resource group | Out of scope for this repo. |

## Known gaps

Stated plainly, because a threat model that claims full coverage is not credible.

1. **Control-plane changes are detected, not blocked.** Preventing them requires Azure Policy
   with `deny` effects at the management-group level, plus PIM for eligible-only elevation.
   Neither is in this repo — both sit above the workload scope.
2. **No customer-managed keys.** Encryption at rest uses platform-managed keys throughout.
   CMK with a private-endpoint Key Vault is a straightforward addition and is deliberately
   omitted to keep the deployable surface small.
3. **Source-side authentication is assumed.** This design secures the pipeline from the hub
   onward. How an on-prem forwarder obtains and rotates its Entra ID credential is a real
   problem and is not solved here.
4. **No egress FQDN inspection without Azure Firewall.** `enable_forced_tunneling` defaults
   to `false` because the firewall is cost-prohibitive on a trial subscription. With it off,
   NSG service tags are the only egress control, which is coarser: they permit any endpoint
   within a tag rather than a specific hostname.
5. **Capture storage uses the trusted-services bypass.** Event Hubs Capture writes from the
   service fabric rather than from inside the VNet, so `bypass = ["AzureServices"]` is
   required. This is a genuine widening of the storage account's network posture, accepted
   in exchange for a replay path.
