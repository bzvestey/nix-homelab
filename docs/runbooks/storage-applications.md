# Storage applications: hl-node-03

The preparation contract below is now deployed on hl-node-03. Jellyfin, Kavita
and Vikunja respond through their preserved Tailscale service identities;
their Kubernetes writers remain stopped. Bulk libraries remain on the same
NAS exports, accessed over Tailscale. Application state is local on the
encrypted data volume. Kavita's existing historical backups were retained.
Vikunja's logical restore preserved 1,257 tasks and two users; native PG17 uses
`127.0.0.1:5434` (Vikunja takes the port in its host setting).

`services.fleet.storageApplications.enable` defaults to false; the storage role
imports and enables it. Bootstrap masks the applications until secret enrollment
and restore. Never start both source and target.

## Read-only source evidence (2026-10-11)

Legacy inputs: `new-cluster/opentofu/vars/app_{jellyfin,kavita,vikunja}.yaml`.
Live Deployments, Pod `status.containerStatuses.imageID`, PVs, Vikunja ConfigMap
and CNPG Cluster were read using the supplied read-only kubeconfig. Registry
inspection with skopeo confirmed these exact running amd64 identities and labels:

| App | Pinned image | Image version label |
| --- | --- | --- |
| Jellyfin | `ghcr.io/linuxserver/jellyfin@sha256:1bb4f88d822a0510bb3604b68aacb80d77c1d2a30181e500090c65111b98723b` | `12.2ubu2604-ls53` (LSIO build, not an independently observed application API version) |
| Kavita | `docker.io/linuxserver/kavita@sha256:2842f1c0882b9d0ce3103420eea0a90b27e4537ff29f87b1471cdd752e936837` | `v0.9.1.4-ls125` |
| Vikunja | `docker.io/vikunja/vikunja@sha256:e2204a1c1c6a81e833c2b3a5442be182ca2335b54c2e7e37578cc3fe12a27cfc` | `2.7.0` |

Source Jellyfin/Vikunja Deployment tags were `latest`; Kavita already used the
above digest. CNPG runs `ghcr.io/cloudnative-pg/postgresql:17.5`, resolved to
`sha256:b1deeed2aa998b2f381e39c5cadb9ec06127708c8bd62965743af19abf21628f`.
Its bootstrap explicitly declares database `app`, owner `app`, UTF8, C collation
and C ctype. Target is native PG17, logical restore only, not a raw directory copy.
No Secret values were read, emitted or saved. ARM support was not inferred or
validated: this group targets x86_64 Intel Framework hardware only.

## Runtime enrollment contract

All path options below are under `services.fleet.storageApplications` and accept
only `/run/secrets/...`. Enroll via the shared SOPS policy, never Nix literals.

| Option/default | Contents and permissions |
| --- | --- |
| `jellyfinEnvironmentFile` `/run/secrets/jellyfin.env` | root-readable Podman env file; enroll any original integration overrides. An empty env file is allowed because identities/credentials are restored inside `/config`. |
| `kavitaEnvironmentFile` `/run/secrets/kavita.env` | same; original auth/SMTP configuration and keys are in restored `/config`. |
| `vikunjaEnvironmentFile` `/run/secrets/vikunja.env` | root-readable env file with nonempty `VIKUNJA_DATABASE_PASSWORD` and `VIKUNJA_AUTH_OPENID_PROVIDERS_POCKETID_CLIENTSECRET`; also preserve any original JWT/service secrets if configured. PG service user `postgres-vikunja` receives this through systemd EnvironmentFile, not by reading it directly. |
| `vikunjaConfigFile` `/run/secrets/vikunja-config.yml` | full original ConfigMap YAML plus enrolled OIDC secret in `auth.openid.providers.PocketID.clientsecret`; owned by UID 1000 with mode 0400. The image's UID does not imply GID 1000. Preserve provider structure exactly; don't rely solely on nested env override behavior. |

Vikunja must retain local login disabled, OpenID enabled, provider `PocketID`,
authurl `https://id.minastas.xyz`, clientid
`c1807354-bdba-4c64-bd7f-70807ecc13de`, emailfallback/usernamefallback true,
scope `openid profile email groups`, stdout event/mail logging and metrics
enabled. Preserve publicurl `https://vikunja.tailbc181.ts.net/`.
SMTP: retain enabled=true, fromemail `vikunja@minastas.ninja`, port 25 and
skiptlsverify=true. Replace Kubernetes-only
`mailrise.mailrise.svc.cluster.local` in the runtime YAML with the reachable
replacement Mailrise service endpoint (expected `mailrise.tailbc181.ts.net`);
verify it actually exposes SMTP port 25 over the tailnet before activation.
An HTTPS-only Mailrise proxy is not an SMTP replacement. Keep source passwords,
OIDC client registration and callback URLs, never create replacement identities.

All apps require the env file and a nonempty local `.fleet-restored` marker;
Vikunja also requires its YAML and nonempty DB/OIDC env credentials. PG is gated
by the env file, DB password and marker. These markers are operator attestations,
not a substitute for inspecting a successful restore. Missing enrollment skips
startup rather than opening a new empty application wizard.

