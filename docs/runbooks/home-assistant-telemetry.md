# Home Assistant operational telemetry: setup and source contracts

Discovery and baseline acceptance date: 2026-10-25. **Collector 0.1.2 is installed
and running on HAOS with Protection mode on; central baseline scraping is enabled
in hl-node-00's configuration. Native Kuma, Grafana and InfluxDB collection is
enabled on HAOS; their central jobs are prepared locally but not yet published.**
The source observations below are discovery evidence;
baseline acceptance is recorded separately below. Follow the approved
[privacy and privilege boundary](../superpowers/specs/2026-10-25-home-assistant-operational-telemetry-design.md).
No app was installed, configured, restarted, or upgraded during discovery.

### Current rollout status

Native setup on 2026-10-26 exposed a collector parsing defect: Go exporters expose
both the approved `go_memstats_alloc_bytes` gauge and an unrelated
`go_memstats_alloc_bytes_total` counter. Python's parser normalizes their names;
0.1.2 preserves declared counter identity so the unknown counter cannot reject
the valid gauge. The allowlist and strict rejection of wrong types are unchanged.
Only the collector was updated/restarted; Grafana and InfluxDB required no settings
changes or restarts. The operator subsequently entered a dedicated Kuma API key
privately into HAOS; authenticated upstream access passed and Kuma was enabled
with a collector-only restart. The Kuma key remains on HAOS, separate from the
central Bearer token. Central native publication remains pending.
No sensor/entity integration was enabled.

Four live observations across 97 seconds retained all 19 healthy baseline sources,
eight label-free Grafana samples and five label-free InfluxDB samples. Node00
authenticated successfully to both filtered endpoints over Tailscale. The native
jobs are not yet centrally scraped; source readiness is not dashboard acceptance.

Native ARM64 collector image/runtime passed; the earlier node00 closure build
passed without activation and predates the central host preparation below.
The separately approved collector-only HAOS installation passed live
authentication and baseline checks: all four paths reject anonymous/wrong tokens
on LAN and Tailscale, and 19 baseline sources remained healthy across three
30-second polling intervals. Inventory contains all 13 installed apps, including
the collector; resources cover only the 12 running apps. Stopped Get HACS remains
in inventory without fabricated resources. Live exposition passed promtool.

Version 0.1.1 isolates the disposable HTTP transport from the metrics runtime,
avoiding a full collector/Prometheus import per request. Matched live measurements
over approximately 180 seconds of container stats each reduced CPU from **0.512
to 0.196 cores**, approximately **62%**, including transport children. That is
12.8% → 4.9% of this four-core Pi's capacity. Sampled container memory changed
from 34–66 MiB to about 25 MiB. All 262 samples and 19 healthy baseline sources
remained present; polling, authentication and five-second cancellation are unchanged.
These short observations are not steady-state guarantees or acceptance of future
native-source overhead. Parent CPU metrics alone substantially understate total
cost; continue measuring the whole container during each rollout stage.

The scrape token was generated and entered privately through Supervisor's options
API. Its ciphertext is now prepared locally in
`secrets/hosts/hl-node-00/home-assistant-telemetry.yaml`, with only the existing
administrator/node00 recipients. The Garage secret file remains byte-for-byte
unchanged. Node00 successfully decrypted/verified this file and used its token for
an authenticated tailnet scrape with all 19 baseline sources healthy; this was an
in-memory preflight, not secret installation or central Prometheus activation.
No plaintext staging remains; an encrypted recovery copy is retained privately.

The host declaration below enables exactly one baseline job with the intended
runtime token path, no native sources and no required-app alerts. Central baseline
publication/normal Comin activation was separately approved after the disabled
preparation and authenticated preflight. Build the updated host closure before
publication and verify the actual running revision, central scrapes and dashboards
after activation. Native-source approval remains a separate gate; do not change
existing apps or their authentication/settings as part of baseline deployment.

## Approval gates and local validation

This runbook describes future operator actions, **not authorization to execute
them**. Keep `fleet.observability.homeAssistant.enable` false on hl-node-00 until
the collector, matching encrypted token, and validation are all in place. No
sensor/entity export, Core Prometheus integration, log shipping, or automation
changes belong to this rollout. Future sensor monitoring needs a separate design.

Request approval separately for:

1. Native ARM64 collector image build/runtime test on a suitable builder, and
   hl-node-00 system closure build, using the current reviewed source. x86_64
   tests and ARM evaluation do not satisfy these native execution gates.
2. Copying only `packages/home-assistant-telemetry/` into HAOS local apps,
   building/installing **only** `local_home_assistant_telemetry`, granting its
   manager role with Protection mode on, mapping TCP 9126, and starting it.
3. Generating/privately entering a separate scrape token; staging its dedicated
   encrypted node00 SOPS file; creating a dedicated Kuma API
   key after reviewing effects on existing API consumers. Never use account
   passwords, browser sessions or Supervisor tokens as scrape credentials.
4. Enabling each selected collector native source and its central job only after
   validation. Grafana/InfluxDB need no exporter setting or restart under the
   discovered configuration. The collector needs restart after options changes.
   Optional Grafana Basic-auth settings would require **restarting the existing
   HAOS Grafana app**, a separate interruption approval; this collector has no
   Grafana/InfluxDB credential option, so leave that alternative deferred.
   Do not change InfluxDB authentication or restart it. Kuma API-key creation
   needs no restart; a new Kuma tag schema can require **restarting Uptime Kuma**,
   but tags are stripped here and that unrelated restart is not requested.
5. After pre-activation validation below, signed jj publication of the Pi
   configuration, SOPS declaration and encrypted token, and activation via normal
   Comin policy, followed by central scrape/dashboard acceptance below.
   Publication can deploy immediately: Comin does not wait for CI. Do not push,
   start deployment workflows, install, or restart anything merely to prepare docs.

Local synthetic checks (not live rollout evidence):

