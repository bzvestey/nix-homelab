#!/usr/bin/env bash
set -euo pipefail
host=${1:?Expected Framework host}
case "$host" in
  hl-node-02|hl-node-03|hl-node-04) ;;
  *) echo "Unsupported Framework host: $host" >&2; exit 1 ;;
esac
: "${GITHUB_SHA:?Expected source revision}"
link="result-$host"
test -L "$link"
output=$(readlink -e "$link")
test -d "$output"
mapfile -d '' -t images < <(find "$output" -type f -name '*.iso' -print0)
if (( ${#images[@]} != 1 )) || [[ $(basename "${images[0]}") != "$host-bootstrap.iso" ]]; then
  echo "Expected exactly one ISO named $host-bootstrap.iso in $output" >&2
  exit 1
fi
artifact="artifact-$host"
mkdir "$artifact"
cp -- "${images[0]}" "$artifact/"
(cd "$artifact" && sha256sum "$host-bootstrap.iso" > "$host.sha256")
{
  printf 'git_commit=%s\n' "$GITHUB_SHA"
  printf 'nix_output=%s\n' "$output"
  printf 'image_store_path=%s\n' "${images[0]}"
  printf 'installation_ready=false\n'
  printf 'required_gates=physical disk facts; source evacuation; secret enrollment; published signed bootstrap policy\n'
} > "$artifact/$host.manifest"
