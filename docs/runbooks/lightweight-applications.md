# Lightweight applications: preparation and restore contract

This module is preparation only. Nothing here authorizes stopping Kubernetes,
deploying, changing DNS, enrolling a duplicate identity or activating a writer.
`services.fleet.lightweightApplications.enable` defaults to false; the
`lightweight-services` role enables it. Bootstrap/Comin quarantine and migrated
service identities remain mandatory integration prerequisites before activation.
For temporary x86 hosting import the service module (not the role, which also
enables Cloudflare) and explicitly enable it. Use private local state directories.
Both x86-64 and ARM64 select their platform from the same immutable image index.

## Runtime configuration (no values in Nix)

All paths are configurable under `services.fleet.lightweightApplications` and
restricted to `/run/secrets/`. Each container requires its `environmentFiles`
entry, default `/run/secrets/<container-name>.env`. Supply root-readable Podman
`KEY=value` files, not Kubernetes Secret JSON. For applications without secret
environment keys, supply an empty enrolled file; this is an intentional start
gate, not permission to start an unrestored application. Configuration files
below are additional start gates. Secret enrollment must retain existing values,
never generate replacement encryption/JWT/OIDC keys. Missing files skip startup;
after enrollment, the operator explicitly starts the prepared units.

| Container | Required runtime keys / source mapping |
| --- | --- |
| `pocket-id` | `ENCRYPTION_KEY` = `pocket-id-runtime/encryption-key` (external source `pocket-id/encryption-key`); `MAXMIND_LICENSE_KEY` = `pocket-id-runtime/maxmind-license-key` (external `pocket-id/maxmind-license-key`). |
| `homarr` | `SECRET_ENCRYPTION_KEY` = `db-secret/db-encryption-key` (external `homarr/db-encryption-key`); `AUTH_OIDC_CLIENT_ID` and `AUTH_OIDC_CLIENT_SECRET` = `auth-oidc-secret/oidc-client-id` and `/oidc-client-secret` (external `homarr/oidc-client-id`, `homarr/oidc-client-secret`). |
| `donetick` | No extra environment secret; `donetickConfigFile`, default `/run/secrets/donetick-selfhosted.yaml`, contains the rendered `donetick-config/selfhosted.yaml`. |
| `commafeed` | No secret environment in source; preserve H2 state/accounts/settings. |
| `wallos` | No secret environment in source; preserve SQLite accounts/settings and logos. |
| `mailrise` | No extra environment secret; `mailriseConfigFile`, default `/run/secrets/mailrise.conf`, contains the original `mailrise` ConfigMap's `mailrise.conf`. Treat it as a secret: it contains a notification webhook credential. Never print it or commit it. |

Donetick's rendered YAML must preserve all source settings from
`new-cluster/opentofu/vars/app_donetick.yaml`: `name`, disabled signup,
`pushover.token` (external `donetick/pushover-token`), SQLite migration,
`jwt.secret` (external `donetick/jwt-secret`), 168h session/refresh durations,
server limits/CORS/frontend, logging, scheduler, email, OAuth and realtime
settings. Preserve OAuth client ID `c7fb12b6-f37d-4245-ad56-4e7ae57ed113`,
`oauth2.client_secret` (external `donetick/oidc-client-secret`), auth URL
`https://id.minastas.xyz/authorize`, token URL `/api/oidc/token`, user-info URL
`/api/oidc/userinfo`, redirect
`https://donetick.tailbc181.ts.net/auth/oauth2`, and provider name `PocketID`.
The sole necessary service-address adaptation is `email.host: mailrise` and
`email.port: 8025` instead of Kubernetes DNS/port 25. The DNS-enabled
`fleet-lightweight` Podman bridge permits this without host networking.
Mailrise retains its wildcard routing, title template, original notification
destination and listen port 8025. Deliver both rendered files through encrypted
secret management, with permissions readable by the container process.

Homarr retains OIDC-only login, issuer/logout URLs, automatic login, groups
attribute and scope, client name and 30d session expiry. Kubernetes integration
is deliberately disabled after migration (no service-account credentials are
copied); Docker integration remains disabled. Homarr stays on better-sqlite3,
SQLite and `/appdata/db.sqlite`. Pocket ID retains `APP_URL` and `TRUST_PROXY`.
Wallos retains `WALLOS_SERVER_URL`. Environment files must not override these
public settings or change the database backend during restore.

## Local data and stopped-writer captures

| Source mount / NAS dataset | Destination | Loopback origin / preserved URL |
| --- | --- | --- |
| Pocket ID `/app/data`, `kube-store/pocketId` PVC | `/var/lib/pocket-id` | `1411:1411`, `https://id.minastas.xyz` (public) |
| Homarr `/appdata`, `kube-store/homarr` PVC | `/var/lib/homarr` | `7575:3000`, `https://homarr.tailbc181.ts.net` |
| Donetick `/donetick_data`, **`data/` subdirectory** of `kube-store/donetick` PVC | `/var/lib/donetick` (put `donetick.db` at its root) | `2021:2021`, `https://donetick.tailbc181.ts.net` |
| CommaFeed `/commafeed/data`, `kube-store/commafeed` PVC | `/var/lib/commafeed` | `8085:8082`, `https://feed.tailbc181.ts.net` |
| Wallos `/var/www/html/db`, PVC `wallos-db` | `/var/lib/wallos/db` | `8282:80`, `https://wallos.tailbc181.ts.net` |
| Wallos `/var/www/html/images/uploads/logos`, PVC `wallos-logos` | `/var/lib/wallos/logos` | same Wallos writer/capture |
| Mailrise configuration only; no persistent application data/queue in source | runtime config above | `8025:8025` SMTP; no HTTP route |

