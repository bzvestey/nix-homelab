# hl-node-02 restore preparation and batched CI

## Intent and delivery boundary

Prepare the installed hl-node-02 for the next migration milestone without
waiting for unrelated Pi images or creating one CI run per small change.
Keep production mounts, workloads, databases, ingress, runner execution and
scheduled backups disabled. Preparation does not authorize deployment,
source quiescing, private-data transfer, restore, production activation or
source retirement.

The current signed preparation branch already selects
`nas.tailbc181.ts.net:/mnt/spinners-1/kube-store/immich`. Build subsequent
preparation on that revision and publish one batch after local validation.
Do not promote this small change separately merely to start another CI run.

## Current evidence

Read-only inspection on 2026-10-10 confirmed:

- hl-node-02 `/var/lib` is ext4 on `/dev/mapper/cryptdata`, with
  1,802,586,243,072 available bytes; root has 58,431,889,408 available bytes.
- Memory totals 33,431,330,816 bytes and `/dev/kvm` exists. This is not proof
  that a particular unprivileged account has KVM access.
- No failed systemd units or NFS mounts were present. Immich, its ML worker,
  Mealie, Tuwunel, both database services and Caddy remain masked.
- Only `secrets/hosts/hl-node-02/bootstrap.yaml` exists for this host. Do not
  infer that application or backup credentials have been enrolled.
- Both architecture checks and all five host closures passed for the signed
  NFS preparation revision. Remaining Pi image builds do not gate this host.

Capacity must be remeasured before private-data staging, including simultaneous
archives, extracted copies, guest disks, repositories and 25% headroom. These
observations do not clear the inventory's unresolved production-data sizes.

## Secret mappings

Use the existing administrator-plus-host SOPS rule; do not add recipients or
create placeholder ciphertext. Keep bootstrap Tailscale credentials separate.

Prepare a separately importable host application-secret module. It is not
imported by the default host until actual encrypted input exists and has been
reviewed. Its prospective `secrets/hosts/hl-node-02/applications.yaml` contains:

| SOPS key | Runtime destination | Mode |
| --- | --- | --- |
| `immich-env` | `/run/secrets/immich.env` | `0600` |
| `mealie-env` | `/run/secrets/mealie.env` | `0600` |
| `tuwunel-config` | `/run/secrets/tuwunel.toml` | `0600` |
| `restic-repository` | `/run/secrets/restic-repository` | `0600` |
| `restic-password` | `/run/secrets/restic-password` | `0600` |
| `restic-s3-credentials` | `/run/secrets/restic-s3-credentials` | `0600` |

All mappings are root-owned. Use the existing backup shared-credentials option,
not credential environment overrides. Do not restart or unmask consumers when
secrets are installed. Verify the managed runtime directory's access policy;
do not change a shared secrets directory blindly. Evaluate the module with
synthetic encrypted fixture inputs; never pass production plaintext into the
Nix store, public artifacts, arguments or logs.

Actual application identities, OIDC secrets and Tuwunel policy must be preserved
from approved source inputs. Do not generate replacement identities. Backup
repository access and its password require a reviewed destination; reuse of the
observability host's repository or password is not assumed.

## Isolated restore environment

Reuse the existing two-VM rehearsal in `wave-2-source-rehearsal.md`, instead of
unmasking the installed host or inventing a partially isolated host generation.
Keep real-hardware bootstrap unchanged. Build only the extended driver, never
invoke its synthetic test script against private inputs.

The preparation build succeeded with driver output
`/nix/store/kn0sl9snhvf1fy8gf1l0j25a54ww3sqp-nixos-test-driver-hl-node-02-services`.
It uses a 64 GiB application guest and 128 GiB rehearsal NAS guest, restricted
QEMU networking, and disabled backup timers. No VM was launched.

Provide a repeatable build target for this existing extension and a launcher
that fails closed unless its work/output directory is on verified encrypted
scratch. Launch only under separate authorization, inside a network namespace
without uplinks. Prove guest isolation as specified by the existing runbook
before copying private data; QEMU restricted networking alone is insufficient.
Do not expose the installed host's production NFS, SOPS secrets or backup
repository to the guests. Guest credentials and repository are rehearsal-only.
The snapshot-derived library is copied into the isolated NAS guest, not mounted
from production. Review its freshness and capacity before transfer.

This environment demonstrates restores; it does not perform the eventual
production restore onto the installed host. That requires a separate reviewed
activation and single-writer cutover procedure.

## CI scope and batching

Keep one preparation-branch push per meaningful milestone. Run formatting,
linting, evaluation and affected tests locally before that push. Do not weaken
Comin signature requirements or deploy untested revisions to avoid CI latency.

Add a tested changed-file selector shared by checks and image workflows:

- Documentation-only changes skip system and image builds.
- A host-only change selects that host closure and the relevant architecture
  checks, preserving the existing KVM/non-KVM distinction.
- Shared modules, packages, topology, flake inputs, secrets policy and CI changes
  select broader checks and closures. Unknown paths or missing comparison
  history conservatively select the full validation set.
- Normal application/secret preparation does not rebuild installer images.
  Installer-specific changes select their affected image family. Add explicit
  manual image selection for cases where a fresh image is actually required.
- Initial pushes and pull requests must use the correct comparison range, not
  only the last commit. A batch can change files across several commits.

Keep this first implementation conservative: do not introduce automatic reuse
of another run's success or skip validation merely because a branch was pushed
before. Exact-revision promotion may still trigger GitHub workflows; reducing
duplicate promotion runs is a separate improvement requiring a trustworthy
clearance policy.

## Validation and review gate

Before publishing the batch, test changed-file selection for host-only,
documentation-only, installer, shared, unknown, initial-push and multi-commit
changes. Test the secret mapping with synthetic inputs and prove credentials
do not defeat bootstrap masks. Verify the rehearsal build target evaluates and
builds without launching VMs or reading private data; test launcher rejection
before sensitive data is supplied. Run the full local x86 checks and inspect
the resulting diff. Do not update the lockfile.

This is a proposed implementation design. Review it before adding the new
mapping, rehearsal target/launcher or CI selector. Review/approval of this
design does not authorize any live operation listed in the delivery boundary.