```sh
nix build --no-link -L .#checks.x86_64-linux.home-assistant-telemetry-http \
  .#checks.x86_64-linux.home-assistant-telemetry \
  .#checks.x86_64-linux.dashboard-queries
nix flake check --no-build --all-systems
# Native ARM64 acceptance on an approved builder; build only, never activate:
nix build --no-link .#nixosConfigurations.hl-node-00.config.system.build.toplevel
```

Run repository formatting/lints and affected observability regression checks
before publication too; record exact revision and results. Report any pre-existing
unrelated CI failure separately without weakening it. Local tests cannot establish
actual LAN/tailnet authorization, manager access, ARM runtime, or dashboard renders.

## Local HAOS app installation (after explicit approval)

Packaging is version **0.1.2**, aarch64 only, built locally from its Dockerfile
(there is no published image to install). Retain the digest-pinned Python base
and hash-pinned `prometheus-client==0.25.0`; do not replace with mutable tags or
unlocked dependencies. Recheck upstream compatibility when updating any pin.

1. Record the reviewed revision with `jj log -r @ --no-graph`, installed platform
   and app versions, and current settings needed for rollback. Confirm TCP 9126
   is still unused with `ss -ltn` and HAOS app port mappings; discovery did not
   reserve it. Stop on conflict rather than changing an unrelated app.
2. Using the authenticated HAOS SSH app's existing `/addons` access, create
   `/addons/local/home-assistant-telemetry` and copy **only** the contents of
   `packages/home-assistant-telemetry/`, including `.dockerignore`, there. No
   credentials go in this source directory, image build context or Dockerfile.
   If the existing SSH app cannot access `/addons`, use an already authorized
   local file-management path or stop for approval; do not grant new mounts or
   disable Protection mode to work around it.
3. In Settings → Apps → App Store, reload/check for updates; open Local apps →
   **Home Assistant Operational Telemetry** and Install (local ARM64 build).
   Verified CLI equivalents on the installed release are `ha store reload`, then
   `ha apps install local_home_assistant_telemetry`; confirm these subcommands
   with `ha store --help` and `ha apps --help` before use. Do not update/install
   other apps. The existing SSH user needs its already-configured sudo access to
   write the root-owned `/addons` directory; do not change ownership or privileges.
4. Verify Protection mode remains on and the manifest requests manager API access
   only, not Core/Docker API, host networking/PID/D-Bus, mounts or journal access.
   Manager permits writes despite GET-only collector code; accept this risk
   explicitly. Set the private options below before Start. Keep native flags
   false initially. Enable the 9126 mapping only under the approved network policy.
5. Start only this app (UI Start or
   `ha apps start local_home_assistant_telemetry`). Confirm baseline inventory and
   stats with the collector's own token/permissions, not the existing SSH app's
   token. Never extract or print `SUPERVISOR_TOKEN`; it is injected by HAOS and
   stays there. Review sanitized startup status, never dump app info/options.

### Private token and native-key entry

Only after secret-setup approval, use a private workstation directory outside
the checkout on encrypted storage or a private runtime filesystem, mode 0700,
with `umask 077` and shell tracing off. Generate a random 32-byte token into a
mode-0600 file (for example `openssl rand -hex 32 > "$private/metrics-token"`,
where `$private` names that directory). Do not print it or put it in shell
arguments/history. This command is an instruction, not an action performed here.

Use a local editor/private UI to transfer the value into the collector's
authenticated Configuration field `metrics_token`. Actual supported options:

| Option | Initial value / private storage |
| --- | --- |
| `metrics_token` | Required nonempty random bearer token, no committed default. |
| `native_kuma` | `false`; set `true` only with approved dedicated key. |
| `native_grafana` | `false`; set `true` after internal endpoint validation. |
| `native_influxdb` | `false`; set `true` after internal endpoint validation. |
| `kuma_api_key` | Optional dedicated `uk<ID>_<random>` key; omit until available. |

HAOS stores these options in the app-private `/data/options.json`. The collector
reads this file **once at startup**; saving changes requires restarting only the
collector. It does not accept token-file paths as options or provide a setup API.
There is no shared secret mount to create. Private setup files are staging only;
use the authenticated app Configuration UI or Supervisor's supported options API
for final entry. On Supervisor 2026.10.3 the latter is POST
`/addons/local_home_assistant_telemetry/options` with an `options` object. Use only
the existing authorized SSH manager app, private runtime payload/header files and
checked API results; keep its Supervisor credential on HAOS. This is a Supervisor
API, not an endpoint implemented by the collector. The password schema
masks input but does not encrypt options: Supervisor, other manager apps and
backups can read them. Protect backup access and never capture UI values in
screenshots or artifacts.

For future installation or rotation, use an authorized SOPS editor on
`secrets/hosts/hl-node-00/home-assistant-telemetry.yaml` and create/update the
top-level key `homeassistant-metrics-token` with the **same** value from the
private file. Preserve the administrator/node00 recipients; leave Garage's
`telemetry.yaml` untouched. The current ciphertext was promoted unchanged from
private encrypted recovery and validated on node00 without exporting its identity.
Use an editor with no swap/backup/plaintext persistence; never decrypt
to the checkout, use `sops --set` with a secret argument, or paste into chat.
Verify only encrypted ciphertext is in the diff. Do not publish yet. Remove
temporary plaintext/key/header files and clear clipboard buffers after private
entry/verification; deletion is not guaranteed secure erasure on SSDs, hence the
private runtime/encrypted staging requirement. Revoke/rotate on accidental exposure.

### Node00 collection declaration

These stanzas now exist locally in `hosts/hl-node-00/default.nix`; do not add
duplicates or replace existing `sops.secrets`/`fleet` attributes. The baseline and
secret declaration are deployed; native opt-ins below are local preparation,
not central activation. They contain no plaintext value. The secret is alongside
Garage in the `// { ... }` block; collection options are inside the existing
`fleet` block:

```nix
# Inside sops.secrets' existing // { ... } block:
homeassistant-metrics-token = {
  sopsFile = ../../secrets/hosts/hl-node-00/home-assistant-telemetry.yaml;
  owner = "prometheus";
  mode = "0400";
  restartUnits = [ "prometheus.service" ];
};

# Inside fleet = { ... }:
observability.homeAssistant = {
  enable = true; # Approved baseline only; module default remains false.
  target = "100.75.116.65:9126";
  tokenFile = config.sops.secrets.homeassistant-metrics-token.path;
  nativeSources = [ "kuma" "grafana" "influxdb" ]; # Prepared; publication pending.
  requiredApps = [ ]; # Explicit always-on slugs only; never stopped Get HACS.
};
```

Even a disabled declaration requires its encrypted key at activation: do not
publish a declaration referencing a missing secret. Prepare and validate both
together. Add a native source only after it is separately approved and validated.
Default module enablement is false; only node00 opts in.
SOPS creates `/run/secrets/homeassistant-metrics-token`,
owned by Prometheus, mode 0400. Rotation can restart **central Prometheus** via
`restartUnits`; approve that interruption too. Never copy a token into Nix text.

## Rollout evidence, overhead and compatibility gates

The fixed paths are `/metrics` (platform plus collector health) and
`/metrics/kuma`, `/metrics/grafana`, `/metrics/influxdb` (filtered native samples).
Every path requires the same separate Bearer credential. Test anonymous and
wrong-token GETs on **all four paths**, from both LAN and tailnet: expect 401.
With the correct token expect 200; disabled native endpoints can return an empty
200, which is **not** successful upstream collection. For private probes use a
mode-0600 curl header/config file populated through a private editor and
`curl --header @"$private/auth-header" ...`; never use a literal token argument,
verbose traces, or raw metrics captures in shared artifacts. Delete the file.

Published HAOS TCP 9126 can be reachable on LAN. Bearer authentication is not
transport encryption: LAN HTTP exposes credentials/data to the LAN path. Use
the approved tailnet path for normal scraping; Tailscale encrypts that path,
not arbitrary LAN HTTP. Restrict network access with existing policy where
available; no router forwarding, public proxy or Tailscale Funnel. Do not expose
the Supervisor API. LAN verification needs a trusted path and explicit approval.

After approved start/options changes, verify at least **three 30-second polling
cycles** and after central activation **two 60-second scrapes**:

- All installed app slugs appear (discovery: twelve), including stopped Get HACS.
  Inventory success is separate from stats; stopped resources are absent. Verify
  manager-role inventory and running-app stats from the real isolated collector.
- All approved native sources show success and fresh last-success timestamps in
  the platform job; disabled/auth-required/unsupported/failing states remain
  visible. `up=1` proves HTTP reachability only. Partial valid native output can
  remain while source success is 0; use the dashboard's freshness/success gates.
- Confirm counters reset sensibly, byte/second units and asymmetric receive vs
  transmit/read vs write values. Confirm no entity IDs/states, tokens/options,
  URLs/hostnames/ports, device identifiers or arbitrary Kuma tags escape filtering.
  Review locally without retaining raw household payloads or secrets in evidence.
- Inspect Kuma logs privately over a complete monitor interval for new label
  errors. Do not trigger a tag-schema restart as a side effect of verification.
- Inspect rendered Grafana default, selected app/monitor, stopped Get HACS,
  missing and stale-source views; save sanitized screenshots and record dashboard
  UIDs `home-assistant`, `home-assistant-apps`, `uptime-kuma`. Do not call query
  fixtures or uninspected screenshots visual acceptance.

Measure overhead rather than promising a number: record installed/running source
count, sample count per job (`scrape_samples_scraped`,
`scrape_samples_post_metric_relabeling`), `scrape_duration_seconds`, collector
`haos_collector_process_resident_memory_bytes` and rate of
`haos_collector_process_cpu_seconds_total`, plus
`haos_collection_duration_seconds` by source. Take a baseline and observations
over the cycles above; record time window, hardware, revision and native flags.
RSS differs from Supervisor cache-adjusted memory. The short live baseline above
does not replace measurement with native sources and central scraping enabled.
Four polling workers and 1 MiB upstream bodies bound polling.
Each request has one absolute 5-second deadline including process startup, DNS,
connect/TLS, request, status/headers and body. A disposable local Python process
owns the transport and is killed and reaped on timeout, rather than leaving a
blocked worker/socket behind. Credentials use private pipes, not command arguments;
measure child-process overhead as well as the parent metrics above. Many slow
sources can exceed the 30-second target; snapshots expire after 90 seconds.
Scrapes never fan out. The listener admits at most 16 clients before allocating
handler threads; excess connections close without an HTTP response. Each admitted
connection has a 5-second total socket lifetime, including idle/slow-drip request
lines, headers and blocked response writes, enforced by socket shutdown. A full
pool can temporarily reject legitimate scrapes too; authentication cannot reserve
capacity before headers arrive. Clients must retry after capacity is released.
Central jobs use 60s interval, 10s timeout, and sample limits 10000 platform /
20000 per enabled native source. Investigate saturation rather than relaxing
limits blindly or treating missing samples as zero.

Compatibility is verified only against the discovery versions below, not every
future app release. Native Grafana request histograms are **currently omitted**
(no tested privacy-safe aggregation); only its five runtime and three DB gauges
are admitted. InfluxDB admits the five runtime families only, not storage/query
metrics. Kuma retains its six family names and original units, including latest
latency milliseconds and certificate days; dashboards convert latest latency to
seconds. No automatic version-negotiation or version lockout is implemented:
schema/allowlist rejection can fail a source, but a version change alone is not
a safety guarantee. Recheck source families/labels/units, fixtures, permissions,
reachability and rendered views before enabling an upgraded runtime. Do not
broaden an allowlist to hide incompatibility. Unsupported native coverage stays
baseline-only; it is not zero or healthy.

Record the reviewed/delivered revision, local test results, ARM build/runtime and
closure results, approved actions, actual activation revision, source/sample
counts, measured CPU/RSS/duration, screenshot inspection and unresolved gaps.
Configuration enablement alone is not live acceptance: confirm **central baseline
collection after Comin activation**. Central native jobs remain unpublished.
If publication is approved, follow the README's signed jj workflow, not a manual
deployment workflow. If a PR is created, monitor its comments/reviews and exact-head
CI; do not describe an earlier green head as validation of the published revision.

