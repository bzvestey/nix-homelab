# Home Assistant operational telemetry

## Status and intended outcome

The operator approved the operational-only scope and requested a concrete design
for review. This document is the proposed implementation contract, not approval
to install an app, restart Home Assistant, publish code, or deploy changes.

Collect supported operational metrics from Home Assistant OS and its installed
apps (formerly add-ons) into the existing Prometheus and Grafana on hl-node-00.
Expose health, resource consumption, versions, updates, and application runtime
metrics. Keep entity and sensor-state monitoring for a separate future project.
Coverage must be explicit: unsupported or failed collection is unknown, not zero
or healthy. No changes to existing sensor recording or automation behavior.

## Observed environment

- Home Assistant OS 18.3, Core 2026.10.4, Supervisor 2026.10.3, Raspberry Pi 4
  aarch64. LAN address 10.15.5.251; Tailscale address 100.75.116.65.
- Home Assistant's `/api/prometheus` currently returns 404; its Prometheus
  integration is not configured. Do not enable unfiltered entity export.
- Supervisor reports Core, Supervisor, and per-app CPU, memory, network and
  block-I/O statistics. Host information includes boot time and disk capacity.
- Tailscale kernel networking and Supervisor DNS forwarding now work. Preserve
  the corrected configuration; do not put Quad100 back into interface DNS.
- Kuma app 0.19.4 packages Kuma 2.5.6. Its metrics endpoint requires
  authentication. A restart refreshed the tag schema; no new Prometheus label
  errors appeared during the following full monitor interval.
- hl-node-00 already owns Prometheus, Grafana provisioning, encrypted runtime
  secrets, and a separate external NAS telemetry module. Extend these patterns.

## Approach selection

1. **Recommended: local HAOS collector, central Prometheus pull.** A small local
   app reads Supervisor APIs and approved local application metrics. The Pi
   scrapes a bounded, authenticated operational endpoint. Supervisor credentials
   stay on HAOS; no Docker socket or host SSH is required for routine collection.
2. Remote SSH polling reuses the diagnostic access but couples monitoring to a
   powerful interactive shell and ad hoc shell parsing. Do not use it as the
   permanent collection mechanism.
3. Core entity export alone misses per-app resources and risks exporting home
   state. Broad Docker/node-exporter deployment adds privileges and unsupported
   host modifications. Neither is the baseline.

## Collection boundary and security

Keep the collector source and HAOS app packaging in this repository under
`packages/home-assistant-telemetry/`. Support aarch64 locally built installation;
do not require a new public image registry or package publication. Pin the base
image and dependencies through the repository's established supply-chain policy.

The app uses Supervisor API access with the minimum role that supports inventory
and resource stats. Current Supervisor access rules require `manager` for app
listing and stats; `default` permits information endpoints but not these stats.
This is **not a read-only token**, even though collector code issues only GETs.
Document the privilege and verify access on the installed Supervisor version.
Do not enable Home Assistant Core API access, Docker API access, host networking,
host PID access, directory mounts, journal access, or disable Protection mode.

The collector has fixed upstream paths and configured local application targets,
not a general HTTP proxy or command-execution interface. Never export options,
API payloads, environment variables, log bodies, addresses of home devices,
credentials, or tokens. Never send the Supervisor token to the Pi.

Publish a dedicated metrics port, initially proposed as TCP 9126 after a live
conflict check. Authenticate all metrics requests with a separate random bearer
token. The Pi reaches it through Tailscale at 100.75.116.65. A published HAOS port
can also be reachable on LAN: do not claim it is tailnet-only merely because
Prometheus uses Tailscale. Require authentication on every interface, do not
configure router forwarding or Funnel, and apply existing network policy where
available. The collector endpoint must not expose a management API.

Use HAOS app private storage for local credentials. Store the Pi's copy of the
metrics token in its existing SOPS telemetry secret file and install it readable
only by Prometheus. Do not put credentials in Git, the Nix store, URLs, CLI
arguments, screenshots, or logs. User-provided application credentials must be
entered through a private local setup path, not pasted into the conversation.

