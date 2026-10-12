# Framework Forgejo Actions runners

hl-node-02 and hl-node-03 are enrolled with encrypted runner credentials;
hl-node-04 remains preparation-only. Bootstrap remains usable: a runner with
no credential file is skipped by a systemd condition.

## Identities and prerequisites

Server: `https://git.tailbc181.ts.net/`. Provision exactly one persistent runner
per Framework, named with its canonical hostname. The locally assigned public
UUIDs are identities, not SSH keys or age recipients:

| Host / server runner name | Assigned UUID | Runtime token file |
| --- | --- | --- |
| hl-node-02 | f1e34f88-7906-4da2-a237-9dc46c7d7802 | /run/secrets/forgejo-runner-hl-node-02 |
| hl-node-03 | d590a8c1-c6d3-4fdc-b11f-6a57978e78ec | /run/secrets/forgejo-runner-hl-node-03 |
| hl-node-04 | 456e3c18-a5e5-4869-9906-a7d65d2eb2a2 | /run/secrets/forgejo-runner-hl-node-04 |

hl-node-03 preserves existing Forgejo runner ID 3, server display name
`k8s-minastas-home-cluster-w2`, and its original token. Its UUID was verified
from the stopped source's `.runner` file during migration; do not provision a
replacement registration using the earlier preparation-only UUID.

hl-node-04 similarly preserves runner ID 4, display name
`k8s-minastas-home-cluster-w3`, and UUID verified in the stopped source's
registration during preparation. The registration is encrypted in the
administrator's capture escrow; do not register a replacement runner.

All three production runners advertise exactly:
`ubuntu-latest:docker://ghcr.io/catthehacker/ubuntu:act-latest`.
The Pis have no runner instance. Test routing labels are not production labels.

Enrollment is a separately approved administrator operation:

1. Enroll each Framework's genuine SSH/age identity using the existing host
   enrollment runbook. Add only actual public Framework recipients to the
   `secrets/framework-runners/` SOPS creation rule; preserve the administrator.
2. Provision the assigned UUID/name on Forgejo at the desired scope. The locked
   local Forgejo CLI supports idempotent `forgejo forgejo-cli actions register`
   with a positional UUID and **`--secret-file`** (or `--secret-stdin`), avoiding
   secret argv. Verify the actual production server's help/version first. As the
   server service account, with its correct work/config paths, the shape is:

   ```sh
   forgejo forgejo-cli actions register --name hl-node-02 \
     --secret-file /secure/runtime/runner-token \
     f1e34f88-7906-4da2-a237-9dc46c7d7802
   ```

   Do not use `--secret VALUE`, legacy `register --token`, shell tracing, or a
   global environment variable. Generate and handle token material privately;
   this document intentionally contains no token. Repeat for the other two
   assigned identities. Do not use ephemeral server registrations. If the
   production server cannot provision an assigned UUID safely, stop and agree
   on a supported method; UI/API-generated UUIDs require deliberate updates to
   the host configuration, not pretending they match these identities.
3. Encrypt each token under the existing `framework-runners` policy. Add the
   corresponding `sops.secrets` definition only when the genuine encrypted file
   exists; supply the exact runtime path above, root-owned with mode `0400`, and
   arrange runner restart after token rotation. The content is the raw runner
   authentication token, **not** `TOKEN=...` and not a registration token.
   No placeholder encrypted file or fabricated host recipient is needed.
4. After approved deployment, start the runner explicitly once credentials
   exist. A condition skipped at boot is not automatically retried when a file
   appears. Resolve the native escaped unit name rather than guessing:

   ```sh
   unit="forgejo-runner-$(systemd-escape --path hl-node-02).service"
   systemctl start "$unit"
   systemctl status "$unit"
   journalctl -u "$unit"
   ```

5. Confirm the server has exactly three named runners, identical production
   labels, and unchanged UUIDs after restarting the services. Run trusted smoke
   jobs and review their outcomes before allowing general work.

