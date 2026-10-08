# Task 14: source capture and offline real-data rehearsal

**Preparation only; not permission to run this procedure.** This document has
not exported data, stopped source workloads, taken snapshots, booted the driver,
or restored production data. Every command below is a **future authorized
command**, except the explicitly read-only preparation section. Parent review
and separate maintenance/data-handling approval are required. No installer,
drain, PVC deletion, source retirement, production restore, route change,
1Password sign-in, commit, push, or production policy change is included.

## 1. Fail-closed approval and NAS gate

STOP: NAS transport/trust, covering ZFS dataset names, snapshot identities,
read-only snapshot subpaths, and quiesced Tuwunel sizes are unresolved. These
NFS paths on `10.15.4.101` are confirmed **paths, not dataset names**:

| Application | Live root | Capture exclusions |
| --- | --- | --- |
| Immich library | `/mnt/spinners-1/kube-store/immich` | `./postgres` |
| Mealie files | `/mnt/spinners-1/kube-store/mealie` | `./postgres` |
| Tuwunel RocksDB/media | `/mnt/flash-1/kube-store/tuwunel` | `./hookshot` |

The NAS operator must supply authenticated administrative access with verified
host trust **or** perform manual snapshots under the approved maintenance
window. They must prove coverage of every root and child dataset, provide
snapshot IDs, creation times and immutable read-only subpaths, and verify all
required files are present. Do not invent NAS users, dataset names, APIs or
privileged helper pods. There is deliberately no executable NAS snapshot
command here. Do not begin quiescing until the operator is ready and this gate
is signed off. Never substitute a directory copy of live RocksDB.

Approve a bounded interruption with a deadline and abort/recovery owner; do not
promise a duration. Dumps and snapshots occur while writers are stopped;
large file archives are made from snapshots **after source service resumes**.
Retain source PVCs, logical dumps and protective snapshots throughout.

Applications are OpenTofu-managed Deployments (`modules/deployment/main.tf`,
`spec.replicas = each.value.replicas`), not ArgoCD. Exclude concurrent OpenTofu
applies, discover HPAs/other scalers/operators and suspend their reconciliation
through an approved mechanism before maintenance. If reconciliation cannot be
controlled, STOP. Record observed desired replicas and require this baseline:

| Namespace/deployment | Original replicas |
| --- | ---: |
| immich/immich-server | 1 |
| immich/immich-machine-learning | 1 |
| mealie/mealie | 1 |
| tuwunel/tuwunel | 1 |
| tuwunel/hookshot | 0 (excluded; remains zero) |

Both CNPG pods are `pg-cluster-1`, container `postgres`, on `workerw1` (future
hl-node-02). **Leave both database pods alive** for logical dumps. Files reside
on the NAS. Stop both Immich writers, not just its server.

## 2. Private storage, compatibility and evidence prerequisites

Keep private data outside Git, the Nix store and public/review artifacts.
Controller home was ext4 on
`/dev/mapper/luks-bdcd61d5-4f6a-4d4d-b8a2-b69c6ddf4db5`, with approximately
1.24 TB free at collection; revalidate encryption, backing device and free
bytes before sensitive collection. Establish a mode-0700 scratch directory on
that verified encrypted storage; use umask 077, no shell tracing, private logs,
runtime key paths (never key contents in argv/logs), and no plaintext long-term
retention. Encrypt immutable exports to administrator recipient
`age1h9s2cpcl8vrtxwq0nlsd86uu0q005v90fmwvwd39ayryy4kvvfdsdz25jz`.
History, driver output, manifests and tokens are sensitive too.

All four jobs currently have `maxPayloadBytes = 1073741824` (1 GiB). Measure
the actual custom-format dump, state logical bytes and final tar separately;
each regular file, aggregate logical bytes and archive bytes must fit. Maximum
archive entries are 100,000; preflight both files and directories. Safe relative
names match `[A-Za-z0-9][A-Za-z0-9._/-]*`, without empty, dot/dot-dot or doubled
slash components. Reject symlinks, multiply-linked files, devices and other
special entries. Do not rename application files to evade validation or raise
budgets silently. The observed 1.48 GB raw Immich PG directory does **not**
establish whether its compressed `pg_dump -Fc` fits; measure the dump.
Oversize or incompatible real data is a STOP and separate reviewed change gate.

Preserve application image pins in [the Wave 2 runbook](wave-2-hl-node-02.md).
Source Immich is PG16.9: cube 1.5, earthdistance 1.2, pg_trgm 1.6, unaccent
1.1, uuid-ossp 1.1, vector 0.8.0, vchord 0.4.3, plpgsql 1.0; relation owners
are app/postgres. Mealie is PG17.5, pg_trgm 1.6, plpgsql 1.0, owner app.
Keep majors and extension pins; record exact source versions before export.
Use the verified count SQL below; discover schema only for additional sampled
assertions. No fabricated backup/count/size values qualify as evidence.

## 3. Authorized source capture

Commands use a Bash session, `set -euo pipefail`, no TTY and no credential argv.
Set `secure` to the approved scratch path. Record a unique capture ID, UTC
window, revision, source deployment counts/images and private SQL assertions.
Run read-only discovery before approving mutations:

```bash
set -euo pipefail
umask 077
: "${secure:?approved encrypted scratch required}"
exec >>"$secure/discovery.private.log" 2>&1
findmnt -T "$secure" -o SOURCE,FSTYPE,TARGET
df -B1 "$secure"
k=(kubectl --kubeconfig /home/bzvestey/dev/new-cluster/kubeconfig --request-timeout=15s)
for ns in immich mealie tuwunel; do
  "${k[@]}" -n "$ns" get deployment,hpa,pods -o wide
done
for ns in immich mealie; do
  "${k[@]}" exec -n "$ns" pg-cluster-1 -c postgres -- \
    psql -X -U postgres -d app -At -v ON_ERROR_STOP=1 \
    -c 'SELECT version(); SELECT extname,extversion FROM pg_extension ORDER BY extname; SELECT schemaname,tablename,tableowner FROM pg_tables ORDER BY 1,2;'
done
```

After explicit maintenance approval and all gates, install recovery **before**
scaling. This restores original counts on normal exit, timeout/failure, or
catchable signals. A controller loss requires the named recovery operator to
execute the same recovery actions. Recovery failures require escalation, not
permission to leave the source stopped. Independently confirm application
health, not only rollout status; check existing source authenticated health and
private continuity assertions without printing credentials.

