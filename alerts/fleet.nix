[
  {
    name = "fleet";
    rules = [
      {
        alert = "FleetHostDown";
        expr = ''up{job=~"fleet-agents|public-endpoints"} == 0'';
        for = "5m";
        labels.severity = "critical";
      }
      {
        alert = "SystemdUnitFailed";
        expr = ''node_systemd_unit_state{state="failed"} == 1'';
        for = "5m";
        labels.severity = "warning";
      }
      {
        alert = "SystemdRestartLoop";
        expr = "increase(node_systemd_service_restart_total[15m]) > 5";
        labels.severity = "warning";
      }
      {
        alert = "DiskOrSmartFault";
        expr = "node_smartmon_device_smart_status != 1 or node_filesystem_device_error == 1";
        labels.severity = "critical";
      }
      {
        alert = "HostTemperatureHigh";
        expr = "node_hwmon_temp_celsius > 80";
        for = "10m";
        labels.severity = "warning";
      }
      {
        alert = "NfsUnavailable";
        expr = "node_nfs_requests_total and on(instance) up == 0";
        labels.severity = "critical";
      }
      {
        alert = "PostgresUnavailable";
        expr = "pg_up == 0";
        for = "2m";
        labels.severity = "critical";
      }
      {
        alert = "PostgresNearCapacity";
        expr = "pg_database_size_bytes / pg_database_size_limit_bytes > 0.85";
        labels.severity = "warning";
      }
      {
        alert = "BackupStale";
        expr = "time() - backup_last_success_timestamp_seconds > 93600";
        labels.severity = "critical";
      }
      {
        alert = "BackupOrRestoreFailed";
        expr = "backup_last_run_success == 0 or restore_last_rehearsal_success == 0";
        labels.severity = "critical";
      }
      {
        alert = "CominFailed";
        expr = ''comin_build_total{status="failure"} > 0'';
        labels.severity = "critical";
      }
      {
        alert = "CominRevisionLag";
        expr = "comin_current_revision_info != on(host_name) group_left comin_expected_revision_info";
        for = "15m";
        labels.severity = "warning";
      }
      {
        alert = "TelemetryRefusedOrDropped";
        expr = "increase(otelcol_receiver_refused_spans[5m]) + increase(otelcol_receiver_refused_log_records[5m]) + increase(otelcol_receiver_refused_metric_points[5m]) + increase(otelcol_exporter_send_failed_spans[5m]) > 0";
        labels.severity = "warning";
      }
      {
        alert = "TelemetryDisk75Percent";
        expr = ''1 - node_filesystem_avail_bytes{mountpoint="/var/lib/telemetry"} / node_filesystem_size_bytes{mountpoint="/var/lib/telemetry"} > 0.75'';
        for = "10m";
        labels.severity = "warning";
      }
      {
        alert = "TelemetryDisk85Percent";
        expr = ''1 - node_filesystem_avail_bytes{mountpoint="/var/lib/telemetry"} / node_filesystem_size_bytes{mountpoint="/var/lib/telemetry"} > 0.85'';
        for = "5m";
        labels.severity = "critical";
      }
    ];
  }
]
