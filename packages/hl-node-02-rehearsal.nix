{
  writeShellApplication,
  coreutils,
  util-linux,
  gnugrep,
  iproute2,
  jq,
  bash,
  driver,
}:
writeShellApplication {
  name = "hl-node-02-rehearsal";
  runtimeInputs = [
    coreutils
    util-linux
    gnugrep
    iproute2
    jq
  ];
  text = ''
    refuse() { echo "rehearsal: $*" >&2; exit 1; }
    [[ $# == 1 ]] || refuse 'expected one absolute encrypted scratch directory'
    scratch=$1
    [[ "$scratch" == /* && -d "$scratch" ]] || refuse 'scratch must be an existing absolute directory'
    [[ $(realpath -e -- "$scratch") == "$scratch" ]] || refuse 'scratch must be canonical, without symlinks'
    [[ $(stat -c %u -- "$scratch") == "$(id -u)" ]] || refuse 'scratch must belong to the current user'
    mode=$(stat -c %a -- "$scratch")
    (( (8#$mode & 077) == 0 )) || refuse 'scratch must not grant group or other access'
    source=$(findmnt -n -T "$scratch" -o SOURCE)
    # Support only a single crypt -> partition/disk chain. Inverse trees with
    # RAID, LVM, branching or unknown layers cannot prove all writes encrypted.
    # TYPE-only JSON requires --tree to include ancestry in children arrays.
    ancestry=$(lsblk --inverse --tree --json -o TYPE -- "$source") || refuse 'scratch must use an identifiable block filesystem'
    printf '%s\n' "$ancestry" | jq -e '
      def chain:
        if .type == "disk" then ((.children // []) | length == 0)
        elif .type == "part" then (.children | length == 1) and (.children[0] | chain)
        else false end;
      (.blockdevices | length == 1) and
      (.blockdevices[0] | .type == "crypt" and
        (.children | length == 1) and (.children[0] | chain))
    ' >/dev/null || refuse 'scratch must have supported unambiguous encrypted ancestry'
    [[ -r /dev/kvm && -w /dev/kvm ]] || refuse 'read/write KVM access is required'
    # Leave room for QEMU's socket suffixes within Linux's 108-byte limit.
    (( ''${#scratch} <= 42 )) || refuse 'scratch path is too long; use a shorter encrypted path'
    umask 077
    rehearsal_root=$(mktemp -d "$scratch/.hlr.XXXXXX")
    trap 'rm -f "$rehearsal_root/.nixos-test-history" "$rehearsal_root/ipython/profile_default/ipython_config.py"; rmdir "$rehearsal_root"/ipython/profile_default "$rehearsal_root"/ipython "$rehearsal_root"/{tmp,runtime,output} "$rehearsal_root" 2>/dev/null || true' EXIT
    mkdir "$rehearsal_root"/{tmp,runtime,output}
    ln -s /dev/null "$rehearsal_root/.nixos-test-history"
    mkdir -p "$rehearsal_root/ipython/profile_default"
    printf '%s\n' 'c.HistoryManager.hist_file = ":memory:"' 'c.HistoryManager.enabled = False' >"$rehearsal_root/ipython/profile_default/ipython_config.py"
    [[ $(findmnt -n -T "$rehearsal_root" -o SOURCE) == "$source" ]] || refuse 'runtime filesystem changed'
    export TMPDIR="$rehearsal_root/tmp" XDG_RUNTIME_DIR="$rehearsal_root/runtime"
    export HISTFILE=/dev/null PYTHON_HISTORY=/dev/null
    export IPYTHONDIR="$rehearsal_root/ipython"
    export secure="$scratch" rehearsal_root
    cd "$rehearsal_root"
    echo "Rehearsal runtime retained at $rehearsal_root; verify guest isolation before transferring data."
    # This namespace has no uplink. The runbook additionally disables each
    # guest's NAT-facing interface before any private data enters the VMs.
    # Expansion belongs to the shell inside the isolated namespace.
    # shellcheck disable=SC2016
    unshare --user --map-root-user --net -- ${bash}/bin/bash -eu -c '
      ip link set lo up
      test -z "$(ip -4 route show default)"
      test -z "$(ip -6 route show default)"
      ip -j link | jq -e "all(.[]; .ifname == \"lo\")" >/dev/null
      exec "$@"
    ' sh ${driver}/bin/nixos-test-driver --interactive -o "$rehearsal_root/output"
  '';
}