## Rollback (separate execution approval required)

1. Disable `fleet.observability.homeAssistant.enable` (or remove approved native
   jobs from `nativeSources` for a native-only rollback), validate, then publish
   the signed rollback via normal Comin policy. Confirm new jobs/rules disappear;
   existing historical Prometheus data can remain. Do not change other telemetry.
2. Stop only `local_home_assistant_telemetry` in HAOS; disable its watchdog/boot
   auto-start if retaining it, or uninstall only that app and remove its local
   source directory if approved. Confirm 9126 no longer listens. Do not restart
   Core, Supervisor, Tailscale, or unrelated apps.
3. Revoke the dedicated Kuma key in its UI after confirming no other consumer
   uses it; remove local options and staging files. Remove only the new SOPS key
   and declaration together after scrape jobs no longer reference it, preserving
   existing encrypted secrets. Revoke/rotate the shared bearer on both ends if
   it may have leaked. Do not rely on app removal to erase backups.
4. Restore only native exporter settings actually changed under approval. Optional
   Grafana auth restoration requires its own app restart approval; initial rollout
   changes no such settings. Avoid Kuma tag changes/restarts. Record rollback
   revision and validation; a NixOS generation rollback does not remove the HAOS
   app, revoke keys, or undo application state.

## Verified platform and access

HAOS 18.3, Supervisor **2026.10.3**, Core **2026.10.4**, aarch64 Raspberry Pi 4;
four online CPUs. Diagnostic access was the existing protected Advanced SSH app,
using `ssh -o BatchMode=yes homeassistant@10.15.5.251` and `bash -lc` for HA CLI
commands. It has `hassio_api: true`, `hassio_role: manager`, Protection mode on.
GETs to the paths below succeeded using its existing Supervisor token. Docker
access was refused by Protection mode; discovery did not disable it or bypass it.
This proves manager access on the installed release, not that a future collector
has already been installed or granted a token. Default-role denial is verified in
the release source, not by creating another app/token on the live host.

Collector packaging must request `hassio_api: true`, `hassio_role: manager` only.
This role permits writes and lifecycle management as well as GETs: it is **not a
read-only credential**. Do not request `homeassistant_api`, `docker_api`, host
network/PID/D-Bus, journal access, directory mounts, or Protection mode changes.
Use `http://supervisor`, with the local `SUPERVISOR_TOKEN` in an Authorization
Bearer header. Never forward that header to an app or to Prometheus. Never log
headers, response bodies, or options; even app info responses can include secrets
for a manager. Fixed GET paths and explicit field selection are essential.

TCP 9126: no listener in `ss -ltn` in the SSH app's host network namespace; no
installed app network mapping to 9126; HTTP probes to both `127.0.0.1:9126` and
`10.15.5.251:9126` returned curl HTTP `000` (no response). Available **at discovery
time**, not reserved: recheck immediately before installation. A published port
is not necessarily tailnet-only. Require the separate random bearer token on all
collector metrics paths and all interfaces, including native-source paths.

## Supervisor 2026.10.3 API contract

Use the **unprefixed v1** API below. The CLI's new `ha apps` spelling still returns
`data.addons`. Do not substitute `/apps` or assume a v2 envelope. The live
Supervisor reports `supervisor_v2_api: false`. API success is
`{"result":"ok","data":...}`; check both HTTP status and result. A transport
success containing `result: error` is not successful collection.

| GET path | Verified data / collection use |
| --- | --- |
| `/addons` | `data.addons[]`: `slug`, `name`, `version`, `version_latest`, `update_available`, `state`. All twelve installed apps found, including stopped Get HACS. Prefer this inventory over full app info. |
| `/addons/{slug}/info` | Same inventory fields plus internal `ip_address`, `host_network`, `network`, `ingress_port`. Needed only for approved target resolution; do not expose addresses or other fields. Manager responses may contain full `options`; discard immediately. |
| `/addons/{slug}/stats` | Common resource fields below; all eleven started apps succeeded. Stopped Get HACS returned `result: error`, message `App cb646a50_get is not running`. |
| `/core/info` | `version`, `version_latest`, `update_available`. **No lifecycle state field**; `boot` is a boot setting, not running state. |
| `/core/stats` | Common resource fields. No entity API access needed. |
| `/supervisor/info` | `version`, `version_latest`, `update_available`, `healthy`, `supported`. No Supervisor lifecycle state field. Health/support are not process-state enums. |
| `/supervisor/stats` | Common resource fields. |
| `/host/info` | `disk_total`, `disk_used`, `disk_free`, `boot_timestamp`, `kernel`, `operating_system`; nullable values stay absent. Do not export other host fields. |
| `/os/info` | `version`, `version_latest`, `update_available`. Do not expose `data_disk` or boot-slot identifiers. |

`/.+/info` is allowed for the default role, but `/addons` and other apps' stats
require manager (or admin). The `self` bypass does not grant global collection.
No Core/Supervisor lifecycle state should be invented from a successful GET.
Use source availability and the fields actually present instead.

### Resource units and semantics

