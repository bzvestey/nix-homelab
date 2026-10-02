set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export FAKE_STATE="$tmp/state"
mkdir -p "$FAKE_STATE"/{dev/disk/by-id,sys/dev/block,bin}
log="$FAKE_STATE/log"
: >"$log"

cat >"$FAKE_STATE/bin/tool" <<'EOF'
#!@bash@
set -euo pipefail
name=$(basename "$0")
state=${FAKE_STATE:?}
case "$name" in
  readlink) cat "$state/readlink" ;;
  stat)
    [ "$(cat "$state/type")" = block ] || exit 1
    cat "$state/major_minor"
    ;;
  udevadm)
    echo udevadm >>"$state/log"
    if [ -e "$state/swap-on-settle" ]; then printf '%s\n' '103:9' >"$state/major_minor"; fi
    ;;
  flock) echo flock >>"$state/log" ;;
  disko)
    [ "$2" = disko ] && printf 'disko:%s\n' "$*" >>"$state/log"
    ;;
  mkfs.ext4|systemd-cryptenroll|nixos-install|ssh-keygen)
    printf '%s:%s\n' "$name" "$*" >>"$state/log"
    ;;
  lsblk) echo lsblk >>"$state/log"; cat "$state/lsblk" ;;
  *) exec "@coreutils@/bin/$name" "$@" ;;
esac
EOF
sed -i "s|@coreutils@|$COREUTILS|g" "$FAKE_STATE/bin/tool"
sed -i "s|@bash@|$BASH|g" "$FAKE_STATE/bin/tool"
chmod +x "$FAKE_STATE/bin/tool"
for command in readlink stat udevadm flock disko mkfs.ext4 systemd-cryptenroll nixos-install ssh-keygen lsblk; do
  ln -s tool "$FAKE_STATE/bin/$command"
done

guard="$FAKE_STATE/guard"
sed \
  -e "s|@devRoot@|$FAKE_STATE/dev|g" \
  -e "s|@sysDevBlock@|$FAKE_STATE/sys/dev/block|g" \
  -e "s|@readlink@|$FAKE_STATE/bin/readlink|g" \
  -e "s|@stat@|$FAKE_STATE/bin/stat|g" \
  -e "1s|.*|#!$BASH|" \
  "$GUARD_TEMPLATE" >"$guard"
chmod +x "$guard"
printf '%s\n' 'RECOVERY KEY ESCROWED' >"$FAKE_STATE/escrow"
: >"$FAKE_STATE/tty"

make_framework() {
  local output=$1 host=$2 by_id=$3
  sed \
    -e 's|@requireRoot@|true|g' \
    -e "s|@host@|$host|g" \
    -e "s|@guard@|$guard|g" \
    -e "s|@guardArgs@|'$host' '$by_id' 'Samsung SSD 970 EVO Plus 2TB' 'S59CNM0W713317D' '3907029168'|g" \
    -e "s|@workDir@|$FAKE_STATE/work-$host|g" \
    -e "s|@disko@|$FAKE_STATE/bin/disko|g" \
    -e 's|@diskConfig@|/fake/disk-config.nix|g' \
    -e "s|@shred@|$COREUTILS/bin/rm|g" \
    -e "s|@urandom@|/dev/zero|g" \
    -e "s|@ttyOut@|$FAKE_STATE/tty|g" \
    -e "s|@ttyIn@|$FAKE_STATE/escrow|g" \
    -e "s|@udevadm@|$FAKE_STATE/bin/udevadm|g" \
    -e "s|@flock@|$FAKE_STATE/bin/flock|g" \
    -e 's|@postDisko@|true|g' \
    -e "s|@stat@|$FAKE_STATE/bin/stat|g" \
    -e "s|@lsblk@|$FAKE_STATE/bin/lsblk|g" \
    -e "s|@cryptenroll@|$FAKE_STATE/bin/systemd-cryptenroll|g" \
    -e 's|@pcrPolicy@|7|g' \
    -e "1s|.*|#!$BASH|" \
    "$FRAMEWORK_TEMPLATE" >"$output"
  chmod +x "$output"
}

FRAMEWORK_INSTALLER="$FAKE_STATE/framework"
FRAMEWORK_AUTHORIZED="$FAKE_STATE/framework-authorized"
make_framework "$FRAMEWORK_INSTALLER" framework-01 "$FAKE_STATE/dev/disk/by-id/nvme-Samsung"
make_framework "$FRAMEWORK_AUTHORIZED" framework-01 "$FAKE_STATE/dev/disk/by-id/nvme-Samsung"
FRAMEWORK_REFUSERS=""
for host in framework-01 framework-02 framework-03; do
  installer="$FAKE_STATE/install-$host"
  make_framework "$installer" "$host" UNRESOLVED
  FRAMEWORK_REFUSERS="$FRAMEWORK_REFUSERS $installer"
done
PI_INITIALIZER="$FAKE_STATE/pi-initializer"
cat >"$PI_INITIALIZER" <<EOF
#!$BASH
set -euo pipefail
read -r typed
token=\$("$guard" observability-pi UNRESOLVED UNRESOLVED UNRESOLVED 0 "\$typed")
"$FAKE_STATE/bin/mkfs.ext4" "\$token"
EOF
chmod +x "$PI_INITIALIZER"

