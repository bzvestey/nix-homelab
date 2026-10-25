"""Execute dashboard expressions against asymmetric Prometheus data contracts."""
import json
import os
from pathlib import Path

dashboards = Path(os.environ["DASHBOARDS"])


def expression(dashboard, panel_id, ref="A", interval_seconds=15):
    data = json.loads((dashboards / (dashboard + ".json")).read_text())
    panel = next(panel for panel in data["panels"] if panel["id"] == panel_id)
    target = next(target for target in panel["targets"] if target["refId"] == ref)
    query = target["expr"]
    rate_interval = "2m"
    if dashboard == "home-assistant-apps" and "$__rate_interval" in query:
        # Grafana uses query Min step, or the datasource's default 15s scrape
        # interval when unset: max($__interval + scrape, 4 * scrape).
        scrape_seconds = int(target.get("interval", "15s").removesuffix("s"))
        rate_interval = str(max(interval_seconds + scrape_seconds, 4 * scrape_seconds)) + "s"
    for variable, value in {
        "${host:regex}": "alpha|beta", "${cluster:regex}": ".*",
        "${database:regex}": ".*", "${backup:regex}": ".*",
        "${metric:regex}": r"nas\.system\.cpu\.user",
        "${app:regex}": ".*", "${monitor:regex}": ".*", "${window:regex}": "30d",
        "$__rate_interval": rate_interval, "$__range": "5m",
    }.items():
        query = query.replace(variable, value)
    return query


series = []


def metric(name, labels, values):
    dimensions = ",".join(key + "=" + json.dumps(value) for key, value in labels.items())
    series.append({"series": name + "{" + dimensions + "}", "values": values})


for host, state in [("alpha", "0"), ("beta", "1")]:
    metric("node_systemd_unit_state", {"job": "node", "host_name": host, "instance": "127.0.0.1:9100", "name": "one.service", "state": "failed"}, state + "+0x5")
metric("node_systemd_unit_state", {"job": "node", "host_name": "beta", "instance": "127.0.0.1:9100", "name": "two.service", "state": "failed"}, "1+0x5")
# Decoys are the lossy duplicate gateway copy and an unrelated host.
for host in ["alpha", "gamma"]:
    metric("node_systemd_unit_state", {"job": "otel-gateway", "host_name": host, "state": "failed"}, "90+0x5")
metric("node_systemd_unit_state", {"job": "node", "host_name": "gamma", "name": "bad.service", "state": "failed"}, "80+0x5")
for host, revision in [("alpha", "aaa"), ("beta", "bbb")]:
    metric("comin_deployment_info", {"job": "comin", "host_name": host, "commit_id": revision, "status": "done"}, "1+0x5")
    metric("fleet_podman_collection_success", {"job": "node", "host_name": host}, ("1" if host == "alpha" else "0") + "+0x5")
    metric("fleet_podman_collection_timestamp_seconds", {"job": "node", "host_name": host}, "150+0x5")
    metric("fleet_podman_container_running", {"job": "node", "host_name": host, "container": "app"}, "1+0x5")
metric("fleet_podman_container_running", {"job": "node", "host_name": "alpha", "container": "stopped"}, "0+0x5")
metric("fleet_podman_container_running", {"job": "otel-gateway", "host_name": "alpha"}, "30+0x5")
for host, cluster, up in [("alpha", "stock", "1"), ("beta", "secondary", "0")]:
    metric("pg_up", {"job": "postgres-" + cluster, "host_name": host, "cluster": cluster}, up + "+0x5")
