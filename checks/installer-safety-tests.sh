set -euo pipefail
state=/build/fixture
rm -rf "$state"
mkdir -p "$state"/{dev/disk/by-id,proc/1/ns,proc/self/ns,sys/dev/block,sys/devices/nvme0n1/nvme0n1p1,sys/devices/nvme0n1/nvme0n1p2,sys/class/net,sys/bus/pci/devices/0000:00:02.0,run}
touch "$state/dev/nvme0n1" "$state/dev/nvme0n1p1" "$state/dev/nvme0n1p2" "$state/dev/sda" "$state/dev/disk/by-id/nvme-Samsung"
ln -s "$state/sys/devices/nvme0n1/nvme0n1p1" "$state/sys/dev/block/259:1"
ln -s "$state/sys/devices/nvme0n1/nvme0n1p2" "$state/sys/dev/block/259:2"
printf '259:0\n' >"$state/sys/devices/nvme0n1/dev"
touch "$state/sys/devices/nvme0n1/nvme0n1p1/partition" "$state/sys/devices/nvme0n1/nvme0n1p2/partition"
printf '103 0\n' >"$state/hex_major_minor" # realistic NVMe 0x103 == decimal 259
printf block >"$state/type"
: >"$state/log"; : >"$state/output"
printf 'mnt:[1]\n' >"$state/proc/1/ns/mnt"
printf 'mnt:[2]\n' >"$state/proc/self/ns/mnt"

setup_host() {
  host=$1
  # Model an already-unshared namespace which still has shared propagation.
  ! cmp -s "$state/proc/1/ns/mnt" "$state/proc/self/ns/mnt"
  printf '24 1 0:20 / / rw,relatime shared:1 - ext4 /dev/root rw\n25 24 0:5 / /dev rw,nosuid shared:1 - devtmpfs devtmpfs rw\n' >"$state/proc/self/mountinfo"
  rm -rf "$state/sys/class/net"; mkdir -p "$state/sys/class/net"
  case "$host" in
    hl-node-02) model='Samsung SSD 970 EVO Plus 2TB'; serial=S59CNM0W713317D; sectors=3907029168; members='lan0 lan1'; mac=9c:bf:0d:00:23:fe; gpu=9a49 ;;
    hl-node-03) model='Samsung SSD 980 1TB'; serial=S64ANS0RB36721W; sectors=1953525168; members='enp0s13f0u3 enp0s13f0u4'; mac=02:00:00:00:03:01; gpu=4626 ;;
    hl-node-04) model='Samsung SSD 980 1TB'; serial=S64ANL0T801753P; sectors=1953525168; members='enp0s13f0u3 enp0s13f0u4'; mac=02:00:00:00:04:01; gpu=9a49 ;;
  esac
  mkdir -p "$state/sys/dev/block/259:0/device"
  printf '%s\n' "$model" >"$state/sys/dev/block/259:0/device/model"
  printf '%s\n' "$serial" >"$state/sys/dev/block/259:0/device/serial"
  printf '%s\n' "$sectors" >"$state/sys/dev/block/259:0/size"
  for member in $members; do mkdir -p "$state/sys/class/net/$member"; printf '%s\n' "$mac" >"$state/sys/class/net/$member/address"; done
  case "$host" in
    hl-node-02) permanent1=9c:bf:0d:00:23:fe; permanent2=9c:bf:0d:00:25:5d ;;
    hl-node-03) permanent1=02:00:00:00:03:01; permanent2=02:00:00:00:03:02 ;;
    hl-node-04) permanent1=02:00:00:00:04:01; permanent2=02:00:00:00:04:02 ;;
  esac
  read -r member1 member2 <<<"$members"
  printf '%s\n' "$permanent1" >"$state/sys/class/net/$member1/permanent-address"
  printf '%s\n' "$permanent2" >"$state/sys/class/net/$member2/permanent-address"
  : >"$state/output"
  printf '0x8086\n' >"$state/sys/bus/pci/devices/0000:00:02.0/vendor"
  printf '0x%s\n' "$gpu" >"$state/sys/bus/pci/devices/0000:00:02.0/device"
  printf 'RECOVERY KEY ESCROWED\n' >"$state/input"
  printf 'PCR7 DISABLED ACKNOWLEDGED\n' >"$state/pcr-input"
}

assert_no_destruction() { ! grep -Eq 'disko:|systemd-cryptenroll:' "$state/log"; }
# Permanent identities must work both before and after bonding rewrites addresses.
setup_host hl-node-02; : >"$state/log"
printf '9c:bf:0d:00:25:5d\n' >"$state/sys/class/net/lan1/address"
printf 'hl-node-02\n' | "$INSTALL_01" >"$state/acceptance" 2>&1
grep -q 'Installation complete' "$state/acceptance"

