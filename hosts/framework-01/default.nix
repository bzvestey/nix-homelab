{ ... }:
{
  imports = [ ../../modules/fleet/base.nix ../../modules/fleet/networking.nix ../../modules/fleet/comin.nix ];
  systemd.network = {
    netdevs."10-bond0".netdevConfig = { Kind = "bond"; Name = "bond0"; };
    networks = {
      "10-member-1" = { matchConfig = { Name = "enp0s13f0u1"; MACAddress = "9c:bf:0d:00:23:fe"; }; networkConfig.Bond = "bond0"; };
      "10-member-2" = { matchConfig = { Name = "enp0s13f0u2"; MACAddress = "9c:bf:0d:00:23:fe"; }; networkConfig.Bond = "bond0"; };
      "20-bond0" = { matchConfig.Name = "bond0"; address = [ "10.15.4.5/24" ]; routes = [ { Gateway = "10.15.4.1"; } ]; networkConfig.DNS = [ "10.15.4.1" ]; };
    };
  };
}
