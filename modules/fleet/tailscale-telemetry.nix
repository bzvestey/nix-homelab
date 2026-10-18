{
  config,
  lib,
  pkgs,
  ...
}:
let
  proxies = config.fleet.tailscaleServiceProxy.proxies or { };
  identities =
    lib.optionalAttrs config.services.tailscale.enable {
      native = "/run/tailscale/tailscaled.sock";
    }
    // lib.mapAttrs (name: _: "/run/tailscale-${name}/tailscaled.sock") proxies;
  collector = pkgs.writeShellScript "tailscale-telemetry" ''
    exec ${pkgs.python3}/bin/python3 ${./tailscale-status.py} \
      ${lib.getExe config.services.tailscale.package} \
      /var/lib/node_exporter/textfile_collector/tailscale.prom \
      ${lib.escapeShellArgs (lib.mapAttrsToList (name: socket: "${name}=${socket}") identities)}
  '';
in
{
  config = lib.mkIf (config.fleet.telemetry.enable && identities != { }) {
    assertions = [
      {
        assertion = !(builtins.hasAttr "native" proxies);
        message = "Tailscale telemetry reserves the identity name native for the host daemon.";
      }
    ];
    systemd.services.tailscale-telemetry = {
      description = "Read-only aggregate Tailscale status telemetry";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = collector;
        # Root is required to read the existing mode-0700 service sockets.
        User = "root";
        TimeoutStartSec = 10 + 6 * builtins.length (builtins.attrNames identities);
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        ReadWritePaths = [ "/var/lib/node_exporter/textfile_collector" ];
      };
    };
    systemd.timers.tailscale-telemetry = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "30s";
      };
    };
  };
}