for spec in hl-node-02:$INSTALL_01 hl-node-03:$INSTALL_02 hl-node-04:$INSTALL_03; do
  host=${spec%%:*}; entry=${spec#*:}; setup_host "$host"; : >"$state/log"
  printf '%s\n' "$host" | "$entry" >"$state/acceptance" 2>&1
  grep -q 'Installation complete' "$state/acceptance"
  grep -Eq '^id:' "$state/log"
  grep -Eq '^unshare:--mount --propagation private -- ' "$state/log"
  test "$(grep -c '^guard-log:' "$state/log")" -ge 2
  grep -Fq "mount:--bind -- /proc/" "$state/log"
  grep -Fq "disko:--argstr device $state/dev/nvme0n1 --mode disko" "$state/log"
  bind_line=$(grep -n '^mount:--bind' "$state/log" | cut -d: -f1)
  bound_stat_line=$(grep -n "^stat:-Lc %t %T -- $state/dev/nvme0n1" "$state/log" | tail -1 | cut -d: -f1)
  disko_line=$(grep -n 'disko:.*--mode disko' "$state/log" | cut -d: -f1)
  test "$bind_line" -lt "$bound_stat_line" && test "$bound_stat_line" -lt "$disko_line"
  test "$(grep -c 'systemd-cryptenroll:.* /proc/[0-9]*/fd/' "$state/log")" -eq 2
done

# Losing permanent evidence or verification must refuse before destructive work,
# even when the bond's current address still matches the old shared identity.
for fault in wrong missing unavailable empty malformed; do
  setup_host hl-node-02; : >"$state/log"
  case "$fault" in
    wrong) printf '02:00:00:00:00:ff\n' >"$state/sys/class/net/lan1/permanent-address" ;;
    missing) rm "$state/sys/class/net/lan1/permanent-address" ;;
    unavailable) touch "$state/ethtool-fails" ;;
    empty) : >"$state/sys/class/net/lan1/permanent-address" ;;
    malformed) printf 'UNRESOLVED\n' >"$state/sys/class/net/lan1/permanent-address" ;;
  esac
  if printf 'hl-node-02\n' | "$INSTALL_01" >"$state/refusal" 2>&1; then exit 1; fi
  test -s "$state/refusal"
  assert_no_destruction
  rm -f "$state/ethtool-fails"
done
for entry in "$INSTALL_UNVERIFIED" "$INSTALL_MISSING" "$INSTALL_UNRESOLVED"; do
  setup_host hl-node-02; : >"$state/log"
  if printf 'hl-node-02\n' | "$entry" >"$state/refusal" 2>&1; then exit 1; fi
  test -s "$state/refusal"
  assert_no_destruction
done

setup_host hl-node-02; touch "$state/unsupported-canonical"; : >"$state/log"
if printf 'hl-node-02\n' | "$INSTALL_01"; then exit 1; fi
assert_no_destruction; ! grep -q '^mount:' "$state/log"; rm "$state/unsupported-canonical"
setup_host hl-node-02; touch "$state/bind-fails"; : >"$state/log"
if printf 'hl-node-02\n' | "$INSTALL_01"; then exit 1; fi
assert_no_destruction; rm "$state/bind-fails"
setup_host hl-node-02; touch "$state/bound-mismatch"; : >"$state/log"
if printf 'hl-node-02\n' | "$INSTALL_01"; then exit 1; fi
assert_no_destruction; grep -q '^umount:' "$state/log"; rm "$state/bound-mismatch"
setup_host hl-node-02; touch "$state/propagation-fails"; : >"$state/log"
if printf 'hl-node-02\n' | "$INSTALL_01"; then exit 1; fi
grep -Eq '^unshare:--mount --propagation private -- ' "$state/log"
assert_no_destruction; ! grep -q '^mount:' "$state/log"; rm "$state/propagation-fails"

setup_host hl-node-02; : >"$state/log"; export FIXTURE_UID=1000
if printf 'hl-node-02\n' | "$INSTALL_01"; then exit 1; fi
assert_no_destruction; unset FIXTURE_UID
setup_host hl-node-02; rm "$state/sys/class/net/lan0/address"; : >"$state/log"
if printf 'hl-node-02\n' | "$INSTALL_01"; then exit 1; fi
assert_no_destruction
setup_host hl-node-02; printf '0xffff\n' >"$state/sys/bus/pci/devices/0000:00:02.0/device"; : >"$state/log"
if printf 'hl-node-02\n' | "$INSTALL_01"; then exit 1; fi
assert_no_destruction

setup_host hl-node-02; touch "$state/child-swap"; : >"$state/log"
if printf 'hl-node-02\n' | "$INSTALL_01"; then exit 1; fi
! grep -q '^systemd-cryptenroll:' "$state/log"; rm "$state/child-swap"
setup_host hl-node-02; printf '8:0\n' >"$state/sys/devices/nvme0n1/dev"; : >"$state/log"
if printf 'hl-node-02\n' | "$INSTALL_01"; then exit 1; fi
! grep -q '^systemd-cryptenroll:' "$state/log"; printf '259:0\n' >"$state/sys/devices/nvme0n1/dev"
setup_host hl-node-02; touch "$state/unmount-fails"; : >"$state/log"
if printf 'hl-node-02\n' | "$INSTALL_01" >"$state/cleanup-out" 2>&1; then exit 1; fi
grep -q 'TARGET UNMOUNT FAILED' "$state/cleanup-out"
! grep -q 'target unmounted' "$state/cleanup-out"
rm "$state/unmount-fails"

# Production generator has no runtime test-hook surface.
! grep -R -E 'FAKE|TEST|BYPASS|FIXTURE|/build/fixture' "$PROD_01"