```bash
set -euo pipefail
umask 077
: "${secure:?}"
: "${maintenance_approval_file:?reviewed nonsecret approval record}"
test -s "$maintenance_approval_file"
# The record documents separately granted permission; its existence grants none.
: "${capture_deadline_utc:?approved absolute UTC deadline, YYYY-MM-DDTHH:MM:SSZ}"
: "${source_health_check:?approved executable checking all source apps privately}"
[[ "$capture_deadline_utc" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
deadline=$(date -u -d "$capture_deadline_utc" +%s)
budget() {
  remaining=$((deadline - $(date -u +%s)))
  test "$remaining" -gt 0 || return 1
  if [ "$remaining" -lt "$1" ]; then printf '%s' "$remaining"; else printf '%s' "$1"; fi
}
bounded() { local seconds; seconds=$(budget "$1") || return 1; shift; timeout --signal=KILL "$seconds" "$@"; }
stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ' >>"$secure/capture-times.private"; }
exec >>"$secure/capture.private.log" 2>&1
k=(kubectl --kubeconfig /home/bzvestey/dev/new-cluster/kubeconfig --request-timeout=15s)
recover_source() {
  rc=$?
  trap - EXIT INT TERM
  failed=0
  for pair in immich/immich-server immich/immich-machine-learning mealie/mealie tuwunel/tuwunel; do
    ns=${pair%/*}; dep=${pair#*/}
    "${k[@]}" -n "$ns" scale deployment "$dep" --replicas=1 || failed=1
  done
  "${k[@]}" -n tuwunel scale deployment hookshot --replicas=0 || failed=1
  for pair in immich/immich-server immich/immich-machine-learning mealie/mealie tuwunel/tuwunel; do
    "${k[@]}" -n "${pair%/*}" rollout status "deployment/${pair#*/}" --timeout=180s || failed=1
    test "$("${k[@]}" -n "${pair%/*}" get deployment "${pair#*/}" -o json | jq '.spec.replicas')" -eq 1 || failed=1
  done
  test "$("${k[@]}" -n tuwunel get deployment hookshot -o json | jq '.spec.replicas')" -eq 0 || failed=1
  timeout --kill-after=5 300 "$source_health_check" || failed=1
  stamp
  if [ "$failed" -ne 0 ]; then
    echo 'STOP: source recovery incomplete; escalate to recovery operator' >&2
    exit 1
  fi
  exit "$rc"
}
trap recover_source EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for pair in immich/immich-server immich/immich-machine-learning mealie/mealie tuwunel/tuwunel; do
  ns=${pair%/*}; dep=${pair#*/}
  bounded 30 "${k[@]}" -n "$ns" scale deployment "$dep" --replicas=0
  # Polling handles pods already deleted; never hide a failed kubectl query.
  stop_end=$(( $(date +%s) + $(budget 180) ))
  while :; do
    pods=$(bounded 15 "${k[@]}" -n "$ns" get pods -l "app=$dep,part=pod" -o json)
    test "$(printf '%s' "$pods" | jq '.items | length')" -ne 0 || break
    test "$(date +%s)" -lt "$stop_end"
    bounded 2 sleep 1
  done
  replicas=$(bounded 15 "${k[@]}" -n "$ns" get deployment "$dep" -o json)
  test "$(printf '%s' "$replicas" | jq '.spec.replicas')" -eq 0
  printf '%s\n' "$pods" >"$secure/$ns-$dep.stopped-pods.json"
  printf '%s\n' "$replicas" >"$secure/$ns-$dep.stopped-deployment.json"
  stamp
done
# STOP here unless the operator proves all writers stopped and snapshots ready.
immich_sql='SELECT count(*) FROM public."asset"; SELECT count(*) FROM public."album"; SELECT count(*) FROM public."user"; SELECT count(*) FROM public."system_metadata";'
mealie_sql='SELECT count(*) FROM public.recipes; SELECT count(*) FROM public.users; SELECT count(*) FROM public.groups;'
printf '%s\n' "$immich_sql" >"$secure/immich-count.sql"
printf '%s\n' "$mealie_sql" >"$secure/mealie-count.sql"
for ns in immich mealie; do
  stamp
  bounded 30 "${k[@]}" exec -n "$ns" pg-cluster-1 -c postgres -- \
    psql -X -At -U postgres -d app -v ON_ERROR_STOP=1 \
    -c 'SHOW server_version; SELECT extname,extversion FROM pg_extension ORDER BY extname;' \
    >"$secure/$ns-source-versions"
  bounded 60 "${k[@]}" exec -i -n "$ns" pg-cluster-1 -c postgres -- \
    psql -X -At -U postgres -d app -v ON_ERROR_STOP=1 \
    <"$secure/$ns-count.sql" >"$secure/$ns-source.counts"
  stamp
done
read -r -t "$(budget 60)" -p 'After stopped-writer/count proof, type WRITERS-STOPPED: ' confirmation </dev/tty 2>/dev/tty
test "$confirmation" = WRITERS-STOPPED
stamp
recipient=age1h9s2cpcl8vrtxwq0nlsd86uu0q005v90fmwvwd39ayryy4kvvfdsdz25jz
for ns in immich mealie; do
  out="$secure/$ns-database.dump.age"
  test ! -e "$out" && test ! -e "$out.partial"
  stamp
  if ! bounded 300 bash -o pipefail -c \
      'kubectl --kubeconfig /home/bzvestey/dev/new-cluster/kubeconfig --request-timeout=15s exec -n "$1" pg-cluster-1 -c postgres -- pg_dump -U postgres -d app -Fc | age -r "$2"' \
      bash "$ns" "$recipient" >"$out.partial"; then
    rm -f -- "$out.partial"
    exit 1
  fi
  test -s "$out.partial"
  mv -- "$out.partial" "$out"
  bounded 30 sha256sum "$out" >"$out.sha256"
  stamp
done
# NAS operator now snapshots all proven covering datasets while writers remain stopped.
# Require snapshot IDs, UTC times, read-only paths, coverage and measured sizes.
# If absent, abort: EXIT recovery runs. Do not archive live NAS roots.
# This prompt bounds operator confirmation; the approved deadline may be shorter.
read -r -t "$(budget 300)" -p 'After snapshot evidence is recorded, type SNAPSHOTS-PROVEN: ' confirmation </dev/tty 2>/dev/tty
test "$confirmation" = SNAPSHOTS-PROVEN
stamp
# Successful confirmation invokes recovery; otherwise EXIT recovery also runs.
exit 0
```

The 180/300-second bounds are abort limits, not an outage promise. Operator
snapshot work also needs the approved deadline; do not wait indefinitely.
Before each operator snapshot action, communicate `budget STEP_MAX` seconds
and the absolute UTC deadline; the independently approved NAS operator must
cap its operation to that remainder or abort. Snapshot command details remain
the NAS gate, not an invented transport here. Recovery is deliberately outside
this deadline; its independent bounds cannot cancel restarting source services.
Do not execute this block unattended: typed confirmations require independent
evidence, not merely pressing Enter. After recovery, verify original counts,
Hookshot zero, source health and private baseline assertions on both success
and failure. Only then release reconciliation locks. Never stop/delete CNPG,
drain workerw1, or remove retained PVCs.

