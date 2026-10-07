# Framework Forgejo Actions runners

This configuration is **not production enrollment**. No Framework SSH/age
recipients or encrypted runner tokens have been created. Bootstrap remains
usable: a runner with no credential file is skipped by a systemd condition.

## Identities and prerequisites

Server: `https://git.tailbc181.ts.net/`. Provision exactly one persistent runner
per Framework, named with its canonical hostname. The locally assigned public
UUIDs are identities, not SSH keys or age recipients:

| Host / server runner name | Assigned UUID | Runtime token file |
| --- | --- | --- |
| hl-node-02 | f1e34f88-7906-4da2-a237-9dc46c7d7802 | /run/secrets/forgejo-runner-hl-node-02 |
| hl-node-03 | 21f9ccab-5418-4bdb-bc74-021effc3dc03 | /run/secrets/forgejo-runner-hl-node-03 |
| hl-node-04 | e9842b40-7feb-4fe9-b81c-4ebed7016304 | /run/secrets/forgejo-runner-hl-node-04 |

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

## Local acceptance

`nix build -L .#checks.x86_64-linux.forgejo-runner` builds a local image and starts
Forgejo plus three Podman runner VMs. The fixture uses real API registrations
and six independent inline jobs with test-only routing labels, no `uses:` action
downloads and no runtime Internet image pulls. It checks job-marker isolation,
live container privilege/socket mounts, all-three-runner work distribution,
restart identity stability, skipped unenrolled services, local state, absent
backup units, and journald output. Fixture UUID substitution follows the locked
nixpkgs `nixos/tests/forgejo.nix` pattern and is not used in production.