metric("pg_fleet_xact_commit_total", {"job": "postgres-stock", "host_name": "alpha", "cluster": "stock", "datname": "app"}, "0+60x5")
metric("fleet_backup_result", {"job": "node", "host_name": "alpha", "exported_job": "daily"}, "1+0x5")
metric("fleet_backup_result", {"job": "otel-gateway", "host_name": "alpha"}, "0+0x5")
metric("probe_success", {"job": "public-endpoints", "instance": "ok.example", "service": "ok.example"}, "1+0x5")
metric("probe_success", {"job": "public-endpoints", "instance": "bad.example", "service": "bad.example"}, "0+0x5")
metric("smartctl_device_smart_status", {"job": "smartctl", "host_name": "alpha", "device": "sda"}, "1+0x5")
metric("smartctl_device_smart_status", {"job": "smartctl", "host_name": "beta", "device": "nvme0"}, "0+0x5")
metric("fleet_restore_rehearsal_result", {"job": "node", "host_name": "alpha", "exported_job": "daily", "snapshot": "abc"}, "1+0x5")
for host, success, timestamp, peers in [("alpha", "1", "300", "2"), ("beta", "1", "150", "7")]:
    labels = {"job": "node", "host_name": host, "identity": "native"}
    metric("tailscale_status_collection_success", labels, success + "+0x5")
    metric("tailscale_status_collection_timestamp_seconds", labels, timestamp + "+0x5")
    metric("tailscale_peer_online", labels, peers + "+0x5")
metric("tailscale_peer_online", {"job": "otel-gateway", "host_name": "alpha"}, "99+0x5")
# Two one-minute scrape stages plus the 30-second status timer can produce
# 150-second-old healthy data. Keep it, but exclude the three-minute boundary.
stale = {"job": "node", "host_name": "alpha", "identity": "stale"}
metric("tailscale_peer_online", stale, "9+0x5")
metric("tailscale_status_collection_success", stale, "1+0x5")
metric("tailscale_status_collection_timestamp_seconds", stale, "120+0x5")
for host, free, size in [("alpha", "25", "100"), ("beta", "125", "200")]:
    labels = {"job": "node", "host_name": host, "mountpoint": "/", "fstype": "ext4"}
    metric("node_filesystem_avail_bytes", labels, free + "+0x5")
    metric("node_filesystem_size_bytes", labels, size + "+0x5")

tests = []

for host, available, scrape in [("alpha", "1", "1"), ("beta", "1", "0")]:
    labels = {"job": "garage", "host_name": host, "instance": host + ":30190"}
    metric("up", labels, scrape + "+0x5")
    metric("cluster_available", labels, available + "+0x5")
    metric("cluster_healthy", labels, "1+0x5")
    metric("garage_local_disk_total", {**labels, "volume": "data"}, "200+0x5")
    metric("garage_local_disk_avail", {**labels, "volume": "data"}, "50+0x5")
metric("truenas_netdata", {"job": "truenas", "host_name": "nas", "metric": "nas.system.cpu.user"}, "23+0x5")
metric("truenas_netdata", {"job": "truenas", "host_name": "nas", "metric": "nas.system.cpu.idle"}, "71+0x5")


def check(dashboard, panel, samples, ref="A"):
    tests.append({"expr": expression(dashboard, panel, ref), "eval_time": "5m", "exp_samples": [
        {"labels": labels, "value": value} for labels, value in samples
    ]})