## 4. Normalize immutable inputs after source recovery

Authenticate read-only snapshot access; verify capture checksums. Archive
snapshot subpaths, never changing live paths. Preserve the **full Immich
library snapshot separately**; its library-only transfer excludes `./postgres`
and is not a fleet payload. There is no `immich-state` job. Mealie snapshot
capture excludes `./postgres`; Tuwunel excludes `./hookshot`, including its
cryptostore. Record exclusions and full snapshot coverage in the manifest.

Future snapshot-only file capture, after authenticated access presents the
proved read-only snapshot root locally. This is **not** a NAS access command;
`snapshot_root` must never be a live root. Run separately for each application:

```bash
set -euo pipefail
umask 077
: "${snapshot_root:?proved read-only snapshot root}" "${encrypted_out:?}"
: "${application:?}" "${snapshot_manifest:?operator coverage and ID record}"
test -s "$snapshot_manifest"
test ! -e "$encrypted_out" && test ! -e "$encrypted_out.partial"
case "$application" in
  immich|mealie) exclusions=(--exclude=./postgres) ;;
  tuwunel) exclusions=(--exclude=./hookshot) ;;
  *) exit 1 ;;
esac
recipient=age1h9s2cpcl8vrtxwq0nlsd86uu0q005v90fmwvwd39ayryy4kvvfdsdz25jz
if ! tar "${exclusions[@]}" -C "$snapshot_root" -cf - . | \
    age -r "$recipient" >"$encrypted_out.partial"; then
  rm -f -- "$encrypted_out.partial"
  exit 1
fi
test -s "$encrypted_out.partial"
mv -- "$encrypted_out.partial" "$encrypted_out"
sha256sum "$encrypted_out" >"$encrypted_out.sha256"
```

On encrypted scratch, decrypt each DB into a distinct empty staging directory
as `database.dump`, using `age -d -i "$runtime_age_key_path"`; checksum and
measure plaintext privately. For state, copy the proved snapshot's contents
into `stage/state/` with the stated exclusions, preserving bytes. Validate
safe grammar, link/type constraints, counts and byte bounds **before** building
tar. Reject on any failure; use `.partial` outputs and atomic rename only after
success. Keep immutable age-encrypted inputs/checksums long term; plaintext is
temporary and subject to the approved retention/cleanup policy.

Run on encrypted host scratch once per input: `kind=db` for dumps, `state`
for Mealie/Tuwunel, `library` for Immich files. Use new absolute `stage`/`plain`
paths below `secure`. Library limits are approved measured budgets, not fleet
limits. Validate ALL archive members before extraction, including links/types.

```bash
set -euo pipefail
umask 077
: "${secure:?}" "${encrypted_input:?}" "${runtime_age_key_path:?}"
: "${stage:?}" "${plain:?}" "${kind:?}"
: "${runtime_python:?public Python 3 interpreter executable}"; test -x "$runtime_python"
secure=$(realpath -e "$secure")
stage=$(realpath -m "$stage"); plain=$(realpath -m "$plain")
[[ "$secure" = /* && "$stage" = "$secure/"* && "$plain" = "$secure/"* ]]
test ! -e "$stage" && test ! -e "$plain" && test ! -e "$plain.partial"
sha256sum -c "$encrypted_input.sha256" >"$secure/checksum.private.log"
age -d -i "$runtime_age_key_path" -o "$plain.partial" "$encrypted_input"
mv "$plain.partial" "$plain"
mkdir -m 0700 "$stage"
case "$kind" in
  db) test -s "$plain"; test "$(stat -c %s "$plain")" -le 1073741824
      mv "$plain" "$stage/database.dump" ;;
  state|library)
    max_bytes=1073741824; max_entries=99998
    if [ "$kind" = library ]; then
      : "${library_max_bytes:?approved measured budget}" "${library_max_entries:?}"
      max_bytes=$library_max_bytes; max_entries=$library_max_entries
    fi
    "$runtime_python" -I - "$plain" "$max_bytes" "$max_entries" "$kind" <<'PY'
import re, sys, tarfile
limit, entries = int(sys.argv[2]), int(sys.argv[3])
seen, total = set(), 0
with tarfile.open(sys.argv[1], 'r:') as archive:
    for member in archive:
        name = member.name
        if name in ('.', './'):
            assert member.isdir()
            name = '.'
        else:
            if name.startswith('./'): name = name[2:]
            if member.isdir() and name.endswith('/'): name = name[:-1]
            # State is normalized under state/; preserve legitimate root dotfiles.
            assert re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]*', 'state/' + name if sys.argv[4] == 'state' else name)
            assert all(part not in ('', '.', '..') for part in name.split('/'))
        assert name not in seen
        seen.add(name)
        assert len(seen) <= entries
        assert member.isdir() or member.isreg()
        assert not member.linkname
        assert 0 <= member.size <= limit
        total += member.size
        assert total <= limit
PY
    dest=$stage
    if [ "$kind" = state ]; then mkdir -m 0700 "$stage/state"; dest="$stage/state"; fi
    tar --extract --file "$plain" --directory "$dest" --no-same-owner --no-same-permissions
    ;;
  *) exit 1 ;;
esac
```

Use `$secure/library-stage` and `$secure/mealie-state-stage` as the respective
extraction stages, and `$secure/JOB.tar` for normalized archives below. Before
driver launch, generate private full-tree manifests (safe names were validated
above). Library extraction also needs a post-extraction check rejecting any
special/multiply-linked entry; it is not subject to fleet byte budgets.

```bash
set -euo pipefail
umask 077
for tree in "$secure/library-stage" "$secure/mealie-state-stage/state"; do
  test -d "$tree"
  test -z "$(find "$tree" -mindepth 1 ! -type f ! -type d -print -quit)"
  test -z "$(find "$tree" -type f -links +1 -print -quit)"
done
(cd "$secure/library-stage"; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum) >"$secure/library.sha256"
(cd "$secure/mealie-state-stage/state"; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum) >"$secure/mealie-state.sha256"
```

Future normalization commands, with populated `stage`, exact approved
`job` and new scratch archive path (normalization only, no host restic import):

