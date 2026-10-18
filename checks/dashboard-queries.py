"""Execute dashboard expressions against asymmetric Prometheus data contracts."""
import json
import os
from pathlib import Path

dashboards = Path(os.environ["DASHBOARDS"])


def expression(dashboard, panel_id, ref="A"):
    data = json.loads((dashboards / (dashboard + ".json")).read_text())
    panel = next(panel for panel in data["panels"] if panel["id"] == panel_id)
    query = next(target["expr"] for target in panel["targets"] if target["refId"] == ref)
    for variable, value in {
        "${host:regex}": "alpha|beta", "${cluster:regex}": ".*",
        "${database:regex}": ".*", "${backup:regex}": ".*",
        "$__rate_interval": "2m", "$__range": "5m",
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


def check(dashboard, panel, samples, ref="A"):
    tests.append({"expr": expression(dashboard, panel, ref), "eval_time": "5m", "exp_samples": [
        {"labels": labels, "value": value} for labels, value in samples
    ]})


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
Path("contracts.json").write_text(json.dumps({
    "evaluation_interval": "1m", "tests": [{
        "interval": "1m", "input_series": series, "promql_expr_test": tests,
    }],
}))
