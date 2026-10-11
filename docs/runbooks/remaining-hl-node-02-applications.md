# Remaining node-02 prerequisites (prepared, not activated)

The only opt-in is `services.fleet.remainingApplications.enable` (default
false). Import `modules/services/remaining-applications.nix` in the future
activation configuration, not the current host. No host/role import is added
here. Existing Immich, Mealie and Matrix are unchanged. Container units are
`podman-{forgejo,foundry,tangled-knot,tranquil-pds}.service`; each requires its
runtime environment and `/var/lib/<name>/.restored`. Write that marker only
after the operator has validated final state, identities and database restore.
The marker is included in subsequent state backups. It is not permission to
run a second writer. PostgreSQL can initialize separately for offline restore.

## Observed sources and immutable versions

Read-only Kubernetes inspection on 2026-10-11 confirmed the following images.
These are source-running amd64 manifests, not claims of ARM64 support.

| Application | Image repository | sha256 digest | HTTP internal → local |
|---|---|---|---|
| Forgejo 16-rootless | codeberg.org/forgejo/forgejo | 5effb7305584aca479b29fde6f9631a6dbe86ae798ae02eeea33a3666f0c0bf8 | 3000 → 3000 |
| Foundry private image | ghcr.io/bzvestey/foundry | 5d59c2eabaa4a495171cfa5ca73148aaf76056bd2052e84d978935f80ea32709 | 30000 → 30000 |
| Tangled Knot 2 | atcr.io/tangled.org/knot | 6a9246da7b49a8bbe6f84122fd6fc09aac3ae93589b193956873daf33f88faa6 | 5555 → 5555 |
| Tranquil PDS | atcr.io/tranquil.farm/tranquil-pds | bfbcb3b574bd836e9719012c98b172a8ebea2046acb6a87cb989eeb4f4dba9a4 | source 3000 → configured 8000 |

Both live CNPG databases use PG18.1 (image digest
`34cb8f540cee92ea6f29f8bd507e4352aefb149863c504fc5e8facce92607135`).
Read-only SQL also verified Forgejo database/owner `forgejo/forgejo`, PDS
`app/app`, and only `plpgsql` 1.0 installed in each source application database.
Native target `pkgs.postgresql_18` currently resolves to 18.6: same-major logical
restore, a documented patch update, never a copied physical CNPG/NFS cluster.
Runner 13 is managed separately by the controller.

Sources: `/home/bzvestey/dev/new-cluster/opentofu/vars/app_gitea.yaml`,
`app_foundry.yaml`, and `opentofu/manifests/{forgejo,tangled-knot,tranquil-pds}/all.yaml`.
The legacy Gitea image/config are NOT the active Forgejo contract. In particular
preserve the live `https://git.tailbc181.ts.net/` origin and
`git-ssh.tailbc181.ts.net:22`, not legacy `gitea-ssh` or HTTP ROOT_URL.
PDS `SERVER_PORT` is documented in upstream
<https://tangled.org/tranquil.farm/tranquil-pds/blob/main/example.toml?code=true>;
the source manifest exposes internal 3000. Target host networking changes only
the local listener to 8000, preserving `minastas.social`, `pds.minastas.social`
and `*.minastas.social`. Foundry and knot retain source internal ports behind
loopback-only Podman publications. Forgejo/PDS bind host-loopback directly.

## Runtime enrollment (never print secrets)

Supply root-readable 0600 files via the existing encrypted secret enrollment.
Do not put registry credentials, database passwords, generated app.ini, account
keys or license files in Nix/store/scratch/output. Do not print Kubernetes Secret
objects. Capture sensitive material directly into encrypted rollback archives
or the approved secret manager, without a plaintext intermediate.