```bash
set -euo pipefail
umask 077
: "${stage:?}" "${archive:?}" "${job:?}"
case "$job" in immich-db|mealie-db|mealie-state|tuwunel-state) ;; *) exit 1;; esac
test ! -e "$archive" && test ! -e "$archive.partial"
# Enumerate to a file so find failures cannot disappear in process substitution.
find "$stage" -mindepth 1 -print0 >"$archive.entries"
count=0; total=0
while IFS= read -r -d '' entry; do
  rel=${entry#"$stage"/}
  [[ "$rel" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]
  case "/$rel/" in *//*|*/./*|*/../*) exit 1;; esac
  test ! -L "$entry"
  count=$((count + 1)); test "$count" -le 99999 # tar also includes ./
  if [ -f "$entry" ]; then
    test "$(stat -c %h "$entry")" -eq 1
    bytes=$(stat -c %s "$entry")
    test "$bytes" -le 1073741824
    total=$((total + bytes)); test "$total" -le 1073741824
  else
    test -d "$entry"
  fi
done <"$archive.entries"
case "$job" in
  *-db) test -s "$stage/database.dump" ;;
  *-state) test -d "$stage/state"; test -n "$(find "$stage/state" -mindepth 1 -print -quit)" ;;
esac
tar -C "$stage" -cf "$archive.partial" .
test "$(stat -c %s "$archive.partial")" -le 1073741824
mv -- "$archive.partial" "$archive"
sha256sum "$archive" >"$archive.sha256"
# Normalization only: import happens in the guest's actual restore repository.
```

DB tar members are `./database.dump`; state members are `./state/<files>`
(plus directory entries). Always build `tar -C stage ... .`, not absolute paths
or a parent directory. Resolve import output to a **full** snapshot ID, match
exact `fleet-job=<job>` tag and `fleet-payload.tar` path, record all tags and
checksums; reject ambiguity. Never restore `latest` or a short ID. Import only
after private data approval and isolation verification. `fleet-restore` performs
bounded archive extraction and repeats grammar/type/required-path checks.

## 5. Read-only preparation: evaluate/build driver only

Root nixpkgs_2 is pinned to `c59305bab2065cfecc4944690d9eedbb56f3a9fa`.
Reuse the two-node check with its supported `.extend` API; do not invoke its
synthetic `testScript`. This expression was parent-evaluated to
`/nix/store/y37azaqlk43pzsy1b19hvfg49m34i8wb-nixos-test-driver-hl-node-02-services.drv`.
Re-evaluate at the reviewed revision; builds may fetch public dependencies but
must happen **before** any private data enters the offline environment.

```bash
nix eval --impure --raw --expr '
let f = builtins.getFlake (toString ./.);
    t = f.checks.x86_64-linux.hl-node-02-services;
in (t.extend { modules = [ ({ lib, ... }: {
  nodes.machine = {
    virtualisation.diskSize = lib.mkForce 65536;
    virtualisation.restrictNetwork = true;
    systemd.timers = lib.genAttrs [
      "fleet-backup-immich-db" "fleet-backup-mealie-db"
      "fleet-backup-mealie-state" "fleet-backup-tuwunel-state"
      "fleet-backup-check"
    ] (_: { enable = lib.mkForce false; });
  };
  nodes.nas = {
    virtualisation.diskSize = lib.mkForce 131072;
    virtualisation.restrictNetwork = true;
  };
}) ]; }).driver.drvPath'
```

Build that **driver derivation only**, not the check/testcase:

```bash
set -euo pipefail
: "${driver_drv:?full reviewed driver derivation path}"
driver=$(nix build --no-link --print-out-paths "$driver_drv^out")
test -x "$driver/bin/nixos-test-driver"
```

Before sensitive input, freshly prove capacity for library plus local state,
archives, restic repository, protective backups, output and at least 25%
headroom, on both encrypted host scratch and actual VM filesystems. A roughly
75 GB library cannot fit RAM tmpfs. NAS disk 131072 MiB and machine 65536 MiB
are starting allocations, not proof of fit; STOP if fresh measurements fail.
Account simultaneously for encrypted inputs, decrypted archives, extracted
host trees, an additional shared-exchange copy, both guest disks, repository,
protective copies and outputs. Exchange is persistent on encrypted host scratch
in this launch layout, not inherently tmpfs. Recheck `findmnt -T`, `df -B1` and
`du -sb` for scratch/exchange/output, plus guest filesystems. The prior ~1.24 TB
is not a reservation. Never retain a ~75 GB library tar on the 128 GiB NAS disk
then extract another ~75 GB there: copy the extracted host directory directly.
No production payload is a Nix input or a `writeText` value.

## 6. Authorized offline runtime bootstrap

Use a private user+network namespace with no uplink/default routes. Keep cwd,
TMPDIR, XDG_RUNTIME_DIR, REPL history and output on approved encrypted scratch.
No production NFS, tailnet, comin or cloudflared; block actual OIDC, client and
federation outbound. Verify isolation before transferring real data, including
guest routes/interface reachability and effective timer/service configuration.
Use a short private runtime path on that same verified encrypted filesystem:
the longer capture path exceeds Linux's Unix-socket limit when QEMU appends
its VM/virtiofs socket directories. Record this additional scratch location
and include it in capacity accounting and eventual plaintext cleanup.

```bash
set -euo pipefail
umask 077
: "${secure:?}" "${driver:?}"
rehearsal_root=$(mktemp -d "$HOME/.hlr.XXXXXX")
test "$(findmnt -n -T "$rehearsal_root" -o SOURCE)" = "$(findmnt -n -T "$secure" -o SOURCE)"
install -d -m 0700 "$rehearsal_root/tmp" "$rehearsal_root/runtime" "$secure/output"
export TMPDIR="$rehearsal_root/tmp" XDG_RUNTIME_DIR="$rehearsal_root/runtime"
export HISTFILE=/dev/null PYTHON_HISTORY=/dev/null
export secure rehearsal_root
cd "$secure"
unshare --user --map-root-user --net -- sh -eu -c \
  'ip link set lo up; test -z "$(ip route show default)"; test -z "$(ip -6 route show default)"; ip -j link | jq -e '\''all(.[]; .ifname == "lo")'\''; exec "$@"' sh \
  "$driver/bin/nixos-test-driver" --interactive -o "$secure/output"
```

At the driver REPL use only manual operations; **never** `test_script()` or
`run_tests()`. Start sequentially:

