# Cost notes

Written because "why didn't you just deploy it?" is a fair question, and the answer is
specific rather than hand-waving.

All figures are approximate, East US 2, and will drift. Check the
[Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) before relying
on them.

## What this design costs to run continuously

| Component | Approximate monthly |
|-----------|--------------------|
| Azure Firewall (Standard) | ~$900 + data processing |
| App Service plan EP1 (Elastic Premium) | ~$150 |
| Event Hubs Standard, 1 TU | ~$22 |
| Private endpoints (8 × ~$7.30) | ~$58 |
| Log Analytics ingestion | ~$2.30 per GB |
| AMPLS, private DNS zones, VNet | negligible |

Azure Firewall dominates by an order of magnitude. It is billed hourly for existence, not
usage, so an idle firewall in a lab costs the same as a production one.

## Why the firewall is optional in this repo

`enable_forced_tunneling` defaults to `false`. With it off, egress control degrades from
FQDN-level inspection to NSG service tags — meaningfully coarser, since a service tag
permits any endpoint within that tag rather than a named host.

That tradeoff is recorded in [the threat model](threat-model.md) as gap 4 rather than
quietly ignored. The production recommendation remains the firewall; the default reflects
what is testable without a funded subscription.

## Deploying this temporarily

Most of the design is genuinely cheap for a short run. Skipping the firewall, a few hours
costs roughly:

| Component | Per hour |
|-----------|----------|
| EP1 plan | ~$0.20 |
| Event Hubs Standard | ~$0.03 |
| 8 private endpoints | ~$0.08 |
| Log Analytics | trial covers 10 GB/day for 31 days on new workspaces |

An afternoon runs to a few dollars, which fits inside the $200 free-account credit. If you
do this, `terraform destroy` immediately afterward — private endpoints and the EP1 plan
both bill continuously whether or not anything flows through them.

## Cost controls in the design itself

Two choices here are cost controls as much as security controls:

**DCR transformation.** `transform_kql` filters heartbeat and health-probe events before
storage. Filtering at ingestion rather than at query time is the single largest lever on
Sentinel spend — you pay per GB stored, so dropping noise upstream compounds.

**Capture to blob.** Raw events land in blob at roughly $0.02/GB against $2.30/GB in Log
Analytics. High-volume, low-signal sources can be captured for compliance retention and
selectively promoted to the workspace, rather than ingested wholesale.