## Metrics contract

Poll Supervisor every 30 seconds with bounded request timeouts and concurrency.
Serve snapshots rather than making an unbounded fan-out during every scrape.
Use seconds and bytes; convert Supervisor disk GB values using the API's actual
unit definition, verified against its source, rather than guessing GiB.

Export only explicit fields:

- Host boot timestamp, disk total/used/free, OS and kernel versions.
- Core and Supervisor state/version/update availability where provided, CPU
  percentage and cumulative CPU time where its unit/meaning is verified, memory
  used/limit, network receive/transmit bytes, and block read/write bytes.
- All installed apps: stable slug, display name, version/latest version,
  update availability, lifecycle state, and the same supported resource stats.
- CPU percentages retain the source's documented normalization. Label dashboards
  accordingly; do not silently divide by the CPU count or cap at 100 percent.
- Source success, last-success timestamp, collection duration, and collector
  process metrics. Represent unsupported fields by absence, not a fabricated 0.

Bound labels to host, component/app slug, state, version, and approved metric
dimensions. Never export container IDs, arbitrary configuration, user/session
identifiers, entity IDs, tag names, monitor URLs, or device names by default.

Use per-source failure isolation. A failure reading one app must not remove
unrelated results. Stop emitting its resource samples when the latest poll fails;
export failure/freshness indicators instead. Discover new apps and remove
uninstalled apps without a collector restart. Stopped apps retain inventory/state
but do not fabricate resource usage or generate a generic 'must be running' alert.
The deliberately stopped Get HACS utility is not an outage.

## Application-specific coverage

Every listed app receives Supervisor inventory/state/resource coverage. Internal
metrics are additional and require an endpoint/configuration check against the
installed version; the following is the discovery matrix, not a claim that all
these exporters already exist or are enabled.

| Installed app | Additional operational coverage / boundary |
| --- | --- |
| Uptime Kuma | Authenticated monitor status, response time, uptime windows, certificate validity/expiry. Retain monitor ID/name/type only; strip arbitrary tags, URLs, hostnames and ports. These are service checks, not home sensor states. |
| Tailscale | Supported daemon/runtime and aggregate connection metrics if accessible without enabling broad network privileges. Do not export peer identities or addresses. |
| Grafana | Native process/runtime, request and database metrics where supported; no user/query text labels. |
| InfluxDB v1 | Runtime/storage/query counters from a supported operational endpoint; never database measurements or query text. |
| Z-Wave JS UI | Runtime/driver/connection aggregate health only where it can be separated from node identities, values and events. Never forward its exporter wholesale. |
| Matter Server | Process/resources/state baseline; protocol runtime counters only if independently supported and free of device-state payloads. |
| OpenThread Border Router | Process/resources/state baseline; aggregate interface/runtime counters if supported. No topology/device identifiers or sensor traffic. |
| Studio Code Server | Process/resources/state baseline; no workspace paths or editing/session activity. |
| ESPHome Device Builder, stable and dev | Process/resources/state baseline; no device entity metrics, firmware secrets or device logs. |
| Get HACS | Inventory and stopped/started state; absence of runtime stats while stopped is expected. |
| Advanced SSH & Web Terminal | Process/resources/state baseline; no session, command, user or shell-history export. |

Collect approved native metrics inside HAOS where possible and expose each source
on a distinct fixed path for central scraping. Use an explicit metric-family and
label allowlist per application, not passthrough plus a short blacklist. Disabled,
unsupported and authentication-required sources appear in the documented coverage
table. Never advertise 'all possible metrics' as permission to weaken privacy or
grant new privileges. Adding a source requiring a service restart/configuration or
credential is an explicit rollout step, not silent discovery side effects.

Do not enable the Core Prometheus integration in the initial phase: Supervisor
provides the operational baseline without granting an exporter entity access.
If Python runtime metrics later justify enabling it, use an explicit entity
deny-all filter verified on the installed Core version and a metric-family
allowlist. Merely dropping entities at Prometheus ingestion is not sufficient
to prevent their exposure from Home Assistant.

