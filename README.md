# NixOS Homelab Fleet

Declarative NixOS configurations for five homelab nodes, replacing the previous
OpenTofu/Kubernetes/Argo CD deployment. Comin builds and activates signed Git
revisions; applications run as native services or rootful Podman containers.
Databases and application configuration stay local to their consuming host.
Large shared libraries remain on TrueNAS NFS, reached over Tailscale.

## Fleet

| Node | Hardware / LAN address | Workloads |
| --- | --- | --- |
| `hl-node-00` | Raspberry Pi 5, 8 GiB / `10.15.4.6` | OpenTelemetry gateway, Prometheus, Loki, Tempo, Grafana; telemetry on a powered SSD |
| `hl-node-01` | Raspberry Pi 5, 16 GiB / `10.15.4.4` | Pocket ID, Mailrise, Homarr, Donetick, CommaFeed, Wallos |
| `hl-node-02` | Framework / `10.15.4.5` | Immich, Mealie, Tuwunel, Forgejo, Foundry, Tangled Knot, Tranquil PDS; one Forgejo runner |
| `hl-node-03` | Framework / `10.15.4.7` | Jellyfin, Kavita, Vikunja; one Forgejo runner |
| `hl-node-04` | Framework / `10.15.4.9` | Deluge with Gluetun/port manager, Prowlarr, Radarr, Sonarr, Whisparr, SABnzbd, publication-manager; one Forgejo runner |

Host identities are independent of their roles. Placement, addresses, permanent
NIC identities, and installation-disk pins are defined in
[`lib/fleet-topology.nix`](lib/fleet-topology.nix). Switch ports use **native VLAN
4**: the hosts send untagged traffic, not an additional tagged VLAN interface.
Framework NICs form active-backup bonds with stable `lan0`/`lan1` names.

Public HTTP routes use Cloudflare connectors/Caddy; tailnet routes use Tailscale
service identities. Each host runs telemetry collection, and dashboards/alerts
are managed here rather than edited only in Grafana.

## Repository layout

- `flake.nix`, `flake.lock`: fleet outputs and pinned Nix dependencies.
- `hosts/<node>/`: hardware, networking, enrollment, and host-specific overrides.
- `modules/roles/`: select workloads for a role.
- `modules/services/<service>/default.nix`: each application's container, local
  database, persistent state, backup/restore contract, and ingress.
- Grouped `*-applications.nix` and `media-automation.nix` modules: compatibility
  aggregators that import and enable individual services. Existing group options
  still work; an individual `services.fleet.<service>.enable = false` overrides
  its group's default. Deluge owns its tightly coupled VPN and port manager.
- `modules/fleet/`: shared deployment, storage, secrets, ingress, telemetry, and
  recovery infrastructure. `prepared-applications.nix` and node02's `cutover.nix`
  still provide live enrollment/startup configuration despite their names.
- `installers/`: host-specific bootstrap media and installation guards.
- `packages/`: custom tools and dependency corrections; `lib/`: shared helpers.
- `secrets/`, `.sops.yaml`: encrypted secrets and age recipient policies.
- `checks/`, `.github/`: configuration/VM tests and scoped CI builds.
- `dashboards/`, `alerts/`: observability definitions.
- `docs/runbooks/`: installation, enrollment, backup/restore, and service guidance.
  Migration inventories and old wave/rehearsal documents are historical evidence,
  not the source of truth for current placement or application versions.

## Deployment and operations

Comin polls the GitHub remote every 60 seconds. It switches from signed `main`
and can test a signed `testing-<hostname>` branch without selecting it as the
normal boot generation. A Tangled fallback is configured where
`fleet.comin.enableMirror` is enabled; keep its policy/revision consistent with
GitHub. **Comin does not wait for GitHub Actions**: validate before publishing a
deployment commit. CI validates/builds; it does not perform the activation.

After local validation, publish with Jujutsu and an authorized SSH signing key:

```sh
jj describe -m 'fix(mealie): update pinned image'
jj --config 'signing.backend="ssh"' \
  --config "signing.key=\"$HOME/.ssh/id_ed25519.pub\"" sign -r @
jj bookmark set main -r @
jj git push --bookmark main
```

The signer must match `modules/fleet/comin.nix`; do not disable signature checks
or remove Jujutsu change IDs to work around a verification failure. Inspect
`journalctl -u comin`, `systemctl --failed`, and `journalctl -u podman-<service>`
on the affected node after deployment. Comin metrics are on port 4243, restricted
to the observability node. A retained NixOS generation can roll back system
configuration, but **does not roll back an application's migrated database**.

