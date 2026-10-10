{
  pkgs,
  disko,
  fleetTopology,
}:
let
  inherit (pkgs) lib;
  # Synthetic QEMU hardware identities; exercise the real host/ISO generators.
  nic = fleetTopology.nodes.hl-node-02.nic // {
    macAddress = "52:54:00:12:01:01";
    permanentMacAddresses = lib.mapAttrs (
      _: mac: if mac == "9c:bf:0d:00:23:fe" then "52:54:00:12:01:01" else "52:54:00:12:02:01"
    ) fleetTopology.nodes.hl-node-02.nic.permanentMacAddresses;
  };
  host = import ../hosts/hl-node-02/default.nix {
    inherit lib;
    fleetTopology.nodes.hl-node-02 = { inherit nic; };
  };
  iso = import ../installers/framework-iso.nix {
    inherit lib pkgs disko;
    modulesPath = pkgs.path + /nixos/modules;
    targetHost = "hl-node-02";
    targetSystem = "/nix/store/test-system";
    diskById = "UNRESOLVED";
    diskModel = "fixture";
    diskSerial = "fixture";
    diskSectors = 1;
    nicMembers = nic.members;
    nicMac = nic.macAddress;
    nicPermanentMacs = nic.permanentMacAddresses;
    address = "10.15.4.5";
    gpuPciId = "8086:9a49";
  };
in
assert host.systemd.network == iso.systemd.network;
pkgs.testers.runNixOSTest {
  name = "framework-permanent-nic-names";
  nodes.machine = {
    virtualisation = {
      vlans = [
        1
        2
        3
      ];
      memorySize = 1024;
    };
    boot.initrd.systemd.enable = iso.boot.initrd.systemd.enable;
    networking = {
      useDHCP = false;
      useNetworkd = true;
      interfaces = lib.mkForce { };
      networkmanager = iso.networking.networkmanager;
    };
    systemd.network = host.systemd.network // {
      enable = true;
    };
    environment.systemPackages = [ pkgs.ethtool ];
  };
  testScript = ''
    from datetime import timedelta
    start_all()
    machine.wait_for_unit("systemd-networkd.service")
    # A historical USB path selector leaves these differently enumerated NICs out.
    machine.wait_until_succeeds("test -d /sys/class/net/lan0 && test -d /sys/class/net/lan1", timeout=timedelta(seconds=20))
    machine.wait_until_succeeds("test $(wc -w </sys/class/net/bond0/bonding/slaves) -eq 2")
    assert set(machine.succeed("cat /sys/class/net/bond0/bonding/slaves").split()) == {"lan0", "lan1"}
    assert machine.succeed("ethtool -P lan0").strip() == "Permanent address: 52:54:00:12:01:01"
    assert machine.succeed("ethtool -P lan1").strip() == "Permanent address: 52:54:00:12:02:01"
    machine.succeed("ip -4 -o addr show bond0 | grep -F '10.15.4.5/24'")
    machine.succeed("test $(cat /sys/class/net/bond0/bonding/miimon) -eq 100")
    machine.fail("systemctl is-active --quiet NetworkManager")
    # The hub NIC must stay excluded even if its current MAC equals the bond's.
    machine.succeed("ip link set eth3 down; ip link set eth3 address 52:54:00:12:01:01; udevadm trigger --action=add /sys/class/net/eth3; udevadm settle; networkctl reconfigure lan0 lan1 eth3")
    machine.succeed("test -d /sys/class/net/eth3 && test ! -e /sys/class/net/eth3/master")
    assert machine.succeed("ethtool -P eth3").strip() == "Permanent address: 52:54:00:12:03:01"
    assert machine.succeed("cat /sys/class/net/lan0/address").strip() == machine.succeed("cat /sys/class/net/lan1/address").strip()
    active = machine.succeed("cat /sys/class/net/bond0/bonding/active_slave").strip()
    other = "lan1" if active == "lan0" else "lan0"
    index = 1 if active == "lan0" else 2
    machine.send_monitor_command(f"set_link virtio-net-pci.{index} off")
    machine.wait_until_succeeds(f"test $(cat /sys/class/net/bond0/bonding/active_slave) = {other}")
    machine.succeed("ip -4 -o addr show bond0 | grep -F '10.15.4.5/24'")
    machine.send_monitor_command(f"set_link virtio-net-pci.{index} on")
    machine.wait_until_succeeds(f"test $(cat /sys/class/net/{active}/carrier) -eq 1")
  '';
}