check("nas", 1, [('{}', 2)])
check("nas", 3, [('cluster_available{job="garage",host_name="alpha",instance="alpha:30190"}', 1)])
check("nas", 4, [('cluster_healthy{job="garage",host_name="alpha",instance="alpha:30190"}', 1)])
check("nas", 5, [('truenas_netdata{job="truenas",host_name="nas",metric="nas.system.cpu.user"}', 23)])
check("nas", 6, [('{job="garage",host_name="alpha",instance="alpha:30190",volume="data"}', 0.75)])
check("storage", 6, [('cluster_available{job="garage",host_name="alpha",instance="alpha:30190"}', 1)])
check("fleet", 2, [('{host_name="alpha"}', 0), ('{host_name="beta"}', 2)])
# Collector failure must hide unknown container state, not turn it into zero.
check("fleet", 3, [('{host_name="alpha"}', 1)])
check("comin", 1, [
    ('comin_deployment_info{job="comin",host_name="alpha",commit_id="aaa",status="done"}', 1),
    ('comin_deployment_info{job="comin",host_name="beta",commit_id="bbb",status="done"}', 1),
])
check("postgres", 1, [
    ('pg_up{job="postgres-stock",host_name="alpha",cluster="stock"}', 1),
    ('pg_up{job="postgres-secondary",host_name="beta",cluster="secondary"}', 0),
])
check("postgres", 3, [('{job="postgres-stock",host_name="alpha",cluster="stock",datname="app"}', 1)])
check("backups", 3, [('fleet_backup_result{job="node",host_name="alpha",exported_job="daily"}', 1)])
# A successful rehearsal must not turn an unrecorded actual restore into success.
check("backups", 6, [])
check("backups", 7, [('fleet_restore_rehearsal_result{job="node",host_name="alpha",exported_job="daily",snapshot="abc"}', 1)])
check("comin", 3, [('{}', 2)])
check("ingress", 3, [
    ('tailscale_peer_online{job="node",host_name="alpha",identity="native"}', 2),
    ('tailscale_peer_online{job="node",host_name="beta",identity="native"}', 7),
])
check("ingress", 1, [
    ('probe_success{job="public-endpoints",instance="ok.example",service="ok.example"}', 1),
    ('probe_success{job="public-endpoints",instance="bad.example",service="bad.example"}', 0),
])
check("storage", 3, [
    ('smartctl_device_smart_status{job="smartctl",host_name="alpha",device="sda"}', 1),
    ('smartctl_device_smart_status{job="smartctl",host_name="beta",device="nvme0"}', 0),
])
check("storage", 1, [
    ('{job="node",host_name="alpha",mountpoint="/",fstype="ext4"}', 0.75),
    ('{job="node",host_name="beta",mountpoint="/",fstype="ext4"}', 0.375),
])

# Home Assistant: asymmetric values, unrelated jobs/hosts, failed snapshots,
# exact freshness boundary, stopped inventory, and counter resets.
ha = {"job": "homeassistant-platform", "host_name": "homeassistant"}
metric("up", ha, "1+0x5")
def ha_health(source, app="", success="1", timestamp="211"):
    labels = {**ha, "source": source, "app": app}
    metric("haos_collection_success", labels, success + "+0x5")
    metric("haos_collection_last_success_timestamp_seconds", labels, timestamp + "+0x5")

for app, memory, cpu, stamp, success in [
    ("alpha", "123", "123.45", "211", "1"),
    ("beta", "777", "7.25", "211", "1"),
    ("stale", "888", "88", "210", "1"),
    ("failed", "999", "99", "211", "0"),
]:
    labels = {**ha, "component": "app", "app": app}
    metric("haos_memory_usage_bytes", labels, memory + "+0x5")
    metric("haos_cpu_percent", labels, cpu + "+0x5")
    # Reset in the final evaluated rate window, not before it.
    metric("haos_network_receive_bytes_total", labels, "0 60 120 180 240 60")
    metric("haos_network_transmit_bytes_total", labels, "0+120x5")
    metric("haos_block_read_bytes_total", labels, "0+180x5")
    metric("haos_block_write_bytes_total", labels, "0+300x5")
    metric("haos_memory_limit_bytes", labels, "1000+0x5")
    ha_health("app_stats", app, success, stamp)
    metric("haos_app_state", {**labels, "state": "started"}, "1+0x5")
ha_health("inventory")
metric("haos_app_state", {**ha, "component": "app", "app": "cb646a50_get", "state": "stopped"}, "1+0x5")
for job, host in [("otel-gateway", "homeassistant"), ("homeassistant-platform", "decoy")]:
    metric("haos_memory_usage_bytes", {"job": job, "host_name": host, "component": "app", "app": "alpha"}, "9999+0x5")
    metric("haos_collection_success", {"job": job, "host_name": host, "source": "app_stats", "app": "alpha"}, "1+0x5")