```python
nas.start()
nas.wait_for_unit("nfs-server")
machine.start()
machine.wait_for_unit("multi-user.target")
for node in (nas, machine):
    # Restricted QEMU networking still advertises an IPv6 NAT default route.
    # Disable its eth0 interface; eth1 is the private inter-VM rehearsal LAN.
    node.succeed("systemctl stop dhcpcd; ip link set eth0 down; ip -4 route flush default; ip -6 route flush default")
    node.succeed("ip -br addr; ip route; ip -6 route; df -B1 /var/lib")
    node.succeed("test -z \"$(ip route show default)\" && test -z \"$(ip -6 route show default)\"")
    node.succeed("command -v timeout; command -v bash")
    node.fail("timeout 5 bash -c 'exec 3<>/dev/tcp/10.15.4.101/2049'")
machine.succeed("systemctl stop podman-immich podman-immich-ml podman-mealie podman-tuwunel")
for unit in ("podman-immich", "podman-immich-ml", "podman-mealie", "podman-tuwunel", "tailscaled", "comin", "cloudflared", "hookshot"):
    machine.fail(f"systemctl is-active --quiet {unit}")
for job in ("immich-db", "mealie-db", "mealie-state", "tuwunel-state", "check"):
    machine.fail(f"systemctl is-active --quiet fleet-backup-{job}.timer")
    machine.fail(f"systemctl is-enabled --quiet fleet-backup-{job}.timer")
machine.succeed("systemctl list-timers --all; systemctl show podman-immich podman-immich-ml podman-mealie podman-tuwunel -p ActiveState -p SubState -p ConditionResult")
```

Runtime machines are `nas` and `machine`; NAS exports `/srv/library` and
machine mounts `nas:/srv/library` at `/mnt/bulk/immich`. Both nodes are trusted private rehearsal
nodes. `copy_from_host` supports runtime copies but its exchange is shared
between both machines: do not treat it as per-guest secret isolation. Stage
large library data onto persistent guest disk, not a retained guest archive, and
prove bytes/counts/checksums before mounting it. Use only snapshot-derived
library content; never connect this VM to production NFS.

Do not copy bootstrap lines from the synthetic testScript. Create isolated
fixture credentials/runtime configuration without reading production secrets.
Required names are `/run/secrets/immich.env` (`DB_PASSWORD`),
`/run/secrets/mealie.env` (`POSTGRES_PASSWORD`, fixture `OIDC_CLIENT_SECRET`),
`/run/secrets/tuwunel.toml`, mode 0600 with parent 0700; missing files are
intentional startup conditions. Test backup configuration uses `/run/repository`
and `/run/restic-password`, **not** default `/run/secrets/restic-*`. Point the
former to an isolated on-disk repository, initialize with the latter, and keep
timers disabled. No production repository/cloud credentials are needed.

Initialize native clusters with these isolated runtime files using
`systemctl start postgres-immich postgresql.target`; keep app units stopped.
Immich PG16 uses user `postgres-immich`, socket `/run/postgres-immich`, port
5433, data `/var/lib/postgres-immich`; Mealie PG17 uses `postgres`, socket
`/run/postgresql`, port 5432, data `/var/lib/postgresql/17`. Both use role/DB
`app`. Verify separation and matching extension availability before restore.

For Tuwunel, do not start against an empty directory. Prepare runtime TOML
preserving `matrix.minastas.social`, `/var/lib/tuwunel`, port 8008, identity
provider/public IDs and production password-login policy; disable federation
and close registration for rehearsal. Use isolated credentials, omit retired
Hookshot configuration/registration/routes. Do not enable password login just
to make a test pass. Install runtime TOML while stopped, before fleet state
restore's automatic first startup. No source configuration is changed.

Public source registration/federation/password flags are true. Only the first
two become false; true password login is preserved, not enabled for checks.
Execute guest Bash fences at the REPL, not the host shell. All resulting output
stays private. Create this fixture while apps remain stopped; do not print
effective env/TOML. Wrap each fence in `bash -euo pipefail` (the driver shell is not guaranteed
to be Bash); e.g. `machine.succeed("bash -euo pipefail <<'REHEARSAL'\n" +
guest_block + "\nREHEARSAL", timeout=600)` with `guest_block` a raw multiline
string containing the fence. Confirmations in guest fences are approval
variables supplied at runtime after review, not interactive reads through the
driver's command channel.

```bash
set -euo pipefail
umask 077
systemctl stop podman-immich podman-immich-ml podman-mealie podman-tuwunel
install -d -m 0700 /run/secrets /var/lib/rehearsal /var/lib/rehearsal/evidence /var/lib/rehearsal/imports
test ! -e /run/repository && test ! -e /run/restic-password
printf 'DB_PASSWORD=isolated-immich-fixture\n' >/run/secrets/immich.env
printf 'POSTGRES_PASSWORD=isolated-mealie-fixture\nOIDC_CLIENT_SECRET=isolated-oidc-fixture\n' >/run/secrets/mealie.env
cat >/run/secrets/tuwunel.toml <<'TOML'
[global]
server_name = "matrix.minastas.social"
database_path = "/var/lib/tuwunel"
address = ["0.0.0.0"]
port = 8008
allow_registration = false
allow_federation = false
login_with_password = true

[[global.identity_provider]]
brand = "pocket-id"
name = "PocketID"
client_id = "9c05911b-c58f-449f-9792-40e87bb25b12"
client_secret = "isolated-oidc-fixture"
issuer_url = "https://id.minastas.xyz"
callback_url = "https://matrix.minastas.social/_matrix/client/unstable/login/sso/callback/9c05911b-c58f-449f-9792-40e87bb25b12"
default = true
userid_claims = ["preferred_username"]
TOML
printf '/var/lib/rehearsal/restic\n' >/run/repository
printf 'isolated-restic-fixture\n' >/run/restic-password
chmod 0600 /run/secrets/* /run/repository /run/restic-password
export RESTIC_REPOSITORY=$(cat /run/repository)
export RESTIC_PASSWORD_FILE=/run/restic-password
test "$RESTIC_REPOSITORY" = /var/lib/rehearsal/restic
test ! -e "$RESTIC_REPOSITORY"
restic init >/var/lib/rehearsal/evidence/repository-init.log
systemctl start postgres-immich postgresql.target
# Use each actual server's store package, never ambiguous PATH psql.
for spec in 'immich postgres-immich postgres-immich /run/postgres-immich 5433 16' 'mealie postgresql postgres /run/postgresql 5432 17'; do
  read -r app unit user socket port major <<<"$spec"
  pid=$(systemctl show "$unit" -p MainPID --value); test "$pid" -gt 0
  bin=$(dirname "$(readlink -f "/proc/$pid/exe")")
  "$bin/psql" --version | grep -Eq "PostgreSQL\) $major\."
  printf '%s\n' "$bin/psql" >"/var/lib/rehearsal/evidence/$app-psql-path"
  runuser -u "$user" -- "$bin/pg_isready" -h "$socket" -p "$port" -d app
  runuser -u "$user" -- "$bin/psql" -X -At -h "$socket" -p "$port" -d app -v ON_ERROR_STOP=1 \
    -c 'SHOW server_version; SELECT extname,extversion FROM pg_extension ORDER BY extname; SELECT name,version FROM pg_available_extension_versions ORDER BY name,version;' \
    >"/var/lib/rehearsal/evidence/$app-bootstrap-versions"
done
for unit in podman-immich podman-immich-ml podman-mealie podman-tuwunel; do
  if systemctl is-active --quiet "$unit"; then exit 1; fi
done
```