## Capture and restore mapping

After separate cutover authorization, stop the source app writer before copying
complete directories (including SQLite WAL/journal, plugins, auth keys and hidden
files). Encrypt capture at source; do not write plaintext secret scratch files.

| Source NAS path | Target local path/container path |
| --- | --- |
| `/mnt/spinners-1/kube-store/jellyfin/` | `/var/lib/jellyfin/` -> `/config` |
| `/mnt/spinners-1/kube-store/kavita/config/` | `/var/lib/kavita/` -> `/config` (source used subPath `config`, do not introduce another `config` directory) |
| `/mnt/spinners-1/kube-store/vikunja/` excluding `postgres/` | `/var/lib/vikunja/` -> `/app/vikunja/files` |
| CNPG database `app`, owner/login `app` | local `app`, owner/login `app`, socket `/run/postgres-vikunja`, port 5434, OS administrator `postgres-vikunja` |

Keep target app units and backup timers masked while restoring. Restore files
with UID/GID 1000; confirm image Vikunja User is 1000 (registry config), source
fsGroup was 1000, LSIO source PUID/PGID were both 1000. After validating files,
write a nonempty `.fleet-restored` attestation in each state directory. For
Vikunja keep Podman masked while this attestation permits starting native PG17
and importing the final custom-format `pg_dump -Fc app`. Initialize role `app`
with the enrolled source password; restore into database `app` with ownership
preserved. Do not restore source CNPG infrastructure roles blindly: source
cluster admin `postgres` maps to OS/cluster admin `postgres-vikunja`; application
role `app` and database `app` stay unchanged. Inventory extra roles, extensions,
owners and ACLs in the final dump before restore; explicitly map any additional
owners rather than silently using `--no-owner`. Source `VIKUNJA_DATABASE_NAME`
was `vikunja` and remains present; actual database selection was the Secret
`dbname`, consistent with CNPG bootstrap `app`. Confirm this against the final
dump without printing Secret material. Never copy the source PG17 data directory.

Leave bulk libraries in place, with read-only container binds:

| NFS source (server `nas.tailbc181.ts.net`) | Host mount | Preserved container path |
| --- | --- | --- |
| `/mnt/spinners-1/videos` | `/mnt/bulk/videos` | Jellyfin `/data` |
| `/mnt/spinners-1/Computer/books` | `/mnt/bulk/books` | Kavita `/data/books` |
| `/mnt/spinners-1/apps/syncthing` | `/mnt/bulk/syncthing` | Kavita `/data/syncthing` |

`dependentUnits` supplies RequiresMountsFor/BindsTo and disables idle expiry.
NAS ACLs must allow numeric 1000 to read/traverse existing libraries; do not
recursively chown bulk exports. App config/databases never use NFS. LSIO root
initialization fixes device access for PUID 1000 with `/dev/dri` mapped as a
device, not an ordinary directory volume. Verify Intel render-node access and
a Jellyfin hardware transcode on target; source Deployment had no GPU mapping.

## Backups and acceptance

Shared `application-backups.nix` provides stopped-writer whole-directory captures
for `jellyfin-state` and `kavita-state` hourly, database alert class, and
`vikunja-files` daily. `vikunja-db` is hourly PG17 logical `app` dump with scratch
database rehearsal, preserving app ownership on real restore. Coordinate final
Vikunja files/dump capture with its writer stopped for cross-resource consistency.
Payload bounds are 32 GiB Jellyfin, 128 GiB Kavita, 16 GiB Vikunja files; DB uses shared 1 GiB
default. Measure final sizes before activation and adjust bounds if needed.
Runtime YAML/env files and Tailscale identities require separate encrypted
escrow/enrollment; they are intentionally not in app-state backup payloads.

Check loopback-only listeners 8096/5000/3456, original `*.tailbc181.ts.net` URLs,
PocketID login and SMTP delivery; Jellyfin `/health`, Vikunja `/api/v1/info`,
Kavita `/` must respond. Verify original users/libraries/tasks/attachments and
perform restore rehearsal before enabling timers and unmasking app units.
No runtime startup, NFS access, OIDC/SMTP or GPU acceptance is claimed by config
evaluation. Public contract check (no broad fleet build):

```sh
nix eval --impure --expr 'let f=builtins.getFlake (toString ./.); in import ./checks/storage-applications.nix { host=f.nixosConfigurations.hl-node-03.extendModules { modules=[]; }; inherit (f.inputs.nixpkgs) lib; }'
```

Preparation validation: contract initially failed because all three applications
were missing, then passed after implementation. Target extended-flake evaluation
returned zero failed NixOS assertions and a toplevel derivation; disabled-module
evaluation verified default false and absence of Jellyfin. `nixfmt --check`
passed for the owned Nix files. Migration subsequently built and switched the
actual hl-node-03 configuration and checked all three loopback and tailnet HTTP
endpoints. User acceptance of OIDC, mail delivery and hardware transcoding
remains separate from these health checks.
