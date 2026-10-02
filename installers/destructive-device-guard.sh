#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
  echo "usage: $0 EXPECTED_HOST MODEL SERIAL CAPACITY_BYTES TYPED_HOST" >&2
  exit 64
fi

expected_host=$1
expected_model=$2
expected_serial=$3
expected_bytes=$4
typed_host=$5
sys_block=${SYS_BLOCK:-/sys/class/block}
dev_root=${DEV_ROOT:-/dev}

if [ "$typed_host" != "$expected_host" ]; then
  echo "refusing: typed hostname does not exactly match $expected_host" >&2
  exit 2
fi
case "$expected_model:$expected_serial:$expected_bytes" in
  *UNRESOLVED* | *UNKNOWN* | *:0)
    echo "refusing: expected device identity is unresolved" >&2
    exit 3
    ;;
esac
case "$expected_bytes" in
  '' | *[!0-9]*) echo "refusing: expected capacity is invalid" >&2; exit 3 ;;
esac
[ "$expected_bytes" -gt 0 ] || { echo "refusing: expected capacity must be positive" >&2; exit 3; }

matches=()
for candidate in "$sys_block"/*; do
  [ -e "$candidate" ] || continue
  [ ! -e "$candidate/partition" ] || continue
  [ -r "$candidate/device/model" ] || continue
  [ -r "$candidate/device/serial" ] || continue
  [ -r "$candidate/size" ] || continue
  model=$(tr -d '\000' <"$candidate/device/model" | sed 's/[[:space:]]*$//')
  serial=$(tr -d '\000' <"$candidate/device/serial" | sed 's/[[:space:]]*$//')
  sectors=$(cat "$candidate/size")
  case "$sectors" in '' | *[!0-9]*) continue ;; esac
  bytes=$((sectors * 512))
  if [ "$model" = "$expected_model" ] && [ "$serial" = "$expected_serial" ] && [ "$bytes" -eq "$expected_bytes" ]; then
    matches+=("$dev_root/$(basename "$candidate")")
  fi
done

if [ "${#matches[@]}" -ne 1 ]; then
  echo "refusing: expected exactly one device matching model+serial+capacity; found ${#matches[@]}" >&2
  exit 4
fi
printf '%s\n' "${matches[0]}"