| Runtime file | Required contract |
|---|---|
| `/run/secrets/forgejo.env` | `POSTGRES_PASSWORD`; same value in `FORGEJO__database__PASSWD`; original `FORGEJO__security__INTERNAL_TOKEN`, `FORGEJO__security__SECRET_KEY`, `FORGEJO__server__LFS_JWT_SECRET`; `FORGEJO__storage__MINIO_ACCESS_KEY_ID`, `FORGEJO__storage__MINIO_SECRET_ACCESS_KEY`; `FORGEJO__mailer__SMTP_ADDR` set to the reachable replacement Mailrise endpoint |
| `/run/secrets/foundry.env` | An enrolled file (may be empty); any source runtime settings. License/application settings are restored state, not downloaded afresh |
| `/run/secrets/tangled-knot.env` | Original `KNOT_MASTER_KEY` |
| `/run/secrets/tranquil-pds.env` | `POSTGRES_PASSWORD`; `DATABASE_URL=postgresql://app:<URL-encoded same password>@127.0.0.1:5435/app`; original `JWT_SECRET`, `DPOP_SECRET`, `MASTER_KEY`, `SSO_OIDC_CLIENT_ID`, `SSO_OIDC_CLIENT_SECRET`; reachable replacement `MAIL_SMARTHOST_HOST` |
| `/run/secrets/remaining-applications-registry.json` | Podman auth JSON with ghcr.io private Foundry pull access and atcr.io pull access |

Registry file is configurable with
`services.fleet.remainingApplications.registryAuthFile` (only `/run/secrets/...`).
Podman gets `REGISTRY_AUTH_FILE` at runtime, including pull/prestart; no `login`
password literal or store auth JSON. Foundry/knot/PDS are gated on this file.
Forgejo keeps Garage bucket `forgejo` at `10.15.4.101:30188`, path lookup,
region `garage`, no TLS. Preserve/back up that external bucket independently;
local state/DB backups are not a replacement for attachments/LFS in Garage.
Forgejo OIDC auth sources/tokens live in its restored database and generated
app config. Do not bootstrap users or re-register auth providers/runners.

## Final capture and restore mapping (operator cutover only)

Preparation has not stopped, activated or deployed anything. At the approved
cutover, first prevent source restart/reconciliation, stop each application
writer, then capture complete directories (including hidden files, SQLite
WAL/journals, keys and app config), and take logical PG18 custom-format dumps.
Keep an encrypted rollback capture before mutating targets. Never start a
target until the source writer and duplicate Tailscale identity are offline.

| Source state | Local target | Required preservation |
|---|---|---|
| Forgejo PVC mounted `/var/lib/gitea` | `/var/lib/forgejo/data` | repos, custom/conf/app.ini, SSH keys, generated server config and identity |
| Rootless `/etc/gitea` (capture even if ephemeral) | `/var/lib/forgejo/config` | source config/SSH material; capture both rootless config locations securely |
| Foundry PVC `app`, `data` | `/var/lib/foundry/{app,data}` | exact installed proprietary application, license, worlds, modules, account config; do not infer Foundry app version from image `latest` |
| Knot PVC `/data`; source ConfigMap `config.toml` | `/var/lib/tangled-knot/data`; `/var/lib/tangled-knot/config.toml` | repos, sealed-keys, ssh_host_key, all embedded state. Config retains hostname `knot.minastas.xyz`, admin `did:plc:ecit4wldfwsit5udtibdrzsq`, closed ACL, sha256 git format, tangled.org appview, plc.directory |
| PDS PVC `blobs` | `/var/lib/tranquil-pds/blobs` | complete blobs plus matching database containing accounts, DIDs, signing keys and OAuth state |

Knot stays bridge-networked: retain `[::]:5555` and `[::]:2222` in restored
config. Replace obsolete trusted `10.244.0.0/16` with the actual Podman proxy
peer/network after observing it; never trust arbitrary forwarded headers.
Capture config in the stopped-state backup root so future restores include it.
State ownership is numeric 1000:1000 for Forgejo/Foundry/knot (Foundry verified
by live stat), 65532:65532 for PDS. The helper normalizes modes to 0750;
container prestart repairs private SSH host keys to 0600. Retain executable
Foundry app files. Audit any other source-specific restrictive file modes.