for component, value, success in [("core", "321", "0"), ("supervisor", "654", "1")]:
    metric("haos_memory_usage_bytes", {**ha, "component": component, "app": ""}, value + "+0x5")
    ha_health(component + "_stats", success=success)
ha_health("native_kuma", "a0d7b954_uptime-kuma")
ha_health("native_grafana", "a0d7b954_grafana")
ha_health("native_influxdb", "a0d7b954_influxdb", success="0")
for source, memory in [("grafana", "456"), ("influxdb", "987")]:
    metric("process_resident_memory_bytes", {"job": "homeassistant-" + source, "host_name": "homeassistant"}, memory + "+0x5")
    metric("process_cpu_seconds_total", {"job": "homeassistant-" + source, "host_name": "homeassistant"}, "0+30x5")
ha_health("host")
metric("haos_host_boot_completion_timestamp_seconds", ha, "17+0x5")
for field, value in [("total", 123.4), ("used", 45.6), ("free", 70.1)]:
    metric("haos_host_disk_" + field + "_bytes", ha, str(value * 1024**3) + "+0x5")
native = {"job": "homeassistant-kuma", "host_name": "homeassistant"}
for monitor, status, latency, ratio in [("17", "2", "123", "0.987"), ("29", "3", "-1", "0.75")]:
    labels = {**native, "monitor_id": monitor, "monitor_name": "Synthetic " + monitor, "monitor_type": "http"}
    metric("monitor_status", labels, status + "+0x5")
    metric("monitor_response_time", labels, latency + "+0x5")
    metric("monitor_uptime_ratio", {**labels, "window": "30d"}, ratio + "+0x5")
    metric("monitor_uptime_ratio", {**labels, "window": "1d"}, "0.1+0x5")
    metric("monitor_response_time_seconds", {**labels, "window": "30d"}, "0.456+0x5")
    metric("monitor_cert_days_remaining", labels, ("19" if monitor == "17" else "7") + "+0x5")
    metric("monitor_cert_is_valid", labels, ("1" if monitor == "17" else "0") + "+0x5")
    metric("monitor_status", {**labels, "job": "wrong"}, "99+0x5")

def label(name, labels):
    return name + "{" + ",".join(k + "=" + json.dumps(v) for k, v in labels.items()) + "}"
app_samples = lambda name, values: [(label(name, {**ha, "component": "app", "app": app}), value) for app, value in values]
check("home-assistant-apps", 3, app_samples("haos_cpu_percent", [("alpha", 123.45), ("beta", 7.25)]))
check("home-assistant-apps", 4, app_samples("haos_memory_usage_bytes", [("alpha", 123), ("beta", 777)]))
check("home-assistant-apps", 6, app_samples("", [("alpha", 1), ("beta", 1)]))
check("home-assistant-apps", 7, app_samples("", [("alpha", 2), ("beta", 2)]))
check("home-assistant-apps", 8, app_samples("", [("alpha", 3), ("beta", 3)]))
check("home-assistant-apps", 8, app_samples("", [("alpha", 5), ("beta", 5)]), ref="B")
check("home-assistant-apps", 5, app_samples("", [("alpha", 0.123), ("beta", 0.777)]))
check("home-assistant", 5, [(label("haos_memory_usage_bytes", {**ha, "component": "supervisor", "app": ""}), 654)])
check("home-assistant-apps", 12, [(label("process_resident_memory_bytes", {"job": "homeassistant-grafana", "host_name": "homeassistant"}), 456)])
check("home-assistant-apps", 12, [], ref="B")
check("home-assistant-apps", 11, [(label("", {"job": "homeassistant-grafana", "host_name": "homeassistant"}), 0.5)])
check("home-assistant-apps", 11, [], ref="B")
# Exercise every real rate target with one-minute samples, not an unconditional
# 2m substitution. Include native InfluxDB's successful control as well as its
# baseline failed-source control above. The receive counter resets at minute 5.
rate_targets = [(6, "A"), (7, "A"), (8, "A"), (8, "B"), (11, "A"), (11, "B")]
rate_series = [dict(item, values="1+0x5") if item["series"].startswith("haos_collection_success{")
               and 'source="native_influxdb"' in item["series"] else item for item in series]
