{
  lib,
  modulesPath,
  pkgs,
  disko,
  targetHost,
  targetSystem,
  diskModel,
  diskSerial,
  diskCapacity,
  nicMembers,
  nicMac,
  address,
  gpuPciId,
  ...
}:
let
  guard = pkgs.writeShellScript "destructive-device-guard" (
    builtins.readFile ./destructive-device-guard.sh
  );
  diskConfig = pkgs.writeText "${targetHost}-disk-config.nix" ''
    import ${./framework-disk-layout.nix} { device = "/dev/installer-target"; }
  '';
  installer = pkgs.writeShellApplication {
    name = "install-${targetHost}";
    runtimeInputs = [
      disko.packages.${pkgs.stdenv.hostPlatform.system}.disko
      pkgs.coreutils
      pkgs.cryptsetup
      pkgs.gnugrep
      pkgs.openssh
      pkgs.util-linux
    ];
    text = ''
      set -euo pipefail
      if [ "$(id -u)" -ne 0 ]; then echo "must run as root" >&2; exit 1; fi
      read -r -p "Type ${targetHost} to authorize erasing its matched disk: " typed_host
      device=$(${guard} ${
        lib.escapeShellArgs [
          targetHost
          diskModel
          diskSerial
          (toString diskCapacity)
        ]
      } "$typed_host")

      for member in ${lib.escapeShellArgs nicMembers}; do
        [ -r "/sys/class/net/$member/address" ] || { echo "missing NIC member $member" >&2; exit 1; }
        [ "$(cat "/sys/class/net/$member/address")" = "${nicMac}" ] || { echo "MAC mismatch on $member" >&2; exit 1; }
      done
      gpu=$(printf '%s' '${gpuPciId}' | tr '[:upper:]' '[:lower:]')
      vendor=''${gpu%:*}; product=''${gpu#*:}
      grep -Fqx "0x$vendor" /sys/bus/pci/devices/0000:00:02.0/vendor || { echo "GPU vendor mismatch" >&2; exit 1; }
      grep -Fqx "0x$product" /sys/bus/pci/devices/0000:00:02.0/device || { echo "GPU device mismatch" >&2; exit 1; }

      work=/run/framework-installer
      key="$work/recovery.key"
      success=false
      cleanup() {
        status=$?
        set +e
        disko --mode umount ${diskConfig} >/dev/null 2>&1
        rm -f /dev/installer-target
        if [ -e "$key" ]; then shred -u "$key" 2>/dev/null || rm -f "$key"; fi
        rmdir "$work" 2>/dev/null || true
        if [ "$success" != true ]; then echo "INSTALLATION DID NOT COMPLETE; target was unmounted" >&2; fi
        exit "$status"
      }
      trap cleanup EXIT INT TERM HUP
      install -d -m 0700 "$work"
      umask 077
      head -c 48 /dev/urandom | base64 -w0 >"$key"
      ln -s "$device" /dev/installer-target

      disko --mode disko ${diskConfig}
      install -d -m 0755 /mnt/etc/ssh
      ssh-keygen -A -f /mnt
      nixos-install --no-root-passwd --system ${targetSystem}

      systemd-cryptenroll --unlock-key-file="$key" --tpm2-device=auto /dev/disk/by-partlabel/framework-root
      systemd-cryptenroll --unlock-key-file="$key" --tpm2-device=auto /dev/disk/by-partlabel/framework-data
      printf '\nOFFLINE RECOVERY KEY (record without photographing or logging):\n' >/dev/tty
      cat "$key" >/dev/tty
      printf '\nType RECOVERY KEY ESCROWED only after storing and independently reading it back: ' >/dev/tty
      IFS= read -r escrowed </dev/tty
      [ "$escrowed" = "RECOVERY KEY ESCROWED" ] || { echo "recovery-key escrow not confirmed" >&2; exit 1; }
      success=true
      echo "Installation complete; target unmounted. Reboot only after the acceptance checklist."
    '';
  };
in
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];
  image.fileName = lib.mkForce "${targetHost}-bootstrap.iso";
  environment.systemPackages = [ installer ];
  services.openssh.enable = true;
  networking.hostName = "${targetHost}-installer";
  systemd.network = {
    netdevs."10-bond0".netdevConfig = {
      Kind = "bond";
      Name = "bond0";
    };
    networks =
      lib.listToAttrs (
        lib.imap0 (index: member: {
          name = "10-member-${toString (index + 1)}";
          value = {
            matchConfig = {
              Name = member;
              MACAddress = nicMac;
            };
            networkConfig.Bond = "bond0";
          };
        }) nicMembers
      )
      // {
        "20-bond0" = {
          matchConfig.Name = "bond0";
          address = [ "${address}/24" ];
          routes = [ { Gateway = "10.15.4.1"; } ];
          networkConfig.DNS = [ "10.15.4.1" ];
        };
      };
  };
  systemd.services."serial-getty@ttyS0".enable = lib.mkDefault true;
  boot.initrd.systemd = {
    enable = true;
    tpm2.enable = true;
  };
}