Review private version files against section 2 before imports. Patch differences
require review; majors and pinned extensions must match. Repeat installed
extension checks after restore; availability alone is insufficient.

At the REPL, after isolation/capacity approval, transfer extracted library
contents directly and the four normalized `$secure/JOB.tar` archives. Inspect
the driver's actual exchange backing path with `findmnt -T` and `df -B1`
before transfers; TMPDIR alone is not proof. Transfers are bounded.

```python
import os, signal, subprocess
secure = os.environ["secure"]
exchange = str(machine.shared_dir)
rehearsal_root = os.environ["rehearsal_root"]
assert os.path.commonpath((os.path.realpath(exchange), os.path.realpath(rehearsal_root))) == os.path.realpath(rehearsal_root)
subprocess.run(["findmnt", "-T", exchange], check=True)
subprocess.run(["df", "-B1", exchange, secure], check=True)
# copy_from_host has NO timeout parameter. Bound the whole host/API operation.
def copy_bounded(node, source, target, seconds):
    def expired(signum, frame):
        raise TimeoutError("runtime transfer exceeded approved step bound; STOP")
    previous = signal.signal(signal.SIGALRM, expired)
    signal.alarm(seconds)
    try:
        node.copy_from_host(source, target)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)
# Directory API targets must be absent, otherwise cp nests the source directory.
# Stop the guest automount too: replacing the NAS directory invalidates old FHs.
machine.succeed("systemctl stop mnt-bulk-immich.automount mnt-bulk-immich.mount", timeout=60)
nas.succeed("systemctl stop nfs-server && test -z \"$(find /srv/library -mindepth 1 -print -quit)\" && df -B1 /srv/library && rmdir /srv/library", timeout=60)
copy_bounded(nas, secure + "/library-stage", "/srv/library", 3600)
nas.succeed("systemctl start nfs-server")
copy_bounded(nas, secure + "/library.sha256", "/var/lib/library.host.sha256", 30)
nas.succeed("bash -o pipefail -c 'cd /srv/library; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum >/var/lib/library.guest.sha256; cmp /var/lib/library.host.sha256 /var/lib/library.guest.sha256'", timeout=3600)
nas.succeed("du -sb /srv/library; df -B1 /srv/library")
machine.succeed("systemctl start mnt-bulk-immich.automount mnt-bulk-immich.mount && findmnt /mnt/bulk/immich", timeout=60)
for job in ("immich-db", "mealie-db", "mealie-state", "tuwunel-state"):
    copy_bounded(machine, secure + "/" + job + ".tar", "/var/lib/rehearsal/imports/" + job + ".tar", 300)
    copy_bounded(machine, secure + "/" + job + ".tar.sha256", "/var/lib/rehearsal/imports/" + job + ".host.sha256", 30)
machine.succeed("test ! -e /var/lib/rehearsal/paired-state")
copy_bounded(machine, secure + "/mealie-state-stage/state", "/var/lib/rehearsal/paired-state", 300)
copy_bounded(machine, secure + "/mealie-state.sha256", "/var/lib/rehearsal/evidence/mealie-state.host.sha256", 30)
for app in ("immich", "mealie"):
    for suffix in ("count.sql", "source.counts", "source-versions"):
        copy_bounded(machine, secure + "/" + app + "-" + suffix, "/var/lib/rehearsal/evidence/" + app + "-" + suffix, 30)
```

Any interrupted copy is STOP: keep apps stopped, inspect partial guest/exchange
files and wait for any in-flight guest copy to finish before approved cleanup;
do not continue to import or accept partial transfers.

Compare a private relative-path SHA256 manifest of the full host library with
the NAS directory before acceptance, not only size. The guest checksum below
compares digest only because host checksum records contain host absolute paths.

```bash
set -euo pipefail
umask 077
export RESTIC_REPOSITORY=$(cat /run/repository) RESTIC_PASSWORD_FILE=/run/restic-password
test "$RESTIC_REPOSITORY" = /var/lib/rehearsal/restic
cd /var/lib/rehearsal/imports
for job in immich-db mealie-db mealie-state tuwunel-state; do
  test "$(sha256sum "$job.tar" | cut -d ' ' -f1)" = "$(cut -d ' ' -f1 "$job.host.sha256")"
  timeout --kill-after=5 300 restic backup --stdin --stdin-filename fleet-payload.tar \
    --tag "fleet-job=$job" --json <"$job.tar" >"$job.import.json"
  short=$(jq -er 'select(.message_type == "summary") | .snapshot_id' "$job.import.json")
  restic snapshots --json "$short" >"$job.snapshots.json"
  id=$(jq -er --arg tag "fleet-job=$job" 'if length == 1 and (.[0].tags | index($tag)) != null then .[0].id else error("ambiguous/tag mismatch") end' "$job.snapshots.json")
  [[ "$id" =~ ^[0-9a-f]{64}$ ]]
  restic ls --json "$id" >"$job.paths.json"
  jq -es 'map(select(.struct_type == "node")) | length == 1 and .[0].path == "/fleet-payload.tar" and .[0].type == "file"' "$job.paths.json" >/dev/null
  printf '%s\n' "$id" >"$job.snapshot-id"
  fleet-restore "$job" --snapshot "$id" --rehearsal
done
```

## 7. State-first restore and actual continuity proof

Import the four normalized archives into the isolated local repository and
record full tagged IDs. First run `fleet-restore JOB --snapshot FULL_ID
--rehearsal` for every job. DB rehearsal imports into a scratch database using
`--no-owner --no-acl`, then drops it; state rehearsal defaults to `true` after
archive validation. It is **not** a state/application continuity test.

Actual restores restart declared app units even if they were previously
stopped, then health-check. They are not a two-job transaction. Therefore for
Mealie **before its DB restore**, stage the coherent paired snapshot files
into `/var/lib/mealie`, verify manifest and set `mealie:mealie` ownership and
0750 directory/file modes with the app stopped. Do not run its state job first
and allow startup against an empty DB. This staging is a reviewed isolated
manual copy of the validated `state/.` payload; do not delete a nonempty target
without separately approving its protective copy. No app writes are allowed
until both intended payloads are ready. Then DB restore may start the app with
the paired state present; record this as two coordinated actions, not atomicity.
If subsequently testing the state restore job, stop Mealie again, preserve
its destination state and explicitly authorize `--force` for that isolated job.

Future isolated Mealie state-first staging, with `paired_state` pointing to the
validated extracted `state` directory and no nonempty destination accepted:

