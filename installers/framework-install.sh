#!@bash@
set -euo pipefail

refuse() { echo "refusing: $*" >&2; exit 1; }
@requireRoot@

initial_namespace=$(@readlink@ /proc/1/ns/mnt) || refuse "cannot identify host mount namespace"
current_namespace=$(@readlink@ /proc/self/ns/mnt) || refuse "cannot identify installer mount namespace"
if [ "$current_namespace" = "$initial_namespace" ]; then
  exec @unshare@ --mount --propagation private -- @bash@ "$0" "$@"
fi
[ "$current_namespace" != "$initial_namespace" ] || refuse "installer requires a private mount namespace"

read -r -p "Type @host@ to authorize erasing its matched disk: " typed_host
token=$(@bash@ @guard@ @guardArgs@ "$typed_host")
IFS='|' read -r stable_id canonical parent_major_minor model serial sectors <<<"$token"
[[ "$canonical" =~ ^@canonicalDevRoot@/nvme[0-9]+n[1-9][0-9]*$ ]] || refuse "unsupported canonical device path"

work=@workDir@
key="$work/recovery.key"
success=false
cleanup() {
  status=$?
  trap - EXIT
  set +e
  unmount_status=0
  if [ -n "${bound_device:-}" ]; then
    @disko@ --argstr device "$bound_device" --mode umount @diskConfig@ >/dev/null 2>&1 || unmount_status=$?
  fi
  bind_unmount_status=0
  if [ "${device_bound:-false}" = true ]; then
    @umount@ -- "$bound_device" >/dev/null 2>&1 || bind_unmount_status=$?
  fi
  if [ -e "$key" ]; then @shred@ -u "$key" 2>/dev/null || rm -f "$key"; fi
  rmdir "$work" 2>/dev/null || true
  if [ "$unmount_status" -ne 0 ]; then
    echo "TARGET UNMOUNT FAILED (status $unmount_status); do not reboot or remove media; manually inspect /mnt and run Disko umount" >&2
    [ "$status" -ne 0 ] || status=$unmount_status
  elif [ "$bind_unmount_status" -ne 0 ]; then
    echo "DEVICE BIND UNMOUNT FAILED (status $bind_unmount_status); installer namespace cleanup is incomplete" >&2
    [ "$status" -ne 0 ] || status=$bind_unmount_status
  elif [ "$success" != true ]; then
    echo "INSTALLATION DID NOT COMPLETE; Disko reports target unmounted" >&2
  else
    echo "Installation complete; target unmounted. Reboot only after the acceptance checklist."
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

install -d -m 0700 "$work"
umask 077
head -c 48 @urandom@ | base64 -w0 >"$key"
printf '\nOFFLINE RECOVERY KEY (copy to approved offline escrow now):\n' >@ttyOut@
cat "$key" >@ttyOut@
printf '\nType RECOVERY KEY ESCROWED only after independently reading it back: ' >@ttyOut@
IFS= read -r escrowed <@ttyIn@
[ "$escrowed" = "RECOVERY KEY ESCROWED" ] || refuse "recovery-key escrow not confirmed"

@udevadm@ settle
exec {device_fd}<"$canonical"
@flock@ -x "$device_fd"
device_fd_path="/proc/$$/fd/$device_fd"
boundary_token=$(@bash@ @guard@ @guardArgs@ "$typed_host")
[ "$boundary_token" = "$token" ] || refuse "device identity changed at destruction boundary"
read -r held_major_hex held_minor_hex < <(@stat@ -Lc '%t %T' -- "$device_fd_path") || refuse "held device is no longer a block device"
held_major_minor="$((16#$held_major_hex)):$((16#$held_minor_hex))"
[ "$held_major_minor" = "$parent_major_minor" ] || refuse "held device identity changed"
bound_device="$canonical"
@mount@ --bind -- "$device_fd_path" "$bound_device" || refuse "cannot bind verified device node"
device_bound=true
read -r bound_major_hex bound_minor_hex < <(@stat@ -Lc '%t %T' -- "$bound_device") || refuse "bound device is not a block device"
bound_major_minor="$((16#$bound_major_hex)):$((16#$bound_minor_hex))"
[ "$bound_major_minor" = "$parent_major_minor" ] || refuse "bound device identity changed"

secure_boot=$(@secureBootState@)
echo "EFI SecureBoot state is $secure_boot. PCR 7 binds the current policy state; this installer does not establish Secure Boot." >&2
printf 'Type PCR7 %s ACKNOWLEDGED to continue: ' "$secure_boot" >@ttyOut@
IFS= read -r pcr_ack <@ttyPcrIn@
[ "$pcr_ack" = "PCR7 $secure_boot ACKNOWLEDGED" ] || refuse "PCR 7 policy not acknowledged"

@disko@ --argstr device "$bound_device" --mode disko @diskConfig@
@postDisko@

open_partition() {
  label=$1
  matches=()
  while read -r path child_major_minor partlabel; do
    [ "$partlabel" = "$label" ] || continue
    matches+=("$path|$child_major_minor")
  done < <(@lsblk@ -nrpo PATH,MAJ:MIN,PARTLABEL "$device_fd_path")
  [ "${#matches[@]}" -eq 1 ] || refuse "expected exactly one $label partition on guarded parent"
  IFS='|' read -r path expected_child_major_minor <<<"${matches[0]}"
  exec {child_fd}<"$path" || refuse "cannot open $label partition"
  child_fd_path="/proc/$$/fd/$child_fd"
  read -r child_major_hex child_minor_hex < <(@stat@ -Lc '%t %T' -- "$child_fd_path") || refuse "$label is not a block device"
  child_major_minor="$((16#$child_major_hex)):$((16#$child_minor_hex))"
  [ "$child_major_minor" = "$expected_child_major_minor" ] || refuse "$label identity changed while opening"
  child_sys=$(@readlink@ -f -- "@sysDevBlock@/$child_major_minor") || refuse "$label has no sysfs identity"
  [ -r "$child_sys/partition" ] || refuse "$label is not a partition"
  observed_parent=$(cat "$(dirname "$child_sys")/dev") || refuse "$label parent identity unavailable"
  [ "$observed_parent" = "$parent_major_minor" ] || refuse "$label is not a child of guarded device"
  printf -v "$2" '%s' "$child_fd_path"
}
open_partition framework-root root_partition
open_partition framework-data data_partition
@cryptenroll@ --unlock-key-file="$key" --tpm2-device=auto --tpm2-pcrs=@pcrPolicy@ "$root_partition"
@cryptenroll@ --unlock-key-file="$key" --tpm2-device=auto --tpm2-pcrs=@pcrPolicy@ "$data_partition"
success=true
