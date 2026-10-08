#!/usr/bin/env bash
set -euo pipefail
helper=$(realpath "$(dirname "$0")/../scripts/package-framework.sh")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
for host in hl-node-02 hl-node-03 hl-node-04; do
  mkdir -p "store-$host/iso"
  printf 'fixture ISO\n' > "store-$host/iso/$host-bootstrap.iso"
  ln -s "$tmp/store-$host" "result-$host"
  GITHUB_SHA=fixture-revision bash "$helper" "$host"
  cmp "store-$host/iso/$host-bootstrap.iso" "artifact-$host/$host-bootstrap.iso"
  (cd "artifact-$host" && sha256sum --check "$host.sha256")
  grep -Fx 'git_commit=fixture-revision' "artifact-$host/$host.manifest"
  grep -Fx "nix_output=$tmp/store-$host" "artifact-$host/$host.manifest"
  grep -Fx "image_store_path=$tmp/store-$host/iso/$host-bootstrap.iso" "artifact-$host/$host.manifest"
  grep -Fx 'installation_ready=false' "artifact-$host/$host.manifest"
done
rm -rf artifact-hl-node-02
expect_failure() {
  if GITHUB_SHA=fixture-revision bash "$helper" hl-node-02; then
    echo 'Expected packaging failure' >&2
    exit 1
  fi
  test ! -e artifact-hl-node-02
}
rm store-hl-node-02/iso/hl-node-02-bootstrap.iso
expect_failure
printf 'wrong host\n' > store-hl-node-02/iso/hl-node-03-bootstrap.iso
expect_failure
printf 'fixture ISO\n' > store-hl-node-02/iso/hl-node-02-bootstrap.iso
mkdir store-hl-node-02/duplicate
cp store-hl-node-02/iso/hl-node-02-bootstrap.iso store-hl-node-02/duplicate/
expect_failure
rm result-hl-node-02
expect_failure
echo 'Framework packaging fixtures passed (3 hosts; missing, wrong-host, ambiguous, missing-link failures).'