## Central integration and dashboards

Add `modules/fleet/home-assistant-telemetry.nix` alongside NAS telemetry and wire
it into `modules/roles/observability.nix`. Enable it only for hl-node-00, with
runtime credentials declared in `hosts/hl-node-00/default.nix`. Use separate
jobs for platform and native application sources, a 60-second scrape interval,
timeouts shorter than the interval, sample limits and `host_name=homeassistant`.
Do not route these through the dimension-stripping OTLP gateway or duplicate
their ingestion through two paths.

Provision three dashboards using the existing Prometheus datasource:

1. **Home Assistant operations:** collection health/freshness, Core/Supervisor
   state and resources, boot age, disk capacity and version/update inventory.
2. **Home Assistant apps:** installed/stopped/running inventory, updates,
   selectable resource charts and a collection coverage/status table.
3. **Uptime Kuma:** selectable monitors, state, latency, uptime windows and
   certificate expiry/validity. Show other native app sections only when their
   actual metrics and units have been verified; document unsupported coverage.

Distinguish scrape reachability from successful upstream collection. No-data and
stale-source states must be visible and never mapped to green or zero. Use
existing alert patterns for collector unavailability, stale critical collection,
disk pressure and explicitly selected always-on services. Avoid alerting on every
update or duplicating every Kuma notification. Preserve existing dashboards.

## Verification and rollout

- Regression tests through the collector HTTP interface: asymmetric units and
  resource inputs, authenticated/unauthenticated requests, lifecycle transitions,
  one-source failures, malformed/unavailable stats, inventory changes and freshness.
- Privacy fixtures include entity states, tokens, options, arbitrary Kuma tags,
  device names and metric-label values; none may reach allowed output.
- Exercise native exporter filtering with actual captured family names and units,
  sanitized fixtures and unsupported-version failures. Never invent metric names.
- Extend existing evaluation and dashboard-query checks for jobs, secrets,
  distinct source labels, failure states, stopped apps and real query results.
- Build/test the collector on ARM64; validate Nix formatting/lint/evaluation and
  affected observability checks before any publication. Inspect rendered Grafana
  default, selected-app, stopped-app and missing/stale-data views and screenshots.
- After approved installation, verify all installed apps appear, operational
  metrics reach the Pi for multiple polling intervals, Kuma label errors remain
  absent and excluded data never appears. Record sample counts/resource overhead.
- Installing/building the new local app, supplying secrets, changing existing
  app configuration, publishing signed commits, and deployment require scoped
  authorization. Do not restart Core or unrelated apps by default.
- Roll back by disabling the new scrape jobs and stopping/removing only the
  collector after approval; restore any changed application metric settings and
  revoke dedicated credentials. Existing Home Assistant behavior is unchanged.

## Delivery and limitations

Implementation includes collector/app packaging, Pi configuration, dashboards,
coverage documentation, tests and a setup/runbook. This design does not authorize
sensor metrics, log shipping, tracing, a replacement HAOS installation, application
upgrades or fixes to unrelated CI failures. Hardware temperature, complete host
CPU/memory, SMART and low-level device statistics are not promised by the
Supervisor endpoints observed so far. Document missing capabilities instead of
installing privileged host collectors without a separate decision.

## Reference contracts

- HAOS app permissions: https://developers.home-assistant.io/docs/apps/configuration/
- Supervisor role access: `supervisor/api/middleware/security.py` in
  https://github.com/home-assistant/supervisor (verify installed-version behavior).
- Core Prometheus integration: https://www.home-assistant.io/integrations/prometheus/
- Kuma exporter: https://github.com/louislam/uptime-kuma/blob/2.5.6/server/prometheus.js
- Local patterns: `modules/fleet/nas-telemetry.nix`,
  `modules/roles/observability.nix`, `checks/dashboard-queries.py`.
