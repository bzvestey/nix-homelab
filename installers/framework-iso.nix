{
  lib,
  modulesPath,
  pkgs,
  disko,
  targetHost,
  targetSystem,
  diskById,
  diskModel,
  diskSerial,
  diskSectors,
  nicMembers,
  nicMac,
  address,
  gpuPciId,
  ...
}:
let
  guard = pkgs.replaceVars ./destructive-device-guard.sh {
    bash = "${pkgs.bash}/bin/bash";
    devRoot = "/dev";
    sysDevBlock = "/sys/dev/block";
    readlink = "${pkgs.coreutils}/bin/readlink";
    stat = "${pkgs.coreutils}/bin/stat";
  };
  diskConfig = pkgs.writeText "${targetHost}-disk-config.nix" ''
    import ${./framework-disk-layout.nix} { device = ${builtins.toJSON diskById}; }
  '';
  postDisko = pkgs.writeShellScript "framework-post-disko" ''
    install -d -m 0755 /mnt/etc/ssh
    ${pkgs.openssh}/bin/ssh-keygen -A -f /mnt
    ${pkgs.nixos-install-tools}/bin/nixos-install --no-root-passwd --system ${targetSystem}
  '';
  installerScript = pkgs.replaceVars ./framework-install.sh {
    bash = "${pkgs.bash}/bin/bash";
    requireRoot = ''[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }'';
    host = targetHost;
    inherit guard diskConfig postDisko;
    guardArgs = lib.escapeShellArgs [
      targetHost
      diskById
      diskModel
      diskSerial
      (toString diskSectors)
    ];
    workDir = "/run/framework-installer";
    shred = "${pkgs.coreutils}/bin/shred";
    stat = "${pkgs.coreutils}/bin/stat";
    udevadm = "${pkgs.systemd}/bin/udevadm";
    cryptenroll = "${pkgs.systemd}/bin/systemd-cryptenroll";
    flock = "${pkgs.util-linux}/bin/flock";
    lsblk = "${pkgs.util-linux}/bin/lsblk";
    disko = "${disko.packages.${pkgs.stdenv.hostPlatform.system}.disko}/bin/disko";
    urandom = "/dev/urandom";
    ttyOut = "/dev/tty";
    ttyIn = "/dev/tty";
    pcrPolicy = "7";
  };
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
      for member in ${lib.escapeShellArgs nicMembers}; do
        [ -r "/sys/class/net/$member/address" ] || { echo "missing NIC member $member" >&2; exit 1; }
        [ "$(cat "/sys/class/net/$member/address")" = "${nicMac}" ] || { echo "MAC mismatch on $member" >&2; exit 1; }
      done
      gpu=$(printf '%s' '${gpuPciId}' | tr '[:upper:]' '[:lower:]')
      vendor=''${gpu%:*}; product=''${gpu#*:}
      grep -Fqx "0x$vendor" /sys/bus/pci/devices/0000:00:02.0/vendor || { echo "GPU vendor mismatch" >&2; exit 1; }
      grep -Fqx "0x$product" /sys/bus/pci/devices/0000:00:02.0/device || { echo "GPU device mismatch" >&2; exit 1; }
      exec ${installerScript}
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
