set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sys="$tmp/sys/class/block"
dev="$tmp/dev"
spy="$tmp/destructive.log"
mkdir -p "$sys" "$dev"

add_device() {
  local name=$1 model=$2 serial=$3 sectors=$4
  mkdir -p "$sys/$name/device"
  printf '%s\n' "$model" >"$sys/$name/device/model"
  printf '%s\n' "$serial" >"$sys/$name/device/serial"
  printf '%s\n' "$sectors" >"$sys/$name/size"
  : >"$dev/$name"
}

partition() { printf 'partition:%s\n' "$1" >>"$spy"; }
format() { printf 'format:%s\n' "$1" >>"$spy"; }
disko() { printf 'disko:%s\n' "$1" >>"$spy"; }
guard() { bash "$GUARD" "$@"; }

refuse() {
  local label=$1
  shift
  : >"$spy"
  if device=$(SYS_BLOCK="$sys" DEV_ROOT="$dev" guard "$@"); then
    partition "$device"
    format "$device"
    disko "$device"
    echo "$label unexpectedly accepted" >&2
    exit 1
  fi
  test ! -s "$spy" || { echo "$label ran destructive command" >&2; exit 1; }
}

# Zero candidates: an unrelated disk must not become a fallback.
add_device sda "Unrelated SATA" "OTHER" 1953525168
refuse zero framework-01 "Samsung SSD 970 EVO Plus 2TB" S59CNM0W713317D 2000398934016 framework-01

# Multiple exact candidates: asymmetric names prove uniqueness, not preferred-name selection.
add_device nvme0n1 "Samsung SSD 970 EVO Plus 2TB" S59CNM0W713317D 3907029168
add_device nvme7n4 "Samsung SSD 970 EVO Plus 2TB" S59CNM0W713317D 3907029168
refuse multiple framework-01 "Samsung SSD 970 EVO Plus 2TB" S59CNM0W713317D 2000398934016 framework-01

rm -rf "$sys/nvme7n4"
refuse wrong-model framework-01 "Samsung SSD 980 1TB" S59CNM0W713317D 2000398934016 framework-01
refuse wrong-serial framework-01 "Samsung SSD 970 EVO Plus 2TB" WRONG 2000398934016 framework-01
refuse wrong-capacity framework-01 "Samsung SSD 970 EVO Plus 2TB" S59CNM0W713317D 1000204886016 framework-01
refuse wrong-hostname framework-01 "Samsung SSD 970 EVO Plus 2TB" S59CNM0W713317D 2000398934016 framework-02

# Unresolved observability identity must refuse even when the operator typed the host.
refuse unresolved observability-pi UNRESOLVED UNRESOLVED 0 observability-pi

# Pi zero/multiple telemetry matches use the same guard and never reach mkfs/disko.
rm -rf "$sys"; mkdir -p "$sys"
add_device mmcblk9 "Boot Media" BOOT 500000000
refuse telemetry-zero observability-pi "Telemetry SSD" TELEMETRY-01 2000398934016 observability-pi
add_device sdb "Telemetry SSD" TELEMETRY-01 3907029168
add_device nvme8n2 "Telemetry SSD" TELEMETRY-01 3907029168
refuse telemetry-multiple observability-pi "Telemetry SSD" TELEMETRY-01 2000398934016 observability-pi

# A unique exact tuple is the only accepted state.
rm -rf "$sys/nvme8n2"
device=$(SYS_BLOCK="$sys" DEV_ROOT="$dev" guard observability-pi "Telemetry SSD" TELEMETRY-01 2000398934016 observability-pi)
test "$device" = "$dev/sdb"
test ! -s "$spy"