## Execution, state, and limitations

The native `services.forgejo-runner` module owns the daemon lifecycle and
declarative connections. systemd `LoadCredential` supplies the token to
`file:$CREDENTIALS_DIRECTORY/...`; the store configuration and daemon argv
contain no token values. There is no registration wrapper or registration
service on a runner host.

Jobs use the shared rootful Podman service. Only the daemon receives
`DOCKER_HOST=unix:///run/podman/podman.sock`. `container.docker_host="-"` prevents
the socket being mounted into job containers; `privileged=false` and
`valid_volumes=[]` disallow privileged jobs and workflow-requested host mounts.
There is no Docker-in-Docker sidecar, Docker daemon, or host execution label.
This is not a strong hostile multi-tenant security boundary: trust workflows,
limit server registration scope, and do not allow arbitrary untrusted jobs on
hosts containing valuable workloads. Rootful engine access by the daemon is
powerful even though the socket is not exposed to jobs.

The native state directory is `/var/lib/forgejo-runner/<hostname>`; job containers
and their workspace volumes are local Podman state under `/var/lib/containers`.
Both are disposable and excluded from runner backup jobs (none are created).
Identity is in declarative configuration, not generated afresh at restart.
The Actions cache service is explicitly disabled. Images follow the existing
shared conservative image-prune policy; no claim is made that image caches or
all local state are removed after every job. Successful normal job cleanup is
tested; interrupted/failed jobs can require administrator cleanup.

Logs go to journald; shared Podman also uses journald. For troubleshooting,
inspect the escaped runner unit and `podman.service`, credential *existence and
permissions* (never print its content), server reachability, and Podman images.
Do not collect production token values or dump credential directories into
diagnostic reports. Disabling a runner is reversible through its fleet enable
option; revoke its server credentials separately if compromise is suspected.

## Checkout archive regression (Podman 5.8.7)

The migrated runners hit the same checkout failure on all three Frameworks:
`statat var/run/act/actions/.../.eslintignore: path escapes from parent`.
This happens before Git checkout: the Docker-compatible archive API rejects
the job image's absolute `/var/run -> /run` symlink. The subsequent missing
`dist/index.js` error is a consequence of the failed copy, not a missing Node
installation or bad repository credentials.

The runner module backports the final fix from
[Buildah #7129](https://github.com/podman-container-tools/buildah/pull/7129),
adapting its call site to Podman's vendored Buildah 1.43.4. Only the API daemon
uses the patched binary; unrelated application units and the CLI package are
unchanged. Its systemd drop-in resets the vendor unit's `ExecStart` before
replacing it. The archive security checks remain enabled: valid in-container
absolute symlinks work, while relative escapes outside the extraction directory
remain rejected. Remove this backport once the pinned Podman includes the fix;
do not downgrade away the existing archive security patches.

The regression fixture exercises both cases through `PUT /containers/.../archive`,
with `/var/run -> /run` in its job image. A plain file-copy command does not
represent the runner's broad-root archive operation.

Separately, the WyrdSaga test workflow publishes PostgreSQL on host port 5432,
which conflicts with the existing database on node02. Container jobs should
connect to their PostgreSQL service on the job network without a fixed host
port publication; do not stop or move the homelab database to accommodate CI.

## Local acceptance

`nix build -L .#checks.x86_64-linux.forgejo-runner` builds a local image and starts
Forgejo plus three Podman runner VMs. The fixture uses real API registrations
and six independent inline jobs with test-only routing labels, no `uses:` action
downloads and no runtime Internet image pulls. It checks job-marker isolation,
live container privilege/socket mounts, all-three-runner work distribution,
restart identity stability, skipped unenrolled services, local state, absent
backup units, and journald output. Fixture UUID substitution follows the locked
nixpkgs `nixos/tests/forgejo.nix` pattern and is not used in production.