for panel, ref in rate_targets:
    for interval_seconds in (1, 15, 300):
        query = expression("home-assistant-apps", panel, ref, interval_seconds)
        tests.append({"expr": "count(" + query + ")", "eval_time": "5m",
                      "exp_samples": [{"labels": "{}", "value": 1 if panel == 11 else 2}],
                      "fixture_series": rate_series})
    # A left-open 60s window has only one regularly spaced scrape: no rate.
    query = expression("home-assistant-apps", panel, ref).replace("[240s]", "[60s]")
    tests.append({"expr": query, "eval_time": "5m", "exp_samples": [], "fixture_series": rate_series})
check("home-assistant", 6, [(label("", ha), 283)])
check("home-assistant", 7, [(label("haos_host_disk_" + field + "_bytes", ha), value * 1024**3)
                           for field, value in [("total", 123.4), ("used", 45.6), ("free", 70.1)]])
tests.append({"expr": "sum(" + expression("home-assistant", 2) + ")", "eval_time": "5m",
              "exp_samples": [{"labels": "{}", "value": 7}]})
check("home-assistant-apps", 1, [
    (label("haos_app_state", {**ha, "component": "app", "app": app, "state": state}), 1)
    for app, state in [("alpha", "started"), ("beta", "started"), ("stale", "started"), ("failed", "started"), ("cb646a50_get", "stopped")]
])
monitor_labels = lambda mid: {**native, "monitor_id": mid, "monitor_name": "Synthetic " + mid, "monitor_type": "http"}
check("uptime-kuma", 1, [(label("monitor_status", monitor_labels(mid)), value) for mid, value in [("17", 2), ("29", 3)]])
check("uptime-kuma", 2, [(label("", monitor_labels("17")), 0.123)])
check("uptime-kuma", 4, [(label("monitor_uptime_ratio", {**monitor_labels(mid), "window": "30d"}), val) for mid, val in [("17", 0.987), ("29", 0.75)]])
check("uptime-kuma", 3, [(label("monitor_response_time_seconds", {**monitor_labels(mid), "window": "30d"}), 0.456) for mid in ["17", "29"]])
check("uptime-kuma", 5, [(label("monitor_cert_days_remaining", monitor_labels(mid)), val) for mid, val in [("17", 19), ("29", 7)]])
check("uptime-kuma", 6, [(label("monitor_cert_is_valid", monitor_labels(mid)), val) for mid, val in [("17", 1), ("29", 0)]])
for dashboard, panel, selector, value, expected in [
    ("home-assistant-apps", 4, "app", "beta", app_samples("haos_memory_usage_bytes", [("beta", 777)])),
    ("home-assistant-apps", 4, "app", "cb646a50_get", []),
    ("uptime-kuma", 1, "monitor_id", "29", [(label("monitor_status", monitor_labels("29")), 3)]),
]:
    tests.append({"expr": expression(dashboard, panel).replace(selector + '=~".*"', selector + '=~"' + value + '"'),
                  "eval_time": "5m", "exp_samples": [{"labels": labels, "value": val} for labels, val in expected]})
# Unknown inventory must not appear as an empty-but-healthy installed set.
tests.append({"expr": expression("home-assistant-apps", 1), "eval_time": "5m", "exp_samples": [],
              "fixture_series": [item for item in series if 'source="inventory"' not in item["series"]]})