Observed Wallos PVC exports are
`/mnt/flash-1/kube-store/wallos/pvc-bc8ce167-3920-45b8-8b7c-7b784aa851d0`
(database) and
`/mnt/flash-1/kube-store/wallos/pvc-7f5bd873-9bfa-4388-9d85-b496feba6f91`
(logos), on `10.15.4.101`. These are **capture sources only**, never destination
NFS database mounts. Reconfirm PVC bindings at cutover.

At the separately authorized cutover, stop each source writer before capturing
the *entire* mounted directory, including hidden files, SQLite WAL/SHM/journals,
H2 files, attachments, encryption material and application identities. Capture
both Wallos mounts under one stopped writer. Keep encrypted rollback captures
and secret exports before evacuating the last Kubernetes worker. Never copy only
the main `.db` file or initialize a blank database then import pieces.

The five `<name>-state` jobs use `lib/application-backups.nix` state jobs with
hourly frequency and `database` alert class. Captures stop `podman-<name>.service`
and restore the complete `state/` payload while the fleet restore tool keeps the
writer stopped. Pocket ID restores UID/GID 1000; Wallos UID/GID 82; other apps
restore root ownership (their image entrypoints control process users). These
are rootful Podman numeric IDs, not fabricated host accounts. Test permissions
and account/settings/attachment counts on an isolated restore. Mailrise is
stateless; an empty directory backup would be invalid and is deliberately not
created. Its complete restore contract is the encrypted runtime config export.
Backup repository credentials and application secret escrow are separate fleet
contracts; directory snapshots do not replace them.

All published ports bind only `127.0.0.1`; CommaFeed's internal 8082 does not
collide with Immich host telemetry 8081/8082. No host network or LAN SMTP listener
is opened. HTTP ingress routes preserve the five hostnames. Before cutover,
the controller must configure the existing migrated Tailscale service proxies
and their native state backups for Homarr, Donetick, Feed and Wallos, without
running the source and destination identities concurrently. Merely declaring a
Caddy hostname does not migrate its Tailscale identity. Mailrise's original
Tailscale load-balancer SMTP port 25 needs a separately integrated TCP identity
proxy to `127.0.0.1:8025`; the current fleet HTTP-only proxy cannot supply it.
Do not claim SMTP identity preservation until that integration is validated.

## Immutable image / architecture evidence (2026-10-11)

Read-only Kubernetes `status.containerStatuses[].imageID` matched all six index
pins below. Skopeo `inspect --raw` of these **exact deployed indexes** independently
showed linux/amd64 and linux/arm64 manifests; attestations with unknown platforms
are not architecture evidence. Mutable Homarr and Donetick `latest` now differ
from deployed images and were deliberately not used.

| App | Exact deployed index SHA256 | Version/build identity | ARM64 child SHA256 |
| --- | --- | --- | --- |
| Pocket ID | `323e7ef5bfacf7cf32f22f3d10ccdf48e0c97c94d67e7e40b0b996830deb5165` | OCI version `2.18.0`, revision `40cb14f89309286dcafaa62dac82a88a4b5ac583` | `7dd124e44cb65f74fe5761b85d832b285ea261d80ad28ec433f2cf80aba192e6` |
| Homarr | `f0fb462299af9749a72f11040fd3f604d1c4976b3d9a137ae5021b7f44d980f5` | OCI version `main`, revision `286abf392ad32cc339b94815c84438863c43190e`, created `2026-09-18T19:19:16.136Z` (package.json reports `0.1.0`, not a reliable release tag) | `b912de52967ade306e710ab6e5e01e226beac61d1b3f73404912ae1f24f70e01` |
| Donetick | `a1cc21dd5a37acb5009009f13e5d2529153049361afb0a1cd94bde312382d36a` | deployed `latest` build, no OCI version label; index is exact version identity | `b806203bb7270fd40bfb771cb45b728cd70e28e19f8ac9fd9287edfb0aaac80f` |
| CommaFeed | `0e52f2a86c2ae36cb446401292c87ba6ca658fafda64c99bc7e8713ed433d8a3` | deployed `latest-h2` build, no OCI version label; H2 variant unchanged | `b835d9060d537baef7a9e215c333131e8bb35cb7e4996143ff8604a76c33b187` |
| Mailrise | `0b8b1ce3447c83b625c9e8896cd9c3db0205590f92ce4d4adaae69729830f52b` | OCI version `latest`, revision `60d485e2ae22ae09ddeac25565c48e3455a8c1a7` | `203cb830a666ee3d0afb1721144d66577467eeb9d821ca2074beffa31766dbc9` |
| Wallos | `0f049dbab45b9f8e8d43b84fd1b77ef9e55909bd1a384a0f4fe8597ab68a1d5d` | deployed/OCI `5.8.1`, revision `844cea04e3025f75494e954aaa67af7386d4840a` | `14df46997cc1be18af64f47dbd7e7431c598d5206ae52522dc729b98a704f743` |

## Focused contract evaluation

The retained check takes `{ config, lib }`, so it can check an enabled Pi or an
extended x86 flake configuration without wiring new shared flake outputs:

```sh
nix eval --impure --expr 'let f = builtins.getFlake (toString ./.); in
  import ./checks/lightweight-applications.nix {
    config = f.nixosConfigurations.hl-node-01.config;
    lib = f.inputs.nixpkgs.lib;
  }'
```

Before enabling production, independently rehearse each stopped-state restore,
check Pocket ID passkeys/OIDC grants, Homarr decryptable integrations/login,
Donetick chores/OAuth/notifications, CommaFeed feeds/read state, Wallos
subscriptions/logos, and a Mailrise notification on an isolated recipient.
HTTP/SMTP readiness is not proof of data restoration. This preparation does not
perform those tests or source captures.
