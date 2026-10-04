{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.fleet.telemetry;
  hasComin =
    lib.hasAttrByPath [ "services" "comin" "enable" ] options && config.services.comin.enable;
  builtInTargets = {
    collector = "127.0.0.1:8888";
    node = "127.0.0.1:9100";
  }
  // lib.optionalAttrs hasComin { comin = "127.0.0.1:4243"; };
  targets = builtInTargets // cfg.localPrometheusTargets;
  secretKeyPattern = "(?i)(^|[._-])(password|token|secret|authorization|cookie|api[._-]?key)($|[._-])";
  scrapeConfigs = lib.mapAttrsToList (name: address: {
    job_name = name;
    static_configs = [ { targets = [ address ]; } ];
  }) targets;
  baseSettings = {
    extensions."file_storage/journald" = {
      directory = "/var/lib/opentelemetry-collector/checkpoints";
      create_directory = true;
    };
    receivers = {
      hostmetrics = {
        collection_interval = "15s";
        scrapers = {
          cpu = { };
          load = { };
          memory = { };
          filesystem = { };
          disk = { };
          network = { };
          processes = { };
        };
      };
      journald = {
        directory = "/var/log/journal";
        start_at = "end";
        storage = "file_storage/journald";
      };
      prometheus.config.scrape_configs = scrapeConfigs;
      otlp.protocols = {
        grpc.endpoint = "127.0.0.1:4317";
        http.endpoint = "127.0.0.1:4318";
      };
    };
    processors = {
      memory_limiter = {
        check_interval = "1s";
        limit_mib = 256;
        spike_limit_mib = 64;
      };
      "transform/normalize" = {
        error_mode = "ignore";
        metric_statements = [
          {
            context = "resource";
            statements = [
              ''set(attributes["host.name"], "${config.networking.hostName}")''
              ''set(attributes["deployment.environment"], "homelab")''
              ''set(attributes["deployment.revision"], "${cfg.revision}")''
              ''set(attributes["service.name"], "host-agent") where attributes["service.name"] == nil''
              ''delete_matching_keys(attributes, "${secretKeyPattern}")''
            ];
          }
          {
            context = "datapoint";
            statements = [
              ''delete_matching_keys(attributes, "${secretKeyPattern}")''
            ];
          }
        ];
        log_statements = [
          {
            context = "resource";
            statements = [
              ''set(attributes["host.name"], "${config.networking.hostName}")''
              ''set(attributes["deployment.environment"], "homelab")''
              ''set(attributes["deployment.revision"], "${cfg.revision}")''
              ''set(attributes["service.name"], "host-agent") where attributes["service.name"] == nil''
              ''delete_matching_keys(attributes, "${secretKeyPattern}")''
            ];
          }
          {
            context = "log";
            statements = [
              ''delete_matching_keys(attributes, "${secretKeyPattern}")''
            ];
          }
        ];
        trace_statements = [
          {
            context = "resource";
            statements = [
              ''set(attributes["host.name"], "${config.networking.hostName}")''
              ''set(attributes["deployment.environment"], "homelab")''
              ''set(attributes["deployment.revision"], "${cfg.revision}")''
              ''set(attributes["service.name"], "host-agent") where attributes["service.name"] == nil''
              ''delete_matching_keys(attributes, "${secretKeyPattern}")''
            ];
          }
          {
            context = "span";
            statements = [
              ''delete_matching_keys(attributes, "${secretKeyPattern}")''
            ];
          }
        ];
      };
      batch = {
        timeout = "2s";
        send_batch_size = 1024;
      };
    };
    exporters = {
      prometheus = {
        endpoint = "0.0.0.0:${toString cfg.prometheusPort}";
        resource_to_telemetry_conversion.enabled = true;
      };
      otlphttp = {
        endpoint = cfg.gatewayEndpoint;
        sending_queue.enabled = false;
        retry_on_failure = {
          enabled = true;
          initial_interval = "1s";
          max_interval = "10s";
          max_elapsed_time = cfg.retryMaxElapsedTime;
        };
      };
    };
    service = {
      extensions = [ "file_storage/journald" ];
      pipelines = {
        metrics = {
          receivers = [
            "hostmetrics"
            "prometheus"
            "otlp"
          ];
          processors = [
            "memory_limiter"
            "transform/normalize"
            "batch"
          ];
          exporters = [
            "prometheus"
            "otlphttp"
          ];
        };
        logs = {
          receivers = [
            "journald"
            "otlp"
          ];
          processors = [
            "memory_limiter"
            "transform/normalize"
            "batch"
          ];
          exporters = [ "otlphttp" ];
        };
        traces = {
          receivers = [ "otlp" ];
          processors = [
            "memory_limiter"
            "transform/normalize"
            "batch"
          ];
          exporters = [ "otlphttp" ];
        };
      };
    };
  };
in
{
  options.fleet.telemetry = {
    enable = lib.mkEnableOption "fleet OpenTelemetry agent";
    gatewayEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "http://observability:4320";
      description = "OTLP/HTTP gateway endpoint resolved by fleet DNS or Tailscale.";
    };
    prometheusPort = lib.mkOption {
      type = lib.types.port;
      default = 9464;
      description = "Consolidated Prometheus endpoint port.";
    };
    retryMaxElapsedTime = lib.mkOption {
      type = lib.types.strMatching "[1-9][0-9]*s";
      default = "60s";
      description = "Maximum elapsed time for retrying failed telemetry exports.";
    };
    revision = lib.mkOption {
      type = lib.types.str;
      default = "unknown";
      description = "Deployment/comin revision attached to every signal.";
    };
    localPrometheusTargets = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Named, authoritative local Prometheus host:port targets registered by service modules.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.opentelemetry-collector = {
      enable = true;
      package = pkgs.opentelemetry-collector-contrib;
      settings = baseSettings;
    };
    services.prometheus.exporters.node = {
      enable = true;
      enabledCollectors = [ "systemd" ];
      extraFlags = [ "--collector.textfile.directory=/var/lib/node_exporter/textfile_collector" ];
    };
    systemd.tmpfiles.rules = [ "d /var/lib/node_exporter/textfile_collector 0755 root root -" ];
    networking.firewall.extraInputRules = ''
      ip saddr 10.15.4.6 tcp dport ${toString cfg.prometheusPort} accept comment "observability agent scrape"
    '';
  };
}
