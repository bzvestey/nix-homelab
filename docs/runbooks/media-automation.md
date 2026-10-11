# Media automation on hl-node-04

Preparation only: do not activate before final source capture, secret enrollment
and bootstrap quarantine removal. `services.fleet.mediaAutomation.enable`
defaults to false; the developer-media-services role imports and enables it.
No source writes or bulk copies are part of this module.

## Source images (observed 2026-10-11)

All nine images are pinned to running Kubernetes imageIDs in the module, not
moving tags. Public digests were independently inspected with skopeo as amd64.

| Component | Observed source version |
| --- | --- |
| Deluge | 2.2.0-ls382 |
| Gluetun | v3.41.1 |
| port manager | v2.0.0, revision 00f3b54d98007142c96b9c4998dde9ea5e24b904 |
| Prowlarr | 2.6.5.5623-ls162 |
| Radarr | 6.4.4.10685-ls318 |
| Sonarr | 4.0.20.3014-ls326 |
| Whisparr | 2.2.0-release.231 (v2) |
| SABnzbd | 5.1.3-ls274 |
| publication-manager | source latest resolved to sha256:861c73bacbe2c632e3f467fb78130bcbbc6fb8e053fb01a816632c347cdf0ad6 |

Private registry inspection without credentials returns authentication required.
Its source imageID is pinned, but independent manifest/version verification and
a runtime authenticated pull remain activation prerequisites. This x86 host
module makes no claim that these platform digests support ARM64.

## Runtime-only secrets and configuration

Supply `/run/secrets/<name>.env` for each of the seven apps, plus
`gluetun.env` and `deluge-port-manager.env`. Empty env files are valid for apps
whose restored configuration already carries their runtime settings. All units
are gated on readable files; this gate is not a replacement for quarantine.
Do not override the VPN/firewall/network settings using these env files.

- `gluetun.env`: `WIREGUARD_PRIVATE_KEY` for the existing ProtonVPN identity.
- `deluge-port-manager.env`: `DELUGE_PASS`, matching the restored Deluge web
  password (source secret key `deluge-runtime/rpc-password`).
- `/run/secrets/publication-manager/server.toml`: preserve issuer
  `https://id.minastas.xyz`, client ID `0724eb37-c3f1-420d-9f39-2c679f4d05f2`,
  callback `https://publications.tailbc181.ts.net/auth/callback`, secure cookies
  and original client secret.
- `/run/secrets/publication-manager/master-key`: original master key, not a
  regenerated key. Both mounted config files must be readable by UID 1000.
- `/run/secrets/publication-manager-registry.json`: Docker/Podman auth JSON for
  `git.tailbc181.ts.net`, provisioned through encrypted secret enrollment. Podman
  receives `--authfile` at runtime; no username/token/login material enters Nix
  or the store. Root-readable only; never run login with credentials in argv.

Shared Tailscale enrollment, backup repository/password and Garage credentials
use the existing fleet contracts; enrollment/secret-policy edits are separate.
Config captures contain API keys and credentials: encrypt and restrict them.

## Restore and paths

Every local state root is `/var/lib/media-automation/<name>`, owned 1000:1000,
mode 0700. Container paths remain `/config`, except publication's `/data`.
Restore Deluge from `kube-store/deluge/config`; restore each other application
from its original `kube-store/<name>` root. Capture complete directories while
source writers are stopped during the operator-owned cutover: SQLite database,
WAL/journal, configs, identities, API keys, pipeline definitions and runs.
Publication uses `/data/server.db`, `/data/pipelines`, `/data/runs`, image
`/plugins` and ephemeral `/tmp`; its key/config are enrolled separately.

| NAS export under nas.tailbc181.ts.net | Host mount | Container path |
| --- | --- | --- |
| /mnt/spinners-1/videos | /mnt/bulk/videos | /videos in Deluge/Radarr/Sonarr/Whisparr/SABnzbd |
| /mnt/spinners-1/kube-store/deluge/downloads | /mnt/bulk/deluge-downloads | /downloads in Deluge |
| /mnt/spinners-1/Computer | /mnt/bulk/publications | /storage in publication-manager |

These are existing bulk directories, not database mounts. Verify the NAS permits
NFS subdirectory mounting for Deluge's existing downloads directory and UID/GID
1000 writes over Tailscale before activation. Do not relocate/copy it merely to
make mounting easier. Preserve restored download client remote-path mappings:
`/downloads` is Deluge-only in the source; `/videos` is shared by the importing
apps and downloaders. Do not invent `/downloads` mounts for the arr applications.
Update only downloader connection endpoints where Kubernetes DNS no longer
exists; retain API keys and original path mappings. Mount dependencies bind
writers to the actual mounts so failed NFS never writes into local fallbacks.

Each `<name>-state` fleet backup job is hourly, database alert class, a complete
stopped-state capture. Restore uses the fleet helper, with 1000:1000 ownership,
0600 files and 0700 directories. Deluge capture stops its forwarding sidecar
before Deluge and restarts only previously active units; Gluetun remains up.
Both writers are listed for restore quiescence. Gluetun/forwarding scratch is
ephemeral and re-created; it contains no state to restore. NAS bulk is excluded.
Use `fleet-restore <name>-state --rehearsal` before final restore; final restore
must be coordinated with stopped source writers and enrolled secrets. Verify
publication pipeline executable requirements after the restrictive restore.

## Networking and acceptance (isolated target only)

Preserved tailnet hostnames route through fleet ingress: deluge:8112,
prowlarr:9696, radarr:7878, sonarr:8989, whisparr:6969, sabnzbd:8180
(container 8080), publications:8090 (container 8080). All origins are loopback.
This module does not migrate the separate `deluge-direct` thin-client identity
or publish 58846/6881 on the host: that requires explicit identity integration,
never a host-network VPN bypass.

Deluge and forwarding sidecar use `--network=container:gluetun`, not host or
independent networking. Only Gluetun publishes 8112, has NET_ADMIN/TUN, and keeps
its firewall enabled, Proton port-forward-only selection and kill switch.
BindsTo/PartOf stop the consumers when the namespace owner disappears.

Before enabling production writes, on an isolated restored target:

1. Confirm all secret gates, local database files, mount sources and permissions.
2. Inspect network namespace identity for all three VPN containers; verify the
   Deluge egress public IP is ProtonVPN, not the host's public IP.
3. Interrupt the VPN tunnel while leaving Gluetun alive: outbound requests from
   the Deluge namespace must fail, never use the host route. Restore the tunnel.
4. Stop Gluetun: Deluge and sidecar must stop. Restart the group explicitly and
   verify forwarded_port matches Deluge's configured listening port. Namespace
   recreation must not leave consumers attached to the previous namespace.
5. Stop each NAS mount: dependent writers must stop, no fallback files appear.
6. Check all loopback origins and original tailnet URLs, downloader mappings,
   publication OIDC/readiness and hourly backup/rehearsal results.

These runtime failure probes are not performed against the live source during
preparation. Preserving Tailscale service identities, bootstrap masking, NAS
authorization and encrypted final capture remain controller/operator tasks.

Focused retained contract check (no full-fleet build):

```sh
nix eval --impure --expr 'let f = builtins.getFlake (toString ./.); c = f.nixosConfigurations.hl-node-04.extendModules { modules = [ {} ]; }; in import ./checks/media-automation.nix { config = c.config; lib = f.inputs.nixpkgs.lib; }'
```