Secrets use sops-nix with each host's real SSH-derived age recipient, not a
per-machine 1Password login. Never put plaintext secrets, host private keys, or
licensed application archives into Git or the Nix store. See
[host enrollment and credential rotation](docs/runbooks/enroll-host.md).

Backups are automatic, with isolated encrypted Restic repositories per host
backed by Garage/S3. Jobs stage consistent database exports or quiesced state,
validate payloads, and publish health metrics. Before an application upgrade,
run its relevant backup jobs on that host and confirm success, for example:

```sh
sudo systemctl start fleet-backup-mealie-db.service fleet-backup-mealie-state.service
sudo fleet-restore mealie-db --snapshot latest --rehearsal
```

`--rehearsal` downloads and validates a payload without replacing live state;
it is not a complete application restore test. Actual restore and overwrite
procedures are in the [backup/restore runbook](docs/runbooks/backup-restore.md).
Retain recovery snapshots and application-upgrade rollback data until explicitly
released; disposable installer downloads are not backups.

### Grafana access and service lifecycle

Grafana is available to tailnet clients at
**https://hl-node-00.tailbc181.ts.net/dashboard/**, using the host's existing
Tailscale identity and HTTPS certificate through Caddy. It is not published
through Cloudflare, and port 3000 remains loopback-only. Grafana login is still
required; the administrator password is stored on node 00 at
`/var/lib/telemetry/grafana/admin-password`.

The **Service lifecycle** dashboard (`service-lifecycle`) filters by host and
systemd service name (regular expression). Its journal-derived starts, stops,
failures and automatic-retry counts cover the selected time range; the event
timeline includes explicit backup/deployment stop/start cycles. Starts include
initial startup, so they are not labeled as restart counts. The default service
filter covers application containers, Tailscale and core monitoring services;
use `.*[.]service` to include other system services and backup jobs.

The sampled automatic-retry graph shows systemd's `NRestarts`, not manual
stop/start cycles. Counters can reset on explicit restarts or reboot, and
short-lived changes between scrapes may be missed. Journal counts also depend
on successful collection and Loki retention: zero received events is not proof
that no interruption occurred during a telemetry outage.

### Dashboard telemetry and limitations

The Fleet, Comin, PostgreSQL, Ingress, Storage and Backups dashboards use
host selectors and the detailed direct-agent scrape jobs. The OTLP gateway
also exports some of these metrics, but intentionally strips dimensions;
combining both sources would double-count samples or merge different jobs.
An absent series means **unknown/not recorded**, never an implicit success.

- **Fleet:** failed systemd units stay separated by host. A read-only Podman
  collector reports actual running/present state for configured application
  containers, excluding ephemeral CI containers. Failed or older-than-three-minute
  collector results are not used as container state. The freshness window allows
  for the 30-second collector timer and two one-minute scrape stages.
- **Comin:** reports the exporter's real deployment information, last-operation
  failure gauges, suspension/reboot flags and fetch counter. Distinct deployed
  revisions indicate rollout consistency, **not lag against remote main**.
- **PostgreSQL:** each stock/isolated local cluster has a loopback exporter with
  a dedicated peer-authenticated `fleet-pg-monitor` role granted `pg_monitor`,
  without application passwords or write privileges. Panels show connectivity,
  database bytes, transaction rates and connections, by host/cluster/database.
- **Ingress:** central HTTPS probes cover concrete public inventory routes
  (not wildcards), with real Matrix/PDS health paths. TLS validation remains on;
  anonymous 401/403 challenges count as reachable, not proof of authenticated
  application health. Local Caddy/cloudflared metrics and aggregate Tailscale
  LocalAPI status are separate. Tailscale collection is read-only, includes host
  and proxy identities, exports no peer names/addresses, and hides stale state.
- **Storage:** filesystem capacity, NFS server operations and temperatures use
  actual exporter names and separate units. Loopback smartctl polling does not
  wake standby disks. **SMART status/temperature are the last reported values**:
  the exporter can retain cached device data on polling errors. Missing device
  data or zero discovered devices may mean unsupported hardware/bridges or a
  scan failure, not healthy disks. Client-only hosts have no NFS server metrics.
