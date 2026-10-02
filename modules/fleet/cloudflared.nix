{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.cloudflared;
  hostnames = map (route: route.hostname) cfg.routes;
  duplicates = lib.filter (hostname: lib.count (candidate: candidate == hostname) hostnames > 1) (
    lib.unique hostnames
  );
  isWildcard = hostname: lib.hasPrefix "*." hostname;
  wildcardSuffix = hostname: lib.removePrefix "*." hostname;
  overlaps =
    exact: wildcard:
    exact == wildcardSuffix wildcard || lib.hasSuffix ".${wildcardSuffix wildcard}" exact;
  routeAt = index: builtins.elemAt cfg.routes index;
  indexes = lib.range 0 ((builtins.length cfg.routes) - 1);
  shadowedExactRoutes = lib.concatMap (
    wildcardIndex:
    let
      wildcard = routeAt wildcardIndex;
    in
    lib.optionals (isWildcard wildcard.hostname) (
      lib.filter (exact: !isWildcard exact.hostname && overlaps exact.hostname wildcard.hostname) (
        map routeAt (lib.drop (wildcardIndex + 1) indexes)
      )
    )
  ) indexes;
  routeType = lib.types.submodule {
    options = {
      hostname = lib.mkOption { type = lib.types.str; };
      origin = lib.mkOption { type = lib.types.strMatching "^http://10\\.15\\.4\\.[0-9]+:[0-9]+$"; };
      hostHeader = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
    };
  };
  ingress =
    map (
      route:
      {
        inherit (route) hostname;
        service = route.origin;
      }
      // lib.optionalAttrs (route.hostHeader != null) {
        originRequest.httpHostHeader = route.hostHeader;
      }
    ) cfg.routes
    ++ [ { service = "http_status:404"; } ];
  configFile = pkgs.writeText "fleet-cloudflared.yml" (
    lib.generators.toYAML { } { inherit ingress; }
  );
  launcher = pkgs.writeShellScript "fleet-cloudflared-run" ''
    set -euo pipefail
    credential="$CREDENTIALS_DIRECTORY/tunnel.json"
    tunnel_id="$(${lib.getExe pkgs.jq} -er '.TunnelID | select(type == "string" and test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))' "$credential")"
    exec ${lib.getExe cfg.package} tunnel --no-autoupdate --config ${configFile} \
      --credentials-file "$credential" run "$tunnel_id"
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
    assertions = [
      {
        assertion = duplicates == [ ];
        message = "fleet.cloudflared.routes contains duplicate hostnames: ${lib.concatStringsSep ", " duplicates}";
      }
      {
        assertion = shadowedExactRoutes == [ ];
        message = "fleet.cloudflared.routes must place every exact hostname before an overlapping wildcard";
      }
      {
        assertion = lib.all (route: isWildcard route.hostname -> route.hostHeader == null) cfg.routes;
        message = "fleet.cloudflared wildcard routes must preserve the incoming Host header";
      }
      {
        assertion = lib.all (
          route: !isWildcard route.hostname -> route.hostHeader == route.hostname
        ) cfg.routes;
        message = "fleet.cloudflared exact routes must override Host with their exact hostname";
      }
    ];
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
        LoadCredential = "tunnel.json:${cfg.credentialFile}";
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