# Same actual dashboard expressions, but missing/stale/failed native collection
# must hide even independently valid partial native families.
for timestamp, success in [("210", "1"), ("211", "0"), (None, None)]:
    changed = []
    for item in series:
        entry = dict(item)
        if 'source="native_kuma"' in entry["series"]:
            if timestamp is None:
                continue
            entry["values"] = (timestamp if entry["series"].startswith("haos_collection_last") else success) + "+0x5"
        changed.append(entry)
    # Separate fixture sets are emitted below, without mutating baseline controls.
    for panel in range(1, 7):
        tests.append({"expr": expression("uptime-kuma", panel), "eval_time": "5m", "exp_samples": [], "fixture_series": changed})

# Display contracts: metadata must not crowd identities/values offscreen, and
# organize needs a single frame (including the mixed host/OS inventory targets).
table_columns = {
    "home-assistant": {
        2: ["source", "app", "Value", "Value #A"],
        3: ["source", "app", "Value", "Value #A"],
        8: ["component", "version", "version_latest"],
        9: ["operating_system", "kernel", "version", "version_latest"],
        10: ["component", "Value", "Value #A"],
        11: ["__name__", "Value", "Value #A"],
    },
    "home-assistant-apps": {
        1: ["app", "state"], 2: ["app", "name", "version", "version_latest"],
        9: ["app", "source", "status"], 10: ["app", "Value", "Value #A"],
    },
    "uptime-kuma": {7: ["source", "app", "status"]},
}
for dashboard, columns in table_columns.items():
    data = json.loads((dashboards / (dashboard + ".json")).read_text())
    tables = {panel["id"]: panel for panel in data["panels"] if panel["type"] == "table"}
    assert tables.keys() == columns.keys(), (dashboard, "all tables need display contracts")
    for panel_id, names in columns.items():
        transforms = tables[panel_id].get("transformations", [])
        combine = "joinByField" if (dashboard, panel_id) == ("home-assistant", 9) else "merge"
        assert [item["id"] for item in transforms] == [combine, "filterFieldsByName", "organize"], (dashboard, panel_id, "combine frames and select display columns")
        assert transforms[1]["options"]["include"]["names"] == names
        organize = transforms[2]["options"]
        assert set(organize["indexByName"]) == set(names)
        assert all(organize["renameByName"].get(name) for name in names)
        if combine == "joinByField":
            assert transforms[0]["options"] == {"byField": "host_name", "mode": "outerTabular"}
    if dashboard == "home-assistant":
        boot = next(panel for panel in data["panels"] if panel["id"] == 6)
        assert boot.get("options", {}).get("colorMode") == "none", "boot age has no severity threshold"
    if dashboard == "home-assistant-apps":
        actual_rates = [(panel["id"], target["refId"]) for panel in data["panels"]
                        for target in panel["targets"] if "$__rate_interval" in target["expr"]]
        assert actual_rates == rate_targets, "cover every HA rate target"
        for panel, ref in actual_rates:
            target = next(target for item in data["panels"] if item["id"] == panel
                          for target in item["targets"] if target["refId"] == ref)
            assert target.get("interval") == "60s", (panel, ref, "Min step must match actual scrapes")
            for interval, expanded in [(1, "240s"), (15, "240s"), (300, "360s")]:
                assert "[" + expanded + "]" in expression(dashboard, panel, ref, interval)

extra_tests = []
for test in tests[:]:
    if "fixture_series" in test:
        tests.remove(test)
        extra_tests.append({"interval": "1m", "input_series": test.pop("fixture_series"), "promql_expr_test": [test]})
Path("contracts.json").write_text(json.dumps({
    # Prometheus extrapolation over the actual 4m window can differ from the
    # mathematical rate by one final mantissa bit. Use promtool's one-bit
    # comparison, retaining numeric rate/reset expectations and exact labels.
    "fuzzy_compare": True,
    "evaluation_interval": "1m", "tests": [{
        "interval": "1m", "input_series": series, "promql_expr_test": tests,
    }] + extra_tests,
}))
