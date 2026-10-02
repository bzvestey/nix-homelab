{ lib, ... }:
let
  wiredLink = import ../../lib/wired-link.nix;
in
{
  imports = [
    ../../modules/fleet/base.nix
    ../../modules/fleet/networking.nix
    ../../modules/fleet/comin.nix
    ../../modules/fleet/telemetry-agent.nix
  ];
  fleet.telemetry.enable = true;
  # Bootstrap remains reachable, but comin cannot switch this host until the
  # physical link's observed MAC is recorded in inventory and used here.
  services.comin.enable = lib.mkForce false;
  systemd.network.networks."20-bootstrap-lan" = {
    inherit (wiredLink) matchConfig;
    address = [ "10.15.4.6/24" ];
    routes = [ { Gateway = "10.15.4.1"; } ];
    networkConfig.DNS = [ "10.15.4.1" ];
  };
  systemd.services.observability-bootstrap-single-ethernet = {
    description = "Refuse ambiguous observability bootstrap networking";
    requiredBy = [ "systemd-networkd.service" ];
    before = [ "systemd-networkd.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      count=0
      while IFS= read -r link; do
        count=$((count + 1))
      done < <(${wiredLink.selectScript})
      [ "$count" -eq 1 ] || { echo "bootstrap requires exactly one Ethernet link; found $count" >&2; exit 1; }
    '';
  };
}