- **Garage is not configured:** no managed Garage server or metrics endpoint is
  defined here. Identify its host/version, enable authenticated admin metrics,
  provision credentials through SOPS, add a private scrape target, then verify
  the actual metric names before replacing the dashboard's setup notice.
- **Backups:** preserve host, backup job and class; age/duration use seconds and
  size uses bytes. Actual restores and rehearsals are separate. “Not recorded”
  does not establish recoverability; a rehearsal is not a full application test.

### Backup availability and remaining investigation

SQLite snapshots keep Pocket ID, Donetick, Homarr, Wallos, Jellyfin, Kavita,
Prowlarr, Radarr, Sonarr and Whisparr online during their hourly backups. Each
database is captured through SQLite's backup API and integrity-checked; live
database sidecars are excluded. Tuwunel uses an hourly native RocksDB checkpoint
and waits for completion before copying it. Mealie, Vikunja and Tranquil PDS keep
running during their hourly PostgreSQL dumps and daily file captures.

These database snapshots are consistent individually, **not atomic with one
another or with accompanying assets/media**. File changes or deletions during
capture can require reconciliation after restore. For a coordinated recovery
point before a migration, stop writers explicitly and capture all related jobs.
Restores still stop services; online backup does not mean online restore.

Tailscale proxy identity backups also stay online. They capture the daemon's
atomically persisted state map, validate its current-profile/key linkage, and
omit logs and renewable certificate caches. Restore reissues cached certificates;
revoked/expired identities may need reauthentication. Tailnet Lock authority
storage is not supported by this capture and causes it to fail closed.

The following backups still stop their applications. They run **once daily at
6:00 AM Pacific** (`America/Los_Angeles`, including daylight saving time), with
no random delay or missed-run catch-up at boot. Jobs on one host serialize, so
some interruptions begin after 6 AM. Manual backups/forced restores can interrupt
services at other times. Daily jobs alert when stale beyond 26 hours; hourly
database jobs retain the 90-minute threshold, and failures still alert separately.

| Application | Why it still stops / investigation needed |
| --- | --- |
| CommaFeed | Embedded H2, not SQLite. Investigate access to its running connection for native `BACKUP TO` and test recovery. |
| publication-manager | Multiple SQLite run databases plus pipeline/run files. Investigate a coordinated application-level export, not independent live copies. |
| SABnzbd | Queue, history, administrative state and in-flight downloads need a coordinated save/export and restore test. |
| Forgejo | PostgreSQL dumps remain hourly and online; daily repository/config capture stops Forgejo. Investigate Git/repository and DB coordination, including externally stored objects. |
| Tangled Knot | Repositories and identity/metadata files need a coordinated export while writes are active. |
| Foundry | Active worlds use LevelDB; native backups require unloading the world. Retain interruption until a verified alternative exists. |
| Deluge | Session/torrent/fast-resume state needs a coordinated save with download state. The daily capture also stops its port manager, but not Gluetun. |

## Updating versions

### Container applications

Images are pinned by **digest**, not mutable `latest` tags. Change the `image`
in `modules/services/<service>/default.nix`. Updating `flake.lock` alone does
not update these images. The Forgejo runner's job image label is a separate
setting in `modules/services/forgejo-runner/default.nix`, currently `act-latest`.

1. Read the application's release/migration notes and create fresh backups.
2. Resolve the intended release tag to its registry digest, for example:

   ```sh
   # Substitute the desired real release tag.
   image=ghcr.io/mealie-recipes/mealie:vX.Y.Z
   nix shell --inputs-from . nixpkgs#skopeo -c \
     skopeo inspect --format '{{.Digest}}' "docker://$image"
   ```

   Check supported platforms before choosing the digest: Pi services need
   `linux/arm64`, Framework services need `linux/amd64`. A manifest-list digest
   can cover both; a platform-specific digest cannot. Private registries require
   runtime authentication, never a token embedded in the Nix expression.
3. Replace the repository/digest pin and adjust configuration required by the
   release. Keep Immich server and machine-learning images on the same release.
   Update version expectations in existing checks when they deliberately pin a
   release; leave historical source inventories unchanged.
4. Format, evaluate/build the affected host, then publish a signed commit.
   Verify the service, logs, authentication, and backups after Comin switches.

Do not update managed application binaries from inside a running container.
Rollback after a schema migration may require restoring the pre-upgrade database
and state as well as the previous image.

### NixOS, native services, and flake inputs

