{ ... }:
{
  imports = [ ../../modules/fleet/base.nix ../../modules/fleet/networking.nix ../../modules/fleet/comin.nix ];
  # Bootstrap only: deployment is forbidden until acceptance records the MAC.
  systemd.network.networks."20-bootstrap-lan" = {
    matchConfig.Type = "ether";
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
      for type in /sys/class/net/*/type; do
        [ "$(cat "$type")" = 1 ] || continue
        [ "$(basename "$(dirname "$type")")" = lo ] && continue
        count=$((count + 1))
      done
      [ "$count" -eq 1 ] || { echo "bootstrap requires exactly one Ethernet link; found $count" >&2; exit 1; }
    '';
  };
  warnings = [ "observability-pi physical deployment is forbidden until acceptance records its Ethernet MAC" ];
}