| Input | Meaning / conversion |
| --- | --- |
| `cpu_usage` | Cumulative container CPU **nanoseconds**, since container start; divide by `1e9` to expose seconds counter. Counter can reset. |
| `cpu_system_usage` | System cumulative CPU nanoseconds at sample time; optional internal normalization input, not the container's own CPU time. |
| `online_cpus` | Count; observed 4. Not a multiplier for the published source percentage. |
| `cpu_percent` | v1 windowed `(container CPU delta / system CPU delta) * 100`, rounded to two decimals. **No multiplication by online CPUs** in this release. Retain exactly this normalization; label charts “Supervisor share of system CPU (%)”. Nullable when no measurement window. Do not cap, divide, or manufacture 0. |
| `memory_usage`, `memory_limit` | Bytes. Usage subtracts Docker inactive-file/cache memory; it is not raw RSS. |
| `memory_percent` | Usage / limit * 100, rounded; optional, or derive from verified byte gauges. |
| `network_rx`, `network_tx` | Cumulative bytes, summed over Docker-reported interfaces. Not host-wide traffic. |
| `blk_read`, `blk_write` | Cumulative bytes from Docker block-I/O Read/Write records. |
| `disk_total`, `disk_used`, `disk_free` | **GiB**, rounded to one decimal by Supervisor. Multiply by **`1024**3`**, not `1e9`. They describe the filesystem containing Supervisor data, not a sum of disks. Free is available space; do not recompute as total minus used. |
| `boot_timestamp` | Integer realtime **microseconds since Unix epoch**: divide by `1e6`. Supervisor actually reads systemd **FinishTimestamp**, when queued startup jobs completed, not exact kernel startup. Label as boot-completion timestamp/approximate boot age. Null/zero means unavailable, not epoch 0. |

Important upstream limitation: DockerStats initializes some missing counters to
zero, catches missing network/block fields, and converts missing memory data to
zero. Thus a *present* zero from Supervisor is not proof of full host-network or
block-I/O visibility. Core returned zero network/block values in discovery;
host-network apps can have the same visibility limitation. Do not call these
host NIC totals or assume an idle disk.
Conversely, an absent field or failed stats response must never become a zero.

The v1 stats endpoints without a query parameter obtain windowed CPU percentages.
Adding `?one_shot` (presence alone) makes percentage nullable. V2 always uses
one-shot stats and drops `cpu_percent`. Poll with bounded timeouts/concurrency;
allow time for Docker's windowed sample. Poll every 30 seconds and serve snapshots.
Separate inventory and per-app resource success. Retain stopped inventory but
omit its resources; do not flag intentionally stopped Get HACS as an outage.
On a latest-poll failure omit that source's resource samples and publish failure,
last-success and duration indicators; do not keep stale gauges looking healthy.

### Pinned platform source evidence

All Supervisor links below are pinned to the installed release **2026.10.3**:

- [API route registration](https://github.com/home-assistant/supervisor/blob/2026.10.3/supervisor/api/__init__.py): `/core` around lines 666–685, `/addons` around 766–781, Supervisor around 599–601.
- [Role/security middleware](https://github.com/home-assistant/supervisor/blob/2026.10.3/supervisor/api/middleware/security.py): `_V1_PATTERNS.role_access` and `token_validation`; roles match paths, not a GET-only policy.
- [App inventory/info/stats](https://github.com/home-assistant/supervisor/blob/2026.10.3/supervisor/api/apps.py): inventory around 180–215, secret-aware info around 227–319, `stats_v1` around 464.
- [Core info/stats](https://github.com/home-assistant/supervisor/blob/2026.10.3/supervisor/api/homeassistant.py), [Supervisor info/stats](https://github.com/home-assistant/supervisor/blob/2026.10.3/supervisor/api/supervisor.py), [stats serialization](https://github.com/home-assistant/supervisor/blob/2026.10.3/supervisor/api/utils.py#L142).
- [DockerStats](https://github.com/home-assistant/supervisor/blob/2026.10.3/supervisor/docker/stats.py): `_calc_cpu_usage`, `_calc_cpu_percent`, `_calc_network`, `_calc_block_io` and cache subtraction verify units/normalization/default limitations.
- [Disk calculation](https://github.com/home-assistant/supervisor/blob/2026.10.3/supervisor/hardware/disk.py#L59) explicitly divides by `1024.0**3` and rounds; [host info](https://github.com/home-assistant/supervisor/blob/2026.10.3/supervisor/host/info.py#L105) connects these methods to Supervisor data paths.
- [Systemd timestamp adapter](https://github.com/home-assistant/supervisor/blob/2026.10.3/supervisor/dbus/systemd.py#L183) and [constant](https://github.com/home-assistant/supervisor/blob/2026.10.3/supervisor/dbus/const.py#L127) identify `FinishTimestamp`. [Systemd D-Bus timestamp definition](https://github.com/systemd/systemd/blob/v257/man/org.freedesktop.systemd1.xml#L1754) defines realtime microseconds (reference interface documentation, not a claim about installed systemd version).

## Installed-app coverage and native endpoint access

**Baseline B** = Supervisor inventory/version/update/state plus resource fields
above while running. All rows have B; native metrics are additional, not a
substitute. Addresses below are internal app/HAOS infrastructure addresses, not
home-device addresses. Resolve non-host-network app addresses from Supervisor
info when needed; don't assume allocations survive reinstall. Never send a
Supervisor credential to these targets. Observations were from the existing SSH
app; reachability from the future isolated collector still requires rollout
verification. Ingress 403 is not exporter support or an invitation to spoof the
Supervisor ingress source.

| App / stable slug | Installed app → packaged runtime | Baseline | Native observation, auth, and required rollout action |
| --- | --- | --- | --- |
| Uptime Kuma / `a0d7b954_uptime-kuma` | 0.19.4 → **2.5.6** | B; started | `http://172.30.33.4:3001/metrics` **401** unauthenticated. Supported six monitor families below, source-verified but authenticated live samples unavailable. Published LAN port 3001 already exists. Requires operator-created dedicated API key, private entry into collector; no password/session scraping. Creating key enables API-key mode without a Kuma restart. |
| Tailscale / `a0d7b954_tailscale` | 0.30.4 → **1.104.2** | B; started | No supported remote scrape exposed by installed app configuration. Host `:9002/metrics` has no response; ingress `:62896/metrics` 403. `tailscale metrics print` uses daemon LocalAPI/socket, not a freely accessible HTTP exporter. Collector has no shared socket/exec access. Optional daemon debug server is not configured in app launcher and exposes more than metrics; **do not enable** for this project. Native unavailable within current packaging/boundary; no Tailscale config changes. |
| Grafana / `a0d7b954_grafana` | 13.0.4 → **13.2.4** (also live `/api/health`) | B; started | `http://172.30.33.2:3000/metrics` **200**, no credentials; native runtime, request and DB families verified below. Port 3000 is internal, not a host mapping. Ingress 1337 returns 403; port 80 no response. No configuration/restart needed for current metrics. Optional native Basic auth via `GF_METRICS_BASIC_AUTH_USERNAME/PASSWORD` through app `env_vars` requires explicit configuration/restart approval, not assumed present. |
| InfluxDB v1 / `a0d7b954_influxdb` | 6.0.0 → **1.13.1** (also live `X-Influxdb-Version`) | B; started | `http://172.30.33.1:8086/metrics` **200**, no credentials despite `auth: true`; current `ssl: false`. Runtime/process families verified. `/metrics` auth is tied to `AuthEnabled && PingAuthEnabled` upstream, not query auth alone. No configuration/restart needed. Dedicated storage/query Prometheus families were **not present**. Do not query measurements or forward `/debug/vars`; broader storage/query coverage unverified/deferred. |
| Z-Wave JS UI / `a0d7b954_zwavejs2mqtt` | 7.8.1 → **11.25.1** | B; started | Ingress `:8099/metrics` 403; actual backend `http://172.30.33.0:44920/metrics` 301 (not Prometheus). Launcher sets `PORT=44920`, nginx upstream is loopback 44920. No Prometheus route/metric module established in pinned source. Authenticated UI/socket statistics are not a verified device-free exporter. Native unsupported/unverified; no new credentials, sessions, driver/node payloads, or config changes authorized. |
| Matter Server / `core_matter_server` | 9.2.0 | B; started | `http://172.30.32.1:5580/metrics` **404**. No supported operational Prometheus endpoint established from installed app configuration. WebSocket device API is out of scope. Native unavailable; baseline only, no changes. |
| OpenThread Border Router / `core_openthread_border_router` | 3.3.0 | B; started | `http://172.30.32.1:8081/metrics` **404**; 8081 is REST API, not a verified Prometheus exporter. No Prometheus implementation established in pinned OTBR tree. Topology/device REST payloads are not allowed. Native unavailable; aggregate REST/CLI work deferred, no privileges or changes. |
| Studio Code Server / `a0d7b954_vscode` | 7.2.0 → **code-server 4.139.1** | B; started | Internal ingress `http://172.30.33.3:1337/metrics` **404**. No verified app-supported operational exporter/config option. Baseline only; no workspace/session access. |
| ESPHome Device Builder / `5c53de3b_esphome` | 2026.10.0 | B; started | Host ingress `:62731/metrics` **403**; direct 6052 host mapping disabled. No verified Builder operational exporter. ESPHome firmware `prometheus` component is **device/entity** export, not Builder monitoring; prohibited here. Native unavailable; do not enable direct unauthenticated dashboard access. |
| ESPHome Device Builder (dev) / `5c53de3b_esphome-dev` | 2026.11.0-dev20261025 | B; started | Host ingress `:62248/metrics` **403**; same restriction as stable. Exact dev runtime exporter source not verified; do not borrow a firmware or stable-version family contract. Baseline only. |
| Get HACS / `cb646a50_get` | 1.3.1 | B inventory; **stopped**, stats error expected | One-shot installer (`startup: once`, `boot: manual`), no network mapping/ingress. No runtime daemon/exporter. Unsupported native; leave stopped. |
| Advanced SSH & Web Terminal / `a0d7b954_ssh` | 24.2.0 | B; started | Host ingress `:65265/metrics` **404**. No verified native operational exporter. Do not collect sessions/history/users or grant Docker access. Baseline only. |

### Core and Supervisor runtime coverage (separate from apps)

Core: Supervisor info/version/update and stats verified; lifecycle state absent.
`http://172.30.32.1:8123/api/prometheus` returned **404**. Do not enable Core
Prometheus or request Core API access for the initial implementation.

Supervisor: info/version/update/healthy/supported and stats verified; no lifecycle
state. Neither source implies whole-host CPU/memory, temperature, SMART, or
hardware coverage. The boot-completion timestamp and filesystem capacity are the
only verified host-resource additions in this discovery.

### Verified native families and filtering contract

Kuma 2.5.6 `server/prometheus.js` defines exactly these monitor gauges:

| Family | Unit / approved dimensions |
| --- | --- |
| `monitor_status` | 0 DOWN, 1 UP, 2 PENDING, 3 MAINTENANCE; retain `monitor_id`, `monitor_name`, `monitor_type` only. |
| `monitor_response_time` | Latest milliseconds; upstream uses -1 for unavailable ping. Do not interpret -1 as successful negative latency. If converted to a new seconds metric, divide valid values by 1000 and omit unavailable latency. |
| `monitor_response_time_seconds` | Sliding-window average seconds; same monitor labels plus `window` in **`1d`, `30d`, `365d`**. Do not confuse with the millisecond latest measurement. |
| `monitor_uptime_ratio` | 0–1 ratio; same bounded windows, not percentage. |
| `monitor_cert_days_remaining` | Days, not epoch/seconds; may be absent when TLS information unavailable. Convert days to duration seconds only under a new accurately named family, not an invented expiry timestamp. |
| `monitor_cert_is_valid` | 0/1 validity, may be absent. |

Strip **all** other labels, including arbitrary tag label names/values,
`monitor_url`, `monitor_hostname`, and `monitor_port`. Never forward the exporter
wholesale. Monitor names are an explicitly approved Kuma dimension only; generic
home device names remain forbidden. Validate label/value size and bounded windows;
unknown families/labels do not expand the contract automatically. Upstream tags
are registered at startup; adding new tags can require a Kuma restart, but that
is not authorized by this discovery and is unnecessary for label-stripped export.

Grafana 13.2.4 and InfluxDB 1.13.1 **both live-expose** these exact families with
no application identity labels: `process_cpu_seconds_total` (counter, seconds),
`process_resident_memory_bytes` (gauge), `process_start_time_seconds` (Unix seconds
gauge), `go_goroutines` (count gauge), `go_memstats_alloc_bytes` (bytes gauge).
These five exact families are a conservative initial allowlist; this is not a
`go_*`/`process_*` wildcard permission. Reject unexpected labels on these families.

Additional live Grafana families: `grafana_database_conn_open`,
`grafana_database_conn_idle`, `grafana_database_conn_in_use` (count gauges), and
`grafana_http_request_duration_seconds` (seconds histogram). Database gauges can
be admitted label-free. Request histogram sample labels observed were `handler`,
`method`, `slo_group`, `status_code`, `status_source`, with `le` on buckets. To
admit request metrics, aggregate across disallowed labels (especially handler),
retain only validated bounded method/status-code and histogram `le`, and **sum
colliding series**, not merely delete labels and emit duplicates. If that
aggregation is not implemented/tested, omit this family. Never export user,
datasource, query, folder, URL or environment-info families by wildcard. Grafana
also exposes namespaced duplicates (`grafana_process_*`); do not double-count.
Native storage/query counters for InfluxDB, Z-Wave driver/connection aggregates,
Tailscale connection aggregates, Matter/OTBR protocol counters remain unsupported
in this initial verified contract, not zero or healthy.

## Kuma dedicated API-key workflow (private operator action)

Kuma 2.5.6 `/metrics` uses `apiAuth` HTTP **Basic** authentication. With API-key
mode enabled the **password is the API key**, and username is ignored by the
authorizer (use an empty username). It is not a Bearer key endpoint. When API-key
mode is disabled, Kuma falls back to account-password authentication; that fallback
is explicitly prohibited for the collector. Browser cookies/JWTs are not scrape
credentials. The live 401 alone cannot reveal whether API-key mode is enabled.

1. Operator privately opens Kuma's authenticated Settings → API Keys → Add API
   Key, creates a dedicated named telemetry key with chosen expiry, and copies
   its one-time clear value locally. Do not paste it into chat, repository files,
   shell arguments/history, URLs, logs, screenshots or artifacts.
2. Upstream `addAPIKey` stores a hash, returns `uk<ID>_<random>`, and sets
   `apiKeysEnabled=true` immediately. This may change authentication expectations
   for other existing API consumers; review them before creation. No server restart
   is indicated by this handler. Key can later be disabled/deleted in the same UI.
3. Supported HAOS private entry mechanism in the local packaging: authenticated
   Settings → Apps → collector → Configuration, optional schema field
   `kuma_api_key: password?`, without a committed/default key. HAOS delivers user
   options to the app's private `/data/options.json`; collector reads locally,
   never dumps options, never places key in process arguments/environment exports,
   and uses Basic auth only on its fixed Kuma target. The local collector is
   installed. Set `native_kuma: true` only after private key entry and
   approval. Loading new options requires restarting the collector only; do not
   restart Kuma/Core.
4. Password schema is UI treatment/validation, **not encryption**. Supervisor,
   other manager apps and backups can access options; protect backup handling.
   A stricter file-only private-entry facility would require an explicitly
   implemented setup path, not a shared mount or a new unauthenticated management
   API. No such facility was created or used in discovery.
5. Until a dedicated key is privately supplied and an authenticated scrape verified,
   report Kuma native source as authentication-required/unavailable and keep its
   Supervisor baseline. Do not try account passwords or manufacture fixtures from
   raw household monitors. Use a separate bearer secret for central collector
   access; keep the Kuma key local to HAOS.

## Sanitized fixture examples for the implementer

These are deliberately **synthetic**, not captured household data. Unknown fields
contain recognizable privacy sentinels which must never appear in metrics,
diagnostic errors, logs, labels, or test artifacts. Separate fixtures should cover
missing/null/malformed fields and the stopped stats error, not only happy paths.

```json
{"result":"ok","data":{"addons":[{"slug":"fixture_alpha","name":"Fixture App","version":"1.2.3","version_latest":"1.2.4","update_available":true,"state":"started","options":{"api_key":"SENSITIVE_FIXTURE_ONLY"}},{"slug":"fixture_once","name":"Fixture Utility","version":"2.0","version_latest":"2.0","update_available":false,"state":"stopped"}],"entity_state":"PRIVATE_FIXTURE_ENTITY"}}
```

```json
{"result":"ok","data":{"cpu_usage":12345678901,"cpu_system_usage":9876543210123,"online_cpus":4,"cpu_percent":12.34,"memory_usage":123456789,"memory_limit":987654321,"memory_percent":12.5,"network_rx":1111111,"network_tx":2222222,"blk_read":3333333,"blk_write":4444444,"token":"SENSITIVE_FIXTURE_ONLY"}}
```

Expect CPU `12.345678901` seconds; retain CPU percentage `12.34`; do not swap
receive/transmit or read/write. All resource byte inputs stay unchanged.

```json
{"result":"ok","data":{"disk_total":123.4,"disk_used":45.6,"disk_free":70.1,"boot_timestamp":1700000123456789,"kernel":"fixture-kernel","operating_system":"Fixture OS","options":{"password":"SENSITIVE_FIXTURE_ONLY"}}}
```

Expect independent products `123.4 * 1073741824`, `45.6 * 1073741824`,
`70.1 * 1073741824`; do not force free = total - used. Timestamp is
`1700000123.456789` seconds. Preserve numeric precision appropriate to a float.

```text
# TYPE monitor_status gauge
monitor_status{monitor_id="17",monitor_name="Synthetic service",monitor_type="http",monitor_url="https://private.invalid/path?token=SENSITIVE_FIXTURE_ONLY",monitor_hostname="PRIVATE_FIXTURE_DEVICE",monitor_port="443",PrivateTag="PRIVATE_FIXTURE_TAG"} 2
# TYPE monitor_response_time gauge
monitor_response_time{monitor_id="17",monitor_name="Synthetic service",monitor_type="http",monitor_url="https://private.invalid"} 123
# TYPE monitor_response_time_seconds gauge
monitor_response_time_seconds{monitor_id="17",monitor_name="Synthetic service",monitor_type="http",window="30d",PrivateTag="PRIVATE_FIXTURE_TAG"} 0.456
# TYPE monitor_uptime_ratio gauge
monitor_uptime_ratio{monitor_id="17",monitor_name="Synthetic service",monitor_type="http",window="365d"} 0.987
# TYPE monitor_cert_days_remaining gauge
monitor_cert_days_remaining{monitor_id="17",monitor_name="Synthetic service",monitor_type="http"} 19
# TYPE monitor_cert_is_valid gauge
monitor_cert_is_valid{monitor_id="17",monitor_name="Synthetic service",monitor_type="http"} 1
# TYPE forbidden_entity_state gauge
forbidden_entity_state{entity_id="PRIVATE_FIXTURE_ENTITY"} 99
```

Native fixture family names/units match upstream source, but authenticated live
Kuma contents were **not** captured/verified. Do not claim these are live samples.

## App source references and confidence limits

- Community app release-pinned Dockerfiles/configs: [Kuma v0.19.4](https://github.com/hassio-addons/app-uptime-kuma/tree/v0.19.4/uptime-kuma), [Tailscale v0.30.4](https://github.com/hassio-addons/app-tailscale/tree/v0.30.4/tailscale), [Grafana v13.0.4](https://github.com/hassio-addons/app-grafana/tree/v13.0.4/grafana), [InfluxDB v6.0.0](https://github.com/hassio-addons/app-influxdb/tree/v6.0.0/influxdb), [Z-Wave JS UI v7.8.1](https://github.com/hassio-addons/app-zwave-js-ui/tree/v7.8.1/zwave-js-ui), [Studio Code v7.2.0](https://github.com/hassio-addons/app-vscode/tree/v7.2.0/vscode), [SSH v24.2.0](https://github.com/hassio-addons/app-ssh/tree/v24.2.0/ssh). Runtime versions in the table come from their Dockerfile build arguments, with Grafana/InfluxDB additionally live-confirmed.
- Kuma [families/units/windows](https://github.com/louislam/uptime-kuma/blob/2.5.6/server/prometheus.js), [route](https://github.com/louislam/uptime-kuma/blob/2.5.6/server/server.js#L353), [API auth](https://github.com/louislam/uptime-kuma/blob/2.5.6/server/auth.js), [key creation](https://github.com/louislam/uptime-kuma/blob/2.5.6/server/socket-handlers/api-key-socket-handler.js), [Settings API Keys UI](https://github.com/louislam/uptime-kuma/blob/2.5.6/src/components/settings/APIKeys.vue), [one-time key dialog](https://github.com/louislam/uptime-kuma/blob/2.5.6/src/components/APIKeyDialog.vue).
- Tailscale [1.104.2 metrics command](https://github.com/tailscale/tailscale/blob/v1.104.2/cmd/tailscale/cli/metrics.go), [optional debug server](https://github.com/tailscale/tailscale/blob/v1.104.2/cmd/tailscaled/tailscaled.go); app launcher `tailscale/rootfs/etc/s6-overlay/s6-rc.d/tailscaled/run` has no debug-listen flag.
- Grafana [13.2.4 metrics defaults/auth](https://github.com/grafana/grafana/blob/v13.2.4/conf/defaults.ini#L2020); app `grafana/rootfs/etc/grafana/grafana.ini` sets internal HTTP port 3000; `grafana/config.yaml` supports `env_vars` restricted to `GF_*` names.
- InfluxDB [1.13.1 metrics route and authWrapper](https://github.com/influxdata/influxdb/blob/v1.13.1/services/httpd/handler.go#L181): `/metrics` around line 317. It registers the Prometheus runtime handler, not a measurement dump. Live HELP/TYPE confirmed families above; no storage/query counter contract inferred from the product name.
- Z-Wave [11.25.1 router/auth](https://github.com/zwave-js/zwave-js-ui/blob/v11.25.1/api/app.ts); app `zwave-js-ui/rootfs/etc/s6-overlay/s6-rc.d/zwave-js-ui/run` and `rootfs/etc/nginx/includes/upstream.conf` establish actual port. No operational Prometheus contract verified.
- Official app repository snapshot [2c0a216afa3228f66b2993bab6b7981dee807c54](https://github.com/home-assistant/addons/tree/2c0a216afa3228f66b2993bab6b7981dee807c54): `matter_server/config.yaml` says 9.2.0, `openthread_border_router/config.yaml` says 3.3.0, matching installed versions. OTBR `build.yaml` pins stable upstream [fd872ab9d4afdfaf034b3b1154fed08b8b6d1e43](https://github.com/openthread/ot-br-posix/tree/fd872ab9d4afdfaf034b3b1154fed08b8b6d1e43); no Prometheus/metrics source paths found in its tree. This is matching app-source evidence, not image-digest attestation or direct Matter runtime-version verification.
- [ESPHome 2026.10.0 firmware Prometheus component](https://github.com/esphome/esphome/tree/2026.10.0/esphome/components/prometheus) is intentionally excluded. [Builder app configuration](https://github.com/esphome/home-assistant-addon/blob/main/esphome/config.yaml) currently matches installed stable version; mutable reference, not exact dev build verification. Ingress denial prevents establishing native Builder coverage, so neither build gets speculative families.
- [Get HACS config snapshot](https://github.com/hacs/addons/blob/9a6b3a31a387dc35707b67cd248a345afac390d7/get/config.yaml) matches 1.3.1 and confirms one-shot/manual semantics.
- [HAOS app options/private data/schema/roles](https://developers.home-assistant.io/docs/apps/configuration/) documents `/data/options.json`, persistent `/data`, optional `password?` schemas and `hassio_role`. These platform docs are reference documentation, not proof of a collector deployment.

No required baseline coverage needs a privilege-boundary correction. Optional
native endpoints requiring unavailable auth/privileges remain explicitly
unavailable. Rollout must verify cross-app access from the real collector,
authenticated Kuma output, filtering and freshness for multiple poll intervals.
