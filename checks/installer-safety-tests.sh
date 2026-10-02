set -euo pipefail
state=/build/fixture
rm -rf "$state"
mkdir -p "$state"/{dev/disk/by-id,sys/dev/block,sys/devices/nvme0n1/nvme0n1p1,sys/devices/nvme0n1/nvme0n1p2,sys/class/net,sys/bus/pci/devices/0000:00:02.0,run}
touch "$state/dev/nvme0n1" "$state/dev/nvme0n1p1" "$state/dev/nvme0n1p2" "$state/dev/disk/by-id/nvme-Samsung"
ln -s "$state/sys/devices/nvme0n1/nvme0n1p1" "$state/sys/dev/block/259:1"
ln -s "$state/sys/devices/nvme0n1/nvme0n1p2" "$state/sys/dev/block/259:2"
printf '259:0\n' >"$state/sys/devices/nvme0n1/dev"
touch "$state/sys/devices/nvme0n1/nvme0n1p1/partition" "$state/sys/devices/nvme0n1/nvme0n1p2/partition"
printf '103 0\n' >"$state/hex_major_minor" # realistic NVMe 0x103 == decimal 259
printf block >"$state/type"
: >"$state/log"; : >"$state/output"

setup_host() {
  host=$1
  rm -rf "$state/sys/class/net"; mkdir -p "$state/sys/class/net"
  case "$host" in
    framework-01) model='Samsung SSD 970 EVO Plus 2TB'; serial=S59CNM0W713317D; sectors=3907029168; members='enp0s13f0u1 enp0s13f0u2'; mac=9c:bf:0d:00:23:fe; gpu=9a49 ;;
    framework-02) model='Samsung SSD 980 1TB'; serial=S64ANS0RB36721W; sectors=1953525168; members='enp0s13f0u3 enp0s13f0u4'; mac=9c:bf:0d:00:0d:3c; gpu=4626 ;;
    framework-03) model='Samsung SSD 980 1TB'; serial=S64ANL0T801753P; sectors=1953525168; members='enp0s13f0u3 enp0s13f0u4'; mac=9c:bf:0d:00:20:37; gpu=9a49 ;;
  esac
  mkdir -p "$state/sys/dev/block/259:0/device"
  printf '%s\n' "$model" >"$state/sys/dev/block/259:0/device/model"
  printf '%s\n' "$serial" >"$state/sys/dev/block/259:0/device/serial"
  printf '%s\n' "$sectors" >"$state/sys/dev/block/259:0/size"
  for member in $members; do mkdir -p "$state/sys/class/net/$member"; printf '%s\n' "$mac" >"$state/sys/class/net/$member/address"; done
  printf '0x8086\n' >"$state/sys/bus/pci/devices/0000:00:02.0/vendor"
  printf '0x%s\n' "$gpu" >"$state/sys/bus/pci/devices/0000:00:02.0/device"
  printf 'RECOVERY KEY ESCROWED\n' >"$state/input"
  printf 'PCR7 DISABLED ACKNOWLEDGED\n' >"$state/pcr-input"
}

assert_no_destruction() { ! grep -Eq 'disko:.*--mode disko|systemd-cryptenroll:' "$state/log"; }
for spec in framework-01:$INSTALL_01 framework-02:$INSTALL_02 framework-03:$INSTALL_03; do
  host=${spec%%:*}; entry=${spec#*:}; setup_host "$host"; : >"$state/log"
  printf '%s\n' "$host" | "$entry"
  grep -Eq '^id:' "$state/log"
  test "$(grep -c '^guard-log:' "$state/log")" -ge 2
  grep -Eq 'disko:--argstr device /proc/[0-9]+/fd/[0-9]+ --mode disko' "$state/log"
  test "$(grep -c 'systemd-cryptenroll:.* /proc/[0-9]*/fd/' "$state/log")" -eq 2
done

setup_host framework-01; : >"$state/log"; export FIXTURE_UID=1000
if printf 'framework-01\n' | "$INSTALL_01"; then exit 1; fi
assert_no_destruction; unset FIXTURE_UID
setup_host framework-01; rm "$state/sys/class/net/enp0s13f0u1/address"; : >"$state/log"
if printf 'framework-01\n' | "$INSTALL_01"; then exit 1; fi
assert_no_destruction
setup_host framework-01; printf '0xffff\n' >"$state/sys/bus/pci/devices/0000:00:02.0/device"; : >"$state/log"
if printf 'framework-01\n' | "$INSTALL_01"; then exit 1; fi
assert_no_destruction

setup_host framework-01; touch "$state/child-swap"; : >"$state/log"
if printf 'framework-01\n' | "$INSTALL_01"; then exit 1; fi
! grep -q '^systemd-cryptenroll:' "$state/log"; rm "$state/child-swap"
setup_host framework-01; printf '8:0\n' >"$state/sys/devices/nvme0n1/dev"; : >"$state/log"
if printf 'framework-01\n' | "$INSTALL_01"; then exit 1; fi
! grep -q '^systemd-cryptenroll:' "$state/log"; printf '259:0\n' >"$state/sys/devices/nvme0n1/dev"
setup_host framework-01; touch "$state/unmount-fails"; : >"$state/log"
if printf 'framework-01\n' | "$INSTALL_01" >"$state/cleanup-out" 2>&1; then exit 1; fi
grep -q 'TARGET UNMOUNT FAILED' "$state/cleanup-out"
! grep -q 'target unmounted' "$state/cleanup-out"
rm "$state/unmount-fails"

# Production generator has no runtime test-hook surface.
! grep -R -E 'FAKE|TEST|BYPASS|FIXTURE|/build/fixture' "$PROD_01"