```bash
set -euo pipefail
: "${paired_state:?validated paired snapshot state directory}"
test "$paired_state" = /var/lib/rehearsal/paired-state
systemctl stop podman-mealie
test -d /var/lib/mealie
test -z "$(find /var/lib/mealie -mindepth 1 -print -quit)"
cp -a "$paired_state/." /var/lib/mealie/
chown -R mealie:mealie /var/lib/mealie
find /var/lib/mealie -type d -exec chmod 0750 {} +
find /var/lib/mealie -type f -exec chmod 0750 {} +
(cd /var/lib/mealie; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum) \
  >/var/lib/rehearsal/evidence/mealie-state.staged.sha256
cmp /var/lib/rehearsal/evidence/mealie-state.host.sha256 /var/lib/rehearsal/evidence/mealie-state.staged.sha256
date -u >/var/lib/rehearsal/evidence/mealie-paired-state-verified
```

For Immich, library must already be mounted and verified; stop server and ML
before DB restore. The DB job declares only `podman-immich.service`; keep ML
stopped until DB restore and initial assertions complete, then start ML.
For Tuwunel, restore real state into an empty stopped target before its first
startup. State defaults are root:root, 0750; Mealie is mealie:mealie, 0750.
Database paths become their respective OS-user ownership, files 0600 and
directories 0700. Record effective ownership/modes, not guessed container IDs.

Commands inside the isolated machine, one job at a time with its recorded ID:

Define these helpers in the same guest Bash invocation as each mutation below.
They use only `/run/repository` and `/run/restic-password`; full selected and
protective IDs, exact tags and the sole stored path are verified before writes.

```bash
set -euo pipefail
umask 077
export RESTIC_REPOSITORY=$(cat /run/repository) RESTIC_PASSWORD_FILE=/run/restic-password
test "$RESTIC_REPOSITORY" = /var/lib/rehearsal/restic
evidence=/var/lib/rehearsal/evidence
verify_id() {
  local job=$1 id=$2
  [[ "$id" =~ ^[0-9a-f]{64}$ ]]
  restic snapshots --json "$id" >"$evidence/$id.snapshot.json"
  jq -e --arg id "$id" --arg tag "fleet-job=$job" \
    'length == 1 and .[0].id == $id and (.[0].tags | index($tag)) != null' \
    "$evidence/$id.snapshot.json" >/dev/null
  restic ls --json "$id" >"$evidence/$id.paths.json"
  jq -es 'map(select(.struct_type == "node")) | length == 1 and .[0].path == "/fleet-payload.tar" and .[0].type == "file"' "$evidence/$id.paths.json" >/dev/null
}
protect() {
  local job=$1 id
  restic snapshots --json >"$evidence/$job.before-protect.json"
  fleet-backup-run "$job" >"$evidence/$job.protect.log" 2>&1
  restic snapshots --json >"$evidence/$job.after-protect.json"
  id=$(jq -er --slurpfile before "$evidence/$job.before-protect.json" --arg tag "fleet-job=$job" \
    '[.[] | select((.tags | index($tag)) != null) | select(.id as $id | ($before[0] | map(.id) | index($id)) == null)] | if length == 1 then .[0].id else error("protective ID ambiguous") end' \
    "$evidence/$job.after-protect.json")
  verify_id "$job" "$id"
  # The next internal backup can prune this middle same-hour snapshot.
  # A unique tag gives it its own group under the unchanged --group-by tags policy.
  local retention_tag="migration-protective=$id"
  restic tag --add "$retention_tag" "$id" >"$evidence/$job.protect-tag.log"
  restic snapshots --json --tag "$retention_tag" >"$evidence/$job.tagged-protect.json"
  id=$(jq -er 'if length == 1 then .[0].id else error("protective tag ambiguous") end' "$evidence/$job.tagged-protect.json")
  # Tagging rewrites the snapshot ID: record the new full ID, not the old one.
  verify_id "$job" "$id"
  printf '%s\n' "$id" >"$evidence/$job.explicit-protective-id"
}
actual_restore() {
  local job=$1 id=$2 rc=0
  shift 2
  verify_id "$job" "$id"
  restic snapshots --json >"$evidence/$job.before-actual.json"
  fleet-restore "$job" --snapshot "$id" "$@" >"$evidence/$job.actual.log" 2>&1 || rc=$?
  # Runs on success AND failure, retaining internal force backup IDs/metadata.
  restic snapshots --json >"$evidence/$job.after-actual.json"
  jq --slurpfile before "$evidence/$job.before-actual.json" \
    '[.[] | select(.id as $id | ($before[0] | map(.id) | index($id)) == null)]' \
    "$evidence/$job.after-actual.json" >"$evidence/$job.internal-protective.json"
  while read -r protective; do verify_id "$job" "$protective"; done \
    < <(jq -r '.[].id' "$evidence/$job.internal-protective.json")
  if [ -s "$evidence/$job.explicit-protective-id" ]; then
    verify_id "$job" "$(cat "$evidence/$job.explicit-protective-id")"
    # Read the complete explicit and internal payloads after success OR failure.
    while read -r protective; do
      timeout --kill-after=5 300 restic dump "$protective" fleet-payload.tar >/dev/null
    done < <(cat "$evidence/$job.explicit-protective-id"; jq -r '.[].id' "$evidence/$job.internal-protective.json")
  fi
  return "$rc"
}
```

```bash
set -euo pipefail
: "${job:?}" "${snapshot_id:?full 64-character ID}"
[[ "$snapshot_id" =~ ^[0-9a-f]{64}$ ]]
verify_id "$job" "$snapshot_id"
fleet-restore "$job" --snapshot "$snapshot_id" --rehearsal
# After state-first/library/bootstrap gates and explicit isolated mutation approval:
test "${isolated_mutation_approval:?separate explicit reviewed approval}" = RESTORE-APPROVED
case "$job" in
  immich-db)
    systemctl stop podman-immich podman-immich-ml
    protect "$job"
    actual_restore "$job" "$snapshot_id" --force ;;
  mealie-db)
    systemctl stop podman-mealie
    test -s "$evidence/mealie-paired-state-verified"
    protect "$job"
    actual_restore "$job" "$snapshot_id" --force ;;
  tuwunel-state)
    systemctl stop podman-tuwunel
    test -s /run/secrets/tuwunel.toml
    test -d /var/lib/tuwunel
    test -z "$(find /var/lib/tuwunel -mindepth 1 -print -quit)"
    date -u >"$evidence/tuwunel-verified-empty"
    actual_restore "$job" "$snapshot_id" ;;
  *) echo 'STOP: Mealie state requires paired staging review' >&2; exit 1 ;;
esac
```

