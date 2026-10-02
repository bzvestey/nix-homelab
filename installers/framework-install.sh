#!@bash@
set -euo pipefail

refuse() { echo "refusing: $*" >&2; exit 1; }
@requireRoot@
read -r -p "Type @host@ to authorize erasing its matched disk: " typed_host
token=$(@guard@ @guardArgs@ "$typed_host")
IFS='|' read -r stable_id canonical parent_major_minor model serial sectors <<<"$token"

work=@workDir@
key="$work/recovery.key"
success=false
cleanup() {
  status=$?
  trap - EXIT
  set +e
  @disko@ --mode umount @diskConfig@ >/dev/null 2>&1
  if [ -e "$key" ]; then @shred@ -u "$key" 2>/dev/null || rm -f "$key"; fi
  rmdir "$work" 2>/dev/null || true
  if [ "$success" != true ]; then echo "INSTALLATION DID NOT COMPLETE; target was unmounted" >&2; fi
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
boundary_token=$(@guard@ @guardArgs@ "$typed_host")
[ "$boundary_token" = "$token" ] || refuse "device identity changed at destruction boundary"

@disko@ --mode disko @diskConfig@
@postDisko@

find_partition() {
  label=$1
  matches=()
  while read -r path child_major_minor parent_path partlabel; do
    [ "$partlabel" = "$label" ] || continue
    observed_parent=$(@stat@ -Lc '%t:%T' -- "$parent_path") || refuse "partition parent is not a block device"
    [ "$parent_path" = "$canonical" ] && [ "$observed_parent" = "$parent_major_minor" ] || continue
    matches+=("$path")
  done < <(@lsblk@ -nrpo PATH,MAJ:MIN,PKNAME,PARTLABEL)
  [ "${#matches[@]}" -eq 1 ] || refuse "expected exactly one $label partition on guarded parent"
  printf '%s\n' "${matches[0]}"
}
root_partition=$(find_partition framework-root)
data_partition=$(find_partition framework-data)
@cryptenroll@ --unlock-key-file="$key" --tpm2-device=auto --tpm2-pcrs=@pcrPolicy@ "$root_partition"
@cryptenroll@ --unlock-key-file="$key" --tpm2-device=auto --tpm2-pcrs=@pcrPolicy@ "$data_partition"
success=true
echo "Installation complete; target unmounted. Reboot only after the acceptance checklist."
