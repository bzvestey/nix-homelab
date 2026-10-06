#!@bash@
set -euo pipefail
@logGuard@

if [ "$#" -ne 6 ]; then
  echo "usage: $0 EXPECTED_HOST EXPECTED_BY_ID MODEL SERIAL SECTORS TYPED_HOST" >&2
  exit 64
fi

expected_host=$1
stable_id=$2
expected_model=$3
expected_serial=$4
expected_sectors=$5
typed_host=$6

refuse() { echo "refusing: $*" >&2; exit 1; }
[ "$typed_host" = "$expected_host" ] || refuse "typed hostname does not exactly match $expected_host"
case "$stable_id:$expected_model:$expected_serial:$expected_sectors" in
  *UNRESOLVED* | *UNKNOWN*) refuse "expected device identity is unresolved" ;;
esac
case "$stable_id" in @devRoot@/disk/by-id/*) ;; *) refuse "expected identity is not a stable by-id path" ;; esac
case "$expected_sectors" in '' | *[!0-9]*) refuse "expected sector count is invalid" ;; esac
[ "$expected_sectors" != 0 ] || refuse "expected sector count is zero"
[ -e "$stable_id" ] || refuse "expected by-id does not resolve"

canonical=$(@readlink@ -f -- "$stable_id") || refuse "cannot canonicalize expected by-id"
[ -n "$canonical" ] || refuse "canonical device path is empty"
read -r major_hex minor_hex < <(@stat@ -Lc '%t %T' -- "$canonical") || refuse "resolved target is not a block device"
case "$major_hex:$minor_hex" in *[!0-9a-fA-F:]* | :*) refuse "resolved target has invalid device numbers" ;; esac
major_minor="$((16#$major_hex)):$((16#$minor_hex))"
sys_device=@sysDevBlock@/$major_minor
[ -e "$sys_device" ] || refuse "resolved block device has no sysfs identity"
[ ! -e "$sys_device/partition" ] || refuse "resolved target is not a whole block device"

read_fact() { tr -d '\000' <"$1" | sed 's/[[:space:]]*$//'; }
[ -r "$sys_device/size" ] || refuse "device facts are incomplete"
model=$([ -r "$sys_device/device/model" ] && read_fact "$sys_device/device/model" || :)
serial=$([ -r "$sys_device/device/serial" ] && read_fact "$sys_device/device/serial" || :)
if [ -z "$model" ] || [ -z "$serial" ]; then
  model=$(@lsblk@ -dnro MODEL -- "$canonical" | sed 's/[[:space:]]*$//') || refuse "device facts are incomplete"
  serial=$(@lsblk@ -dnro SERIAL -- "$canonical" | sed 's/[[:space:]]*$//') || refuse "device facts are incomplete"
fi
sectors=$(read_fact "$sys_device/size")
[ -n "$model" ] && [ -n "$serial" ] || refuse "device facts are incomplete"
case "$sectors" in '' | *[!0-9]*) refuse "observed sector count is invalid" ;; esac
[ "$model" = "$expected_model" ] || refuse "model mismatch"
[ "$serial" = "$expected_serial" ] || refuse "serial mismatch"
[ "$sectors" = "$expected_sectors" ] || refuse "sector-count mismatch"

printf '%s|%s|%s|%s|%s|%s\n' "$stable_id" "$canonical" "$major_minor" "$model" "$serial" "$sectors"
