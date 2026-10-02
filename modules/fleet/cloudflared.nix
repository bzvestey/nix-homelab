{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.cloudflared;
  routeType = lib.types.submodule {
    options = {
      hostname = lib.mkOption { type = lib.types.str; };
      origin = lib.mkOption { type = lib.types.strMatching "^http://10\\.15\\.4\\.[0-9]+:[0-9]+$"; };
      hostHeader = lib.mkOption { type = lib.types.str; };
    };
  };
  ingress =
    map (route: {
      inherit (route) hostname;
      service = route.origin;
      originRequest.httpHostHeader = route.hostHeader;
    }) cfg.routes
    ++ [ { service = "http_status:404"; } ];
  configFile = pkgs.writeText "fleet-cloudflared.yml" (
    lib.generators.toYAML { } { inherit ingress; }
  );
  launcher = pkgs.writeShellScript "fleet-cloudflared-run" ''
    set -euo pipefail
    tunnel_id="$(${lib.getExe pkgs.jq} -er '.TunnelID | select(type == "string" and length > 0)' ${lib.escapeShellArg cfg.credentialFile})"
    exec ${lib.getExe cfg.package} tunnel --no-autoupdate --config ${configFile} \
      --credentials-file ${lib.escapeShellArg cfg.credentialFile} run "$tunnel_id"
  '';
in
{
  options.fleet.cloudflared = {
    enable = lib.mkEnableOption "redundant fleet Cloudflare connector";
    credentialFile = lib.mkOption {
      type = lib.types.strMatching "^/run/secrets/.*";
      default = "/run/secrets/cloudflared-tunnel.json";
      description = "Runtime tunnel credential JSON shared only by the Pi connector recipient group.";
    };
    routes = lib.mkOption {
      type = lib.types.listOf routeType;
      default = [ ];
      description = "Ordered public hostname-to-origin map.";
    };
    package = lib.mkPackageOption pkgs "cloudflared" { };
  };

  config = lib.mkIf cfg.enable {
    environment.etc."cloudflared/fleet-ingress.yml".source = configFile;
    systemd.services.cloudflared-fleet = {
      description = "Fail-closed redundant Cloudflare tunnel connector";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig = {
        ConditionPathIsReadable = cfg.credentialFile;
        StartLimitIntervalSec = 300;
        StartLimitBurst = 5;
      };
      serviceConfig = {
        ExecStart = launcher;
        Restart = "on-failure";
        RestartSec = "10s";
        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
      };
    };
  };
}