set_identity() {
  printf '%s\n' "$FAKE_STATE/dev/nvme0n1" >"$FAKE_STATE/readlink"
  printf '%s\n' block >"$FAKE_STATE/type"
  printf '%s\n' '103:0' >"$FAKE_STATE/major_minor"
  mkdir -p "$FAKE_STATE/sys/dev/block/103:0/device"
  printf '%s\n' 'Samsung SSD 970 EVO Plus 2TB' >"$FAKE_STATE/sys/dev/block/103:0/device/model"
  printf '%s\n' S59CNM0W713317D >"$FAKE_STATE/sys/dev/block/103:0/device/serial"
  printf '%s\n' 3907029168 >"$FAKE_STATE/sys/dev/block/103:0/size"
  : >"$FAKE_STATE/dev/nvme0n1"
  : >"$FAKE_STATE/dev/disk/by-id/nvme-Samsung"
}

assert_no_destructive() {
  ! grep -Eq '^(disko|mkfs.ext4|systemd-cryptenroll):' "$log"
}

refuse_framework() {
  local label=$1
  : >"$log"
  if printf 'framework-01\nRECOVERY KEY ESCROWED\n' | "$FRAMEWORK_INSTALLER"; then
    echo "$label unexpectedly accepted" >&2
    exit 1
  fi
  assert_no_destructive || { echo "$label executed destructive action" >&2; exit 1; }
}

# No stable by-id has been physically observed: every shipped Framework entry point refuses.
for installer in $FRAMEWORK_REFUSERS; do
  : >"$log"
  if printf '%s\n' "$(basename "$installer" | sed 's/^install-//')" | "$installer"; then exit 1; fi
  assert_no_destructive
done

set_identity
rm "$FAKE_STATE/dev/disk/by-id/nvme-Samsung"
refuse_framework unresolved-by-id
set_identity
printf '%s\n' file >"$FAKE_STATE/type"
refuse_framework non-block-by-id
set_identity
printf '%s\n' 999999999999999999999999999999999999 >"$FAKE_STATE/sys/dev/block/103:0/size"
refuse_framework huge-sector-count
set_identity
printf '%s\n' 'Wrong model' >"$FAKE_STATE/sys/dev/block/103:0/device/model"
refuse_framework wrong-model
set_identity
printf '%s\n' 'WRONG-SERIAL' >"$FAKE_STATE/sys/dev/block/103:0/device/serial"
refuse_framework wrong-serial
set_identity
: >"$log"
if printf 'framework-02\n' | "$FRAMEWORK_INSTALLER"; then exit 1; fi
assert_no_destructive
set_identity
printf '%s\n' '103:1' >"$FAKE_STATE/major_minor"
refuse_framework major-minor-change

# Pi production entry point cannot bypass its unresolved identity and never formats.
: >"$log"
if printf 'observability-pi\nINITIALIZE TELEMETRY SSD\n' | "$PI_INITIALIZER"; then exit 1; fi
assert_no_destructive

# A udev identity swap between initial validation and the destruction boundary refuses.
set_identity
cp -r "$FAKE_STATE/sys/dev/block/103:0" "$FAKE_STATE/sys/dev/block/103:9"
touch "$FAKE_STATE/swap-on-settle"
: >"$log"
if printf 'framework-01\n' | "$FRAMEWORK_AUTHORIZED"; then exit 1; fi
assert_no_destructive
rm "$FAKE_STATE/swap-on-settle"

# Authorized harness proves production ordering and exact-parent partition selection.
set_identity
cat >"$FAKE_STATE/lsblk" <<EOF
$FAKE_STATE/dev/nvme0n1p1 103:1 $FAKE_STATE/dev/nvme0n1 framework-root
$FAKE_STATE/dev/nvme0n1p2 103:2 $FAKE_STATE/dev/nvme0n1 framework-data
$FAKE_STATE/dev/other1 8:1 $FAKE_STATE/dev/other framework-root
EOF
: >"$log"
printf 'framework-01\nRECOVERY KEY ESCROWED\n' | "$FRAMEWORK_AUTHORIZED"
expected='udevadm
flock
disko
lsblk
lsblk
systemd-cryptenroll
systemd-cryptenroll'
actual=$(grep -E '^(udevadm|flock|disko|lsblk|systemd-cryptenroll)' "$log" | cut -d: -f1)
test "$actual" = "$expected"
! grep -Fq "$FAKE_STATE/dev/other1" "$log"

# A child claiming the wrong parent refuses before TPM enrollment.
set_identity
cat >"$FAKE_STATE/lsblk" <<EOF
$FAKE_STATE/dev/nvme0n1p1 103:1 $FAKE_STATE/dev/other framework-root
$FAKE_STATE/dev/nvme0n1p2 103:2 $FAKE_STATE/dev/nvme0n1 framework-data
EOF
: >"$log"
if printf 'framework-01\nRECOVERY KEY ESCROWED\n' | "$FRAMEWORK_AUTHORIZED"; then exit 1; fi
! grep -q '^systemd-cryptenroll:' "$log"
