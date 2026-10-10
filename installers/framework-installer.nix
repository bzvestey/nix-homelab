{
  lib,
  pkgs,
  diskoPackage,
  targetHost,
  targetSystem,
  diskById,
  diskModel,
  diskSerial,
  diskSectors,
  nicMembers,
  nicPermanentMacs ? { },
  gpuPciId,
  commands ? { },
  roots ? { },
}:
let
  command = name: fallback: commands.${name} or fallback;
  devRoot = roots.dev or "/dev";
  sysRoot = roots.sys or "/sys";
  procRoot = roots.proc or "/proc";
  runRoot = roots.run or "/run";
  guard = pkgs.replaceVars ./destructive-device-guard.sh {
    bash = command "bash" "${pkgs.bash}/bin/bash";
    inherit devRoot;
    sysDevBlock = "${sysRoot}/dev/block";
    readlink = command "readlink" "${pkgs.coreutils}/bin/readlink";
    stat = command "stat" "${pkgs.coreutils}/bin/stat";
    tr = "${pkgs.coreutils}/bin/tr";
    lsblk = command "lsblk" "${pkgs.util-linux}/bin/lsblk";
    logGuard = command "logGuard" ":";
  };
  diskConfig = pkgs.writeText "${targetHost}-disk-config.nix" ''
    { device, ... }: import ${./framework-disk-layout.nix} { inherit device; }
  '';
  postDisko = command "postDisko" (
    pkgs.writeShellScript "framework-post-disko" ''
      install -d -m 0755 /mnt/etc/ssh
      ${pkgs.openssh}/bin/ssh-keygen -A -f /mnt
      ${pkgs.nixos-install-tools}/bin/nixos-install --no-root-passwd --system ${targetSystem}
    ''
  );
  secureBootState = command "secureBootState" (
    pkgs.writeShellScript "secure-boot-state" ''
      shopt -s nullglob
      vars=(${sysRoot}/firmware/efi/efivars/SecureBoot-*)
      [ "''${#vars[@]}" -eq 1 ] || { echo UNAVAILABLE; exit 0; }
      value=$(${pkgs.coreutils}/bin/od -An -tu1 -j4 -N1 "''${vars[0]}" | ${pkgs.coreutils}/bin/tr -d ' ')
      case "$value" in 1) echo ENABLED ;; 0) echo DISABLED ;; *) echo UNKNOWN ;; esac
    ''
  );
  core = pkgs.replaceVars ./framework-install.sh {
    bash = command "bash" "${pkgs.bash}/bin/bash";
    requireRoot = ''[ "$(${command "id" "${pkgs.coreutils}/bin/id"} -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }'';
    host = targetHost;
    inherit guard diskConfig postDisko;
    guardArgs = lib.escapeShellArgs [
      targetHost
      diskById
      diskModel
      diskSerial
      (toString diskSectors)
    ];
    workDir = "${runRoot}/framework-installer";
    shred = command "shred" "${pkgs.coreutils}/bin/shred";
    stat = command "stat" "${pkgs.coreutils}/bin/stat";
    readlink = command "readlink" "${pkgs.coreutils}/bin/readlink";
    awk = command "awk" "${pkgs.gawk}/bin/awk";
    procMountinfo = "${procRoot}/self/mountinfo";
    mount = command "mount" "${pkgs.util-linux}/bin/mount";
    umount = command "umount" "${pkgs.util-linux}/bin/umount";
    udevadm = command "udevadm" "${pkgs.systemd}/bin/udevadm";
    cryptenroll = command "cryptenroll" "${pkgs.systemd}/bin/systemd-cryptenroll";
    flock = command "flock" "${pkgs.util-linux}/bin/flock";
    lsblk = command "lsblk" "${pkgs.util-linux}/bin/lsblk";
    disko = command "disko" "${diskoPackage}/bin/disko";
    urandom = roots.urandom or "/dev/urandom";
    ttyOut = roots.ttyOut or "/dev/tty";
    ttyIn = roots.ttyIn or "/dev/tty";
    ttyPcrIn = roots.ttyPcrIn or "/dev/tty";
    sysDevBlock = "${sysRoot}/dev/block";
    canonicalDevRoot = devRoot;
    inherit secureBootState;
    pcrPolicy = "7";
  };
  inner = pkgs.writeShellScript "install-${targetHost}-inner" ''
    set -euo pipefail
    ${lib.concatMapStringsSep "\n" (member: ''
      member=${lib.escapeShellArg member}
      expected=${lib.escapeShellArg (nicPermanentMacs.${member} or "")}
      [ -n "$expected" ] && [ "$expected" != UNRESOLVED ] || { echo "unverified permanent MAC for $member" >&2; exit 1; }
      [ -r "${sysRoot}/class/net/$member/address" ] || { echo "missing NIC member $member" >&2; exit 1; }
      evidence=$(${command "ethtool" "${pkgs.ethtool}/bin/ethtool"} -P "$member") || { echo "permanent MAC unavailable for $member" >&2; exit 1; }
      [[ "$evidence" =~ ^Permanent\ address:\ ([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]] || { echo "invalid permanent MAC evidence for $member" >&2; exit 1; }
      permanent=''${evidence#Permanent address: }
      [ "''${permanent,,}" = "''${expected,,}" ] || { echo "permanent MAC mismatch on $member" >&2; exit 1; }
    '') nicMembers}
    gpu=$(printf '%s' '${gpuPciId}' | tr '[:upper:]' '[:lower:]')
    vendor=''${gpu%:*}; product=''${gpu#*:}
    grep -Fqx "0x$vendor" "${sysRoot}/bus/pci/devices/0000:00:02.0/vendor" || { echo "GPU vendor mismatch" >&2; exit 1; }
    grep -Fqx "0x$product" "${sysRoot}/bus/pci/devices/0000:00:02.0/device" || { echo "GPU device mismatch" >&2; exit 1; }
    exec ${command "bash" "${pkgs.bash}/bin/bash"} ${core} "$@"
  '';
in
pkgs.writeShellScriptBin "install-${targetHost}" ''
  set -euo pipefail
  exec ${command "unshare" "${pkgs.util-linux}/bin/unshare"} --mount --propagation private -- ${command "bash" "${pkgs.bash}/bin/bash"} ${inner} "$@"
''
