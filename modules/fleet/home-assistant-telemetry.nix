{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet.observability.homeAssistant;
  platform = ''job="homeassistant-platform",host_name="homeassistant"'';
  fresh =
    source:
    ''(haos_collection_success{${platform},source="${source}"} == 1) and (time() - haos_collection_last_success_timestamp_seconds{${platform},source="${source}"} < 90)'';
  rule = alert: expr: severity: {
    inherit alert expr;
    for = "5m";
    labels = { inherit severity; };
  };
in
{
  options.fleet.observability.homeAssistant = {
    enable = lib.mkEnableOption "authenticated operational HAOS collection (no entity data)";
    target = lib.mkOption {
      type = lib.types.str;
      default = "100.75.116.65:9126";
      description = "Collector host:port; Supervisor credentials must remain on HAOS.";
    };
    tokenFile = lib.mkOption {
      type = lib.types.strMatching "^/run/.+";
      default = "/run/secrets/homeassistant-metrics-token";
      description = "Runtime bearer-token file readable by Prometheus; never a Supervisor token.";
    };
    nativeSources = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "kuma"
          "grafana"
          "influxdb"
        ]
      );
      default = [ ];
      description = "Only explicitly verified and enabled native collector sources.";
    };
    requiredApps = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[a-zA-Z0-9_-]{1,100}");
      default = [ ];
      description = "Explicit always-on app slugs; stopped utilities are not outages by default.";
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.unique cfg.nativeSources == cfg.nativeSources;
        message = "Home Assistant native sources must be unique.";
      }
    ];
    services.prometheus = {
      checkConfig = "syntax-only";
      scrapeConfigs = map (source: {
        job_name = "homeassistant-${source}";
        metrics_path = if source == "platform" then "/metrics" else "/metrics/${source}";
        scrape_interval = "60s";
        scrape_timeout = "10s";
        sample_limit = if source == "platform" then 10000 else 20000;
        authorization = {
          type = "Bearer";
          credentials_file = cfg.tokenFile;
        };
        static_configs = [
          {
            targets = [ cfg.target ];
            labels.host_name = "homeassistant";
          }
        ];
      }) ([ "platform" ] ++ cfg.nativeSources);
      ruleFiles = [
        (pkgs.writeText "home-assistant-alerts.json" (
          builtins.toJSON {
            groups = [
              {
                name = "home-assistant";
                rules = [
                  (rule "HomeAssistantCollectorUnavailable" "up{${platform}} == 0 or absent(up{${platform}})"
                    "critical"
                  )
                  (rule "HomeAssistantCriticalCollectionStale" (lib.concatMapStringsSep " or "
                    (source: "absent(${fresh source})")
                    [
                      "inventory"
                      "core_stats"
                      "supervisor_stats"
                      "host"
                    ]
                  ) "critical")
                  (rule "HomeAssistantDiskPressure"
                    "(haos_host_disk_free_bytes{${platform}} / haos_host_disk_total_bytes{${platform}} < 0.15) and on(host_name) (${fresh "host"})"
                    "warning"
                  )
                ]
                ++ map (
                  app:
                  (rule "HomeAssistantRequiredAppNotRunning"
                    ''absent(haos_app_state{${platform},app="${app}",state="started"} == 1 and on(host_name) (${fresh "inventory"}))''
                    "critical"
                  )
                  // {
                    labels = {
                      severity = "critical";
                      inherit app;
                    };
                  }
                ) cfg.requiredApps;
              }
            ];
          }
        ))
      ];
    };
  };
}
