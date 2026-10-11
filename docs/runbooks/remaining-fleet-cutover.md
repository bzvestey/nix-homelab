# Remaining fleet: prepared batch and sequential cutover

Placement is hl-node-01 for the six lightweight apps and Cloudflare;
hl-node-03 for Jellyfin/Kavita/Vikunja; hl-node-04 for media automation.
Each Framework retains one runner. Manyfold is excluded.

## Build once, install separately

The `images` workflow's `host=remaining` selection builds only 01, 03 and 04,
in parallel. Each artifact includes its revision manifest and SHA256 checksum.
Both Framework ISOs install the quarantined target, not the active role.
The Pi 01 image also masks workloads, service identities, backup timers and
Comin. SSH/networking remain available. No image contains replacement host keys
or fabricated encrypted secrets.

Build active closures before beginning the outage:

```sh
nix build .#nixosConfigurations.hl-node-03.config.system.build.toplevel \
  .#nixosConfigurations.hl-node-04.config.system.build.toplevel \
  .#preparedConfigurations.hl-node-03-staging.config.system.build.toplevel \
  .#preparedConfigurations.hl-node-02-remaining.config.system.build.toplevel
# On the ARM builder:
nix build .#nixosConfigurations.hl-node-01.config.system.build.toplevel
```

These are preparation commands, not activation. Container image pulls still
need runtime registry credentials; prefetch them before stopping writers.
Adding enrolled ciphertext changes activation closures, not bootstrap policy.
Retain the exact image revision and installation closure; do not replace media
just because a secret recipient was added later.

## Enrollment contract

For each host, this command prints only required secret key/path names:

```sh
nix eval --json .#nixosConfigurations.hl-node-03.config.fleet.preparedApplications.secretPaths
```

Substitute 01/04 as needed; use `preparedConfigurations.hl-node-02-remaining`
or `preparedConfigurations.hl-node-03-staging` for those variants. Encrypt each
mapped value in a SOPS YAML file under `secrets/hosts/<host>/`, adding the actual
SSH-derived age recipient after installation. Set
`fleet.preparedApplications.secretsFile` to that enrolled file in the selected
configuration. No restartUnits are set: enrollment alone must not restart a
writer. Preserve all application encryption, OIDC, JWT and SMTP values.
Source mappings and database-address adaptations are documented in the four
service-group runbooks. Registry authentication JSON is runtime-only.

Imported HTTP identities retain their original MagicDNS names. Mailrise retains
TCP 25 → local 8025; Forgejo/Knot SSH retain separate identities on TCP 22;
Deluge-direct retains the thin-client listener on 58846. Never enroll fresh
nodes with the same names or start source and destination identities together.
Export native tailscaled state from the stopped source, not Kubernetes Secret
JSON. Its encrypted escrow and ongoing identity-state backups are separate
from application state backups.

Runner enrollment files remain the runner module's existing contract:
`/run/secrets/forgejo-runner-hl-node-03` and `...hl-node-04`. Supply the preserved
registration identity, rather than creating a second runner with the same UUID.

## Sequence: 03 → 04 → 01

1. Preserve final source manifests, secrets, Tailscale identities and encrypted
   rollback captures before removing Kubernetes workers. Stop only the apps
   being moved, then capture full state directories and version-compatible
   PostgreSQL logical dumps. Bulk NFS libraries stay in place.
2. Install 03 using its verified physical disk identity. Enroll its host key,
   Tailscale and Garage credentials. Grant NAS exports to its actual Tailscale
   address. Restore Jellyfin/Kavita config and Vikunja files/database using the
   storage runbook; preserve numeric ownership and restore attestations.
3. Use the prebuilt 03-staging configuration to host the future Pi apps before
   removing the last Kubernetes worker. Restore their local state and migrate
   their identities with exactly one writer. Move Cloudflare outside Kubernetes.
   The staging connector routes Pocket ID to 10.15.4.7:8080. Update the other
   connector's Pocket ID origin to the same target at that cutover.
4. Finish the separately prepared Forgejo/Foundry/Knot/PDS migrations to 02
   before evacuating the last worker; existing Immich/Mealie/Matrix stay enabled.
   Do not remove the source databases merely because their apps are stopped.
5. Install 04 after its source workloads are evacuated. Restore local media
   automation state; mount existing videos/downloads/publications exports.
   Check Gluetun connectivity and disconnect behavior before starting Deluge.
6. Install 01 last. Stop the staged apps/identities on 03, capture fresh state,
   restore onto 01 and move their identities. Change both Cloudflare connectors'
   Pocket ID origin to 10.15.4.4:8080. Only then remove the staging configuration
   from 03. The shared route table intentionally still points to the current
   source until this separately authorized migration changes it.

## Activation and restore boundaries

Keep bootstrap selected until runtime files and state are restored. Use each
group's documented first-source restore procedure; an existing native restic
snapshot can instead use `fleet-restore <job> --snapshot <id>` (its usage lists
`--force` and `--rehearsal`; do not bypass confirmation casually). First migration captures
are not automatically interchangeable with native backup payloads.
Storage/remaining application restore markers must attest the documented state
layout, not merely bypass a startup gate. Initialize local PG only as required
for restoring its logical dump; do not start the application against a blank DB.

Copy the selected built closure to the installed target, then use its
`bin/switch-to-configuration test` for the approved activation. Verify original
accounts/data, OIDC, SMTP and HTTP endpoints, plus NFS access and (on 03) GPU
transcoding. Commit/enroll the final role only after acceptance; Comin is
disabled in bootstrap, so activation requires this explicit step. After
acceptance, switch persistently and enable automatic backup timers. Run one
backup per job and verify its repository snapshot before advancing.

This batch prepares configuration and commands only. Artifact builds,
recipient enrollment, first-source restores, runtime/VPN acceptance and live
cutovers remain distinct steps; configuration checks do not prove them.