Native DB directories are nonempty by design. `--force` first captures a
protective backup when the target is active/nonempty. DB restore validates
the dump in a scratch DB, drops only its `app`, creates it owned by `app` with
template0/locale C, then imports preserving dump ownership/ACLs. Never remove
an active PG data directory or force anything outside the isolated destination.
Before mutation, explicitly run `fleet-backup-run JOB` on the isolated target,
for DB jobs or nonempty state targets only; resolve/record its full tagged
protective ID and verify it. An empty first-restore Tuwunel target has no state
to back up: record verified emptiness, retain the immutable source snapshot,
and do not invoke a state backup whose required directory would be empty. The subsequent
`--force` operation also creates a protective snapshot internally; record that
additional ID after the operation, including on failure, and retain both.
Do not confuse these destination backups with the source capture IDs.

To prove the actual Mealie state **job** after paired staging and DB acceptance,
stop Mealie, record its protective state backup as above, revalidate the paired
full state ID/tag and explicitly approve this future isolated command:

```bash
set -euo pipefail
: "${mealie_state_snapshot_id:?full reviewed paired state ID}"
[[ "$mealie_state_snapshot_id" =~ ^[0-9a-f]{64}$ ]]
systemctl stop podman-mealie
verify_id mealie-state "$mealie_state_snapshot_id"
test "${isolated_state_approval:?separate explicit force approval}" = STATE-FORCE-APPROVED
protect mealie-state
actual_restore mealie-state "$mealie_state_snapshot_id" --force
```

This restarts Mealie and health-checks with its restored DB already in place.
Recompare the paired state/DB assertions immediately; no intervening client
writes are permitted. Do not claim all four actual job restores if this step
has not been performed and evidenced.

Health failure is STOP. After mutation, fleet-restore stops declared app units;
do not restart blindly. Preserve diagnostics privately, source and snapshots
intact, review protective restore IDs and recover only the isolated destination.
Built-in health checks are local endpoints, not complete continuity proof:
Immich `/api/server/ping` on 2283, Mealie `/api/app/about` on 9000, Tuwunel
`/_matrix/client/versions` on 8008. Verify Caddy locally as described in Wave 2;
never route a production client into this namespace.

Before declaring data acceptance, run matching destination counts against
the exact source SQL files, privately compare outputs and verify installed
versions/extensions again. Use the version-specific paths saved at bootstrap.

```bash
set -euo pipefail
umask 077
evidence=/var/lib/rehearsal/evidence
for spec in 'immich postgres-immich /run/postgres-immich 5433' 'mealie postgres /run/postgresql 5432'; do
  read -r app user socket port <<<"$spec"
  psql=$(cat "$evidence/$app-psql-path")
  runuser -u "$user" -- "$psql" -X -At -h "$socket" -p "$port" -d app -v ON_ERROR_STOP=1 \
    <"$evidence/$app-count.sql" >"$evidence/$app-destination.counts"
  cmp "$evidence/$app-source.counts" "$evidence/$app-destination.counts"
  runuser -u "$user" -- "$psql" -X -At -h "$socket" -p "$port" -d app -v ON_ERROR_STOP=1 \
    -c 'SHOW server_version; SELECT extname,extversion FROM pg_extension ORDER BY extname;' \
    >"$evidence/$app-restored-versions"
  # Exact extensions must match; server patch differences remain a review gate.
  tail -n +2 "$evidence/$app-source-versions" >"$evidence/$app-source-extensions"
  tail -n +2 "$evidence/$app-restored-versions" >"$evidence/$app-restored-extensions"
  cmp "$evidence/$app-source-extensions" "$evidence/$app-restored-extensions"
done
# Start ML only after Immich counts/private initial assertions and version review.
```

Compare captured **real** asymmetric IDs/counts and sampled records privately:

* Immich: asset/user/album/settings counts, DB owners and exact extension
  versions, actual VectorChord index query behavior, migration success,
  original/thumbnail rendering against snapshot bytes, persisted OIDC/settings
  equality with secret fields redacted. No invented synthetic rows establish
  real-data continuity; ML cache is disposable, not a payload.
* Mealie: recipe/user/group counts and asymmetric recipe IDs, app ownership,
  associated recipe/profile files, session/signing state and hashes. Exclude
  only explained volatile log changes from comparison; retain an exact original
  manifest. Verify password login remains disabled and OIDC configuration
  remains compatible, without claiming an external login succeeded.
* Tuwunel: server identity, existing account/device IDs, rooms/messages/media
  continuity and sampled media hashes through approved local assertions or
  existing authorized sessions. Keep tokens out of argv/logs. If existing
  sessions cannot be safely used offline, record the unproved client assertion
  as a later gate, not permission to weaken login/registration policy.

Offline proves local counts/files/versions/endpoints only. Actual Pocket ID
OIDC, production client continuity, public routes and federation require later
separately approved shadow/integration gates. No such proof is implied here.

## 8. Private evidence and completion checklist

Populate a private manifest; never put real record IDs, secrets or payloads in
the repository/report. Blank entries mean unverified, not zero.

| Evidence | Required capture/restore fields |
| --- | --- |
| Approval/isolation | reviewer, maintenance deadline, recovery owner, revision, namespace route proof |
| Capture identity | capture ID, UTC start/stop/resume and consistent window, source image/PG/extension versions |
| Source control | original/recovered replicas, scaler/apply lock, stopped-writer proof, restart health on success/failure |
| NAS | authenticated trust, proven dataset coverage, full snapshot IDs/times/read-only subpaths, exclusions |
| Payload | exact job, files/counts, logical/archive/encrypted byte sizes, SHA256, safe-name/link/type checks |
| Restore | full import ID and all tags, protective IDs, selected restore ID, rehearsal/actual exit and health results |
| Application | private source/restored counts/asymmetric IDs, files/hash samples, ownership/modes, continuity assertions |
| Retention | encrypted immutable input locations, protective retention, plaintext cleanup owner/date |

- [ ] All unresolved NAS, sensitive-data acceptance and maintenance gates approved.
- [ ] Source restored to original counts and health; Hookshot excluded; PVCs retained.
- [ ] Exports/snapshots belong to one documented stopped-writer window.
- [ ] Payload bounds and VM/host capacity pass without budget changes.
- [ ] Built driver only; namespace/guests offline; no synthetic script invoked.
- [ ] Real library and paired Mealie state staged before app startup/DB restart.
- [ ] Four explicit tagged IDs rehearsed; actual restores and private assertions recorded.
- [ ] Failure recovery/protective IDs retained; no production destination forced.
- [ ] External OIDC/client/federation gates still explicitly outstanding.
- [ ] Encrypted immutable inputs retained; temporary plaintext handled per approval.

Preparation completion means documentation and driver expression validation
only. It does not authorize execution or certify production acceptance.