NixOS, native observability tools, Forgejo runner, and ordinary Nix packages
follow the locked `nixpkgs` input. Hardware profiles, Disko, sops-nix, and Comin
have their own flake inputs. Update deliberately and review `flake.lock`:

```sh
nix flake update nixpkgs         # OS and nixpkgs-provided packages
nix flake update comin           # one other input
# nix flake update              # all inputs; broader upgrade
jj diff flake.lock
```

Shared-input changes affect the whole fleet, so validate both architectures and
all affected hosts. Custom pins live in `packages/`, notably Immich's PG16
extensions in `immich-postgresql.nix`. Keep the Comin signature-compatibility
correction and Podman archive backport until their upstream replacements are
verified; see [enrollment](docs/runbooks/enroll-host.md) and
[runner troubleshooting](docs/runbooks/forgejo-runners.md).

### PostgreSQL major upgrades

The package selections (`postgresql_16`, `_17`, `_18`) are in the owning service
modules/custom packages. Updating nixpkgs normally updates that selected major;
changing the selection to another major is a **data migration**, not an image
bump. Make verified logical backups, check required extensions, plan a supported
dump/restore or `pg_upgrade`, and retain the old data/major for rollback. Never
point a new major at the existing data directory without a migration procedure.

### Foundry VTT

The Foundry module pins the **Node runtime image**. The licensed Foundry app is
installed separately under `/var/lib/foundry/app`, with user data under
`/var/lib/foundry/data`; it is not bundled into the repository or installer.
The current app is 14.369 with Node 24. For a future update, obtain the licensed
Node ZIP, confirm the required Node range and system/module compatibility, take
a cold backup of app and data, stop Foundry, install the new app preserving its
configuration/license, and start/test it. Changing the runtime image alone does
not update Foundry. Downgrading after world migration requires the old app
**and** pre-migration data. Keep `/var/lib/hlr/foundry-upgrade-14.369/` as recovery
material until it is explicitly released.

## Validation

Use focused checks while iterating, then the full suite for shared changes:

```sh
nix fmt -- --check .
nix run .#statix -- check .
nix run .#deadnix -- --fail .
nix flake check --no-build --show-trace
nix build --no-link .#nixosConfigurations.hl-node-02.config.system.build.toplevel
# Existing grouped-service contracts (choose the matching architecture).
nix build --no-link .#checks.x86_64-linux.remaining-services
```

Full VM checks require a Linux host with readable/writable `/dev/kvm`:

```console
nix flake check --show-trace
```

Build Pi closures/images on native AArch64 and Framework closures/images on
x86_64. For first installation or replacement hardware, use the
[Framework](docs/runbooks/install-framework.md) or
[Pi](docs/runbooks/install-pi.md) runbook and reverify physical identities and
recovery-key escrow; ordinary service updates do not require reflashing.

## CI scope and image builds

Batch locally validated preparation changes into one push per meaningful
milestone; do not weaken signed deployment policy to avoid CI latency.
The shared `.github/scripts/ci-scope.py` selector uses the entire push
`before...after` range or the paginated PR changed-files list (including old
rename paths). A new branch compares against the repository default branch
when available. Missing history, API errors, truncated results and unknown
paths conservatively select all checks, closures and images.

| Changes | Architecture checks / closures | Automatic images |
| --- | --- | --- |
| `docs/`, README, AGENTS only | None | None |
| `hosts/<node>/`, `secrets/hosts/<node>/` | Node architecture / node closure | None |
| Shared modules, packages, lib, checks, flake inputs, secrets policy, CI | Both / all five | None |
| Framework installer files | Both / all five | All three Framework images |
| Pi installer or Pi hardware module | Both / all five | Both Pi images |
| Shared installer files | Both / all five | All images |
| Unknown paths or incomplete discovery | Both / all five | All images |

Selected architectures retain their full existing check commands and KVM
requirements. Empty selections skip build jobs, not an assertion that an
image is fresh or installation-ready. Normal application and secret changes
do not request new installer images. Existing image packaging, provenance,
warnings and artifact retention are unchanged.

For an explicitly needed image, open **Actions → images → Run workflow**,
choose the revision and `host`: `all` or one canonical ID (`hl-node-00`
through `hl-node-04`). One host selects only its image, regardless of changed
paths; `all` selects all five. This builds artifacts only, not deployment.

Local selector and packaging fixtures:

```console
python3 .github/tests/ci-scope.py
bash .github/tests/framework-packaging.sh
actionlint .github/workflows/checks.yml .github/workflows/images.yml
```
