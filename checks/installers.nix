{ pkgs, disko }:
let
  canonicalDevice = "/dev/nvme0n1";
  actualDiskConfig = import ../installers/framework-disk-layout.nix { device = canonicalDevice; };
  rootDevice = disko.lib.deviceNumbering actualDiskConfig.disko.devices.disk.system.device 2;
  dataDevice = disko.lib.deviceNumbering actualDiskConfig.disko.devices.disk.system.device 3;
  evaluatedDiskConfig =
    assert rootDevice == "/dev/nvme0n1p2";
    assert dataDevice == "/dev/nvme0n1p3";
    pkgs.writeText "evaluated-framework-disk-config" (builtins.toJSON actualDiskConfig);
  fakeTool = pkgs.writeShellScript "installer-fixture-tool" ''
        set -euo pipefail
        state=/build/fixture
        name=$(basename "$0")
    name=''${name#*-fixture-}
        echo "$name:$*" >>"$state/log"
        case "$name" in
          id) echo "''${FIXTURE_UID:-0}" ;;
          guard-log) ;;
          readlink)
            case "$*" in
              /proc/1/ns/mnt) echo 'mnt:[1]' ;;
              /proc/self/ns/mnt) if [ "''${FIXTURE_PRIVATE_NS:-0}" = 1 ] && [ ! -e "$state/no-namespace" ]; then echo 'mnt:[2]'; else echo 'mnt:[1]'; fi ;;
              *sys/dev/block/259:1*) echo "$state/sys/devices/nvme0n1/nvme0n1p1" ;;
              *sys/dev/block/259:2*) echo "$state/sys/devices/nvme0n1/nvme0n1p2" ;;
              *) [ -e "$state/unsupported-canonical" ] && echo "$state/dev/sda" || echo "$state/dev/nvme0n1" ;;
            esac
            ;;
          stat)
            [ "$(cat "$state/type")" = block ] || exit 1
            case "''${*: -1}" in
              *p1|*/fd/11) [ -e "$state/child-swap" ] && echo '103 9' || echo '103 1' ;;
              *p2|*/fd/12) echo '103 2' ;;
              *) [ -e "$state/bound" ] && [ -e "$state/bound-mismatch" ] && echo '8 0' || cat "$state/hex_major_minor" ;;
            esac
            ;;
          unshare)
            if [ -e "$state/no-namespace" ] && [ "''${FIXTURE_PRIVATE_NS:-0}" = 1 ]; then exit 5; fi
            shift 4
            FIXTURE_PRIVATE_NS=1 exec "$@"
            ;;
          mount)
            [ ! -e "$state/bind-fails" ] || exit 6
            touch "$state/bound"
            ;;
          umount) rm -f "$state/bound" ;;
          udevadm|flock|post-disko) ;;
          secure-boot-state) echo DISABLED ;;
          disko)
            [ -e "$state/unmount-fails" ] && [[ "$*" == *'--mode umount'* ]] && exit 7
            true
            ;;
          lsblk)
            cat <<EOF
    $state/dev/nvme0n1p1 259:1 framework-root
    $state/dev/nvme0n1p2 259:2 framework-data
    EOF
            ;;
          systemd-cryptenroll) ;;
          *) exec ${pkgs.coreutils}/bin/$name "$@" ;;
        esac
  '';
  tool = name: pkgs.runCommand "fixture-${name}" { } ''ln -s ${fakeTool} "$out"'';
  commands = {
    bash = "${pkgs.bash}/bin/bash";
    id = tool "id";
    logGuard = tool "guard-log";
    readlink = tool "readlink";
    stat = tool "stat";
    udevadm = tool "udevadm";
    unshare = tool "unshare";
    mount = tool "mount";
    umount = tool "umount";
    flock = tool "flock";
    disko = tool "disko";
    lsblk = tool "lsblk";
    cryptenroll = tool "systemd-cryptenroll";
    postDisko = tool "post-disko";
    secureBootState = tool "secure-boot-state";
    shred = "${pkgs.coreutils}/bin/rm";
  };
  roots = {
    dev = "/build/fixture/dev";
    sys = "/build/fixture/sys";
    run = "/build/fixture/run";
    urandom = "/dev/zero";
    ttyIn = "/build/fixture/input";
    ttyPcrIn = "/build/fixture/pcr-input";
    ttyOut = "/build/fixture/output";
  };
  facts = {
    framework-01 = {
      model = "Samsung SSD 970 EVO Plus 2TB";
      serial = "S59CNM0W713317D";
      sectors = 3907029168;
      members = [
        "enp0s13f0u1"
        "enp0s13f0u2"
      ];
      mac = "9c:bf:0d:00:23:fe";
      gpu = "8086:9a49";
    };
    framework-02 = {
      model = "Samsung SSD 980 1TB";
      serial = "S64ANS0RB36721W";
      sectors = 1953525168;
      members = [
        "enp0s13f0u3"
        "enp0s13f0u4"
      ];
      mac = "9c:bf:0d:00:0d:3c";
      gpu = "8086:4626";
    };
    framework-03 = {
      model = "Samsung SSD 980 1TB";
      serial = "S64ANL0T801753P";
      sectors = 1953525168;
      members = [
        "enp0s13f0u3"
        "enp0s13f0u4"
      ];
      mac = "9c:bf:0d:00:20:37";
      gpu = "8086:9a49";
    };
  };
  installer =
    host:
    let
      f = facts.${host};
    in
    import ../installers/framework-installer.nix {
      inherit pkgs commands roots;
      inherit (pkgs) lib;
      diskoPackage = pkgs.disko or pkgs.hello;
      targetHost = host;
      targetSystem = "/nix/store/test-system";
      diskById = "/build/fixture/dev/disk/by-id/nvme-Samsung";
      diskModel = f.model;
      diskSerial = f.serial;
      diskSectors = f.sectors;
      nicMembers = f.members;
      nicMac = f.mac;
      gpuPciId = f.gpu;
    };
  productionInstaller = import ../installers/framework-installer.nix {
    inherit pkgs;
    inherit (pkgs) lib;
    diskoPackage = pkgs.hello;
    targetHost = "framework-01";
    targetSystem = "/nix/store/test-system";
    diskById = "UNRESOLVED";
    diskModel = "model";
    diskSerial = "serial";
    diskSectors = 1;
    nicMembers = [ "eth0" ];
    nicMac = "00:00:00:00:00:00";
    gpuPciId = "8086:0000";
  };
in
pkgs.runCommand "installer-safety-tests"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
    ];
  }
  ''
    export INSTALL_01=${installer "framework-01"}/bin/install-framework-01
    export INSTALL_02=${installer "framework-02"}/bin/install-framework-02
    export INSTALL_03=${installer "framework-03"}/bin/install-framework-03
    export PROD_01=${productionInstaller}
    test -s ${evaluatedDiskConfig}
    bash ${./installer-safety-tests.sh}
    touch "$out"
  ''