Database mapping is deliberate because `fleet.localPostgres` HBA and the shared
database helper assume `app`: source Forgejo database/owner `forgejo/forgejo`
become target `app/app`; source PDS already uses `app/app`. Restore with
`--no-owner --no-acl --role=app` into precreated target `app`, never create the
source database name on the target. The module adapts the helper's final restore
to this mapping; rehearsal validates a scratch DB before destructive replacement.
Check source custom grants/extensions before cutover; non-default grants must
be explicitly mapped rather than silently discarded. Target clusters:

- `postgres-forgejo.service`: `/var/lib/postgres-forgejo`, socket
  `/run/postgres-forgejo`, loopback 5434.
- `postgres-tranquil-pds.service`: `/var/lib/postgres-tranquil-pds`, socket
  `/run/postgres-tranquil-pds`, loopback 5435.

Backups: `forgejo-db` and `tranquil-pds-db` hourly logical `database.dump`;
`foundry-state` and `tangled-knot-state` hourly stopped embedded/application
state (database alert class); `forgejo-state` and `tranquil-pds-state` daily
stopped identity/blob state. All use fleet backup/restore commands and include
only local application paths, not existing NAS physical PG clusters. For the
initial import, keep units masked until *both* DB and state have been restored;
fleet-restore normally restarts job units, so do not treat sequential imports
as atomic. Only then validate and create the `.restored` marker.

## SSH and acceptance blockers

No host SSH22/firewall or Tailscale identity is changed here. Runtime cutover
must restore separate `git-ssh` and `knot-ssh` service identities and arrange
their port22 forwarding to `127.0.0.1:2222` (Forgejo) and
`127.0.0.1:2223` (knot, internal2222). Do not replace host administrative SSH
or expose these listeners on all interfaces. HTTP `git` service identity and
public ingress evacuation are controller integration responsibilities.

Before activation: resolve replacement SMTP reachability, verify private image
pulls, exact installed Foundry version/license, source DB grants/extensions,
captured rootless config locations, Knot proxy trust, matching final blobs/DB,
service-identity enrollment and SSH forwarding. Run an isolated restore rehearsal
and compare SSH fingerprints, Forgejo OIDC/login/repos/LFS/actions, Foundry
world loading, knot sealed-key identity, PDS account DIDs/signing/OIDC and all
public/legacy origins. HTTP probes are `/api/healthz`, `/`, `/xrpc/_health`,
`/xrpc/_health` on ports3000/30000/5555/8000. No image pull, workload start or
end-to-end restore has been performed during this preparation.

## Focused evaluation

`checks/remaining-applications.nix` accepts `{ configuration = extendedNode02; }`
and tests the public configuration, not a full-fleet VM/build. With a live
local module plus a store-snapshotted flake, remove only the module `imports`
in the evaluation adapter because node02 already imports local-postgres through
Immich (avoids declaring the same option through two path identities):

```sh
nix eval --impure --expr '
let f = builtins.getFlake (toString ./.);
    m = {config,lib,pkgs,...}@args:
      builtins.removeAttrs (import ./modules/services/remaining-applications.nix args) ["imports"];
    c = f.nixosConfigurations.hl-node-02.extendModules {
      modules = [ m { services.fleet.remainingApplications.enable = true; } ];
    };
in import ./checks/remaining-applications.nix { configuration = c; }'
```

Preparation validation: the contract initially failed on the absent public
option and passes with the extended configuration. Enabled node02 evaluates
its toplevel derivation with zero failed NixOS assertions; default-disabled
import leaves all original containers unchanged, and opt-in also leaves every
existing container unchanged. `nixfmt --check` and `deadnix` pass for the two
owned Nix files. Statix reports only a style warning about repeated `fleet`
attribute prefixes; there are no runtime builds or activation claims.
