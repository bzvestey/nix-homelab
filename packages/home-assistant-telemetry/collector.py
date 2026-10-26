"""Allowlisted Supervisor v1 operational telemetry; no Core or Docker API access."""

from concurrent.futures import ThreadPoolExecutor
import base64
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import math
import os
import re
import socket
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit

from prometheus_client import CollectorRegistry, ProcessCollector, generate_latest
from prometheus_client.core import CounterMetricFamily, GaugeMetricFamily
from prometheus_client.parser import text_string_to_metric_families


# Explicit public metric families. Counter inputs are cumulative, not deltas.
RESOURCE_FIELDS = {
    "cpu_usage": ("cpu_seconds_total", "counter", 1e-9),
    "cpu_percent": ("cpu_percent", "gauge", 1),
    "memory_usage": ("memory_usage_bytes", "gauge", 1),
    "memory_limit": ("memory_limit_bytes", "gauge", 1),
    "memory_percent": ("memory_percent", "gauge", 1),
    "network_rx": ("network_receive_bytes_total", "counter", 1),
    "network_tx": ("network_transmit_bytes_total", "counter", 1),
    "blk_read": ("block_read_bytes_total", "counter", 1),
    "blk_write": ("block_write_bytes_total", "counter", 1),
}
STATES = {"started", "stopped", "starting", "stopping", "error", "unknown"}
SOURCES = ("inventory", "core_info", "core_stats", "supervisor_info",
           "supervisor_stats", "host", "os")
NATIVE = {"kuma": ("a0d7b954_uptime-kuma", 3001),
          "grafana": ("a0d7b954_grafana", 3000),
          "influxdb": ("a0d7b954_influxdb", 8086)}
UNSUPPORTED = {"tailscale": "a0d7b954_tailscale", "zwavejs2mqtt": "a0d7b954_zwavejs2mqtt",
               "matter": "core_matter_server", "otbr": "core_openthread_border_router",
               "vscode": "a0d7b954_vscode", "esphome": "5c53de3b_esphome",
               "esphome-dev": "5c53de3b_esphome-dev", "hacs": "cb646a50_get",
               "ssh": "a0d7b954_ssh"}
RUNTIME = {"process_cpu_seconds_total": "counter", "process_resident_memory_bytes": "gauge",
           "process_start_time_seconds": "gauge", "go_goroutines": "gauge",
           "go_memstats_alloc_bytes": "gauge"}
KUMA = {name: "gauge" for name in ("monitor_status", "monitor_response_time",
        "monitor_response_time_seconds", "monitor_uptime_ratio",
        "monitor_cert_days_remaining", "monitor_cert_is_valid")}


def native_rows(body, source):
    allowed = dict(KUMA if source == "kuma" else RUNTIME)
    if source == "grafana":
        allowed.update({"grafana_database_conn_" + suffix: "gauge"
                        for suffix in ("open", "idle", "in_use")})
    # The parser strips _total from counters. Resolve identity using the
    # expected contract, not the received type (which itself needs validation).
    counter_names = {name.removesuffix("_total"): name
                     for name, kind in allowed.items() if kind == "counter"}
    # Preserve declared identities too: an unrelated foo_total counter must
    # not be mistaken for an allowlisted foo gauge after parser normalization.
    declared_counters = set(re.findall(
        r"(?m)^\s*#\s+TYPE\s+([a-zA-Z_:][a-zA-Z0-9_:]*)\s+counter\s*$", body))
    series, rejected, recognized = {}, set(), False
    for family in text_string_to_metric_families(body):
        name = family.name
        if family.type == "counter" and name not in declared_counters:
            name += "_total"
        name = counter_names.get(name, name)
        if name not in allowed:
            continue
        recognized = recognized or bool(family.samples)
        try:
            if family.type != allowed[name]:
                raise ValueError("unexpected type")
            for sample in family.samples:
                if sample.name != name or not math.isfinite(sample.value):
                    raise ValueError("invalid sample")
                labels = {}
                value = sample.value
                if source == "kuma":
                    labels = {key: text(sample.labels[key]) for key in
                              ("monitor_id", "monitor_name", "monitor_type")}
                    if not re.fullmatch(r"[1-9][0-9]{0,19}", labels["monitor_id"]):
                        raise ValueError("invalid monitor identity")
                    if name in ("monitor_response_time_seconds", "monitor_uptime_ratio"):
                        window = sample.labels["window"]
                        if window not in ("1d", "30d", "365d"):
                            raise ValueError("invalid window")
                        labels["window"] = window
                    if (name == "monitor_status" and value not in (0, 1, 2, 3)
                            or name == "monitor_cert_is_valid" and value not in (0, 1)
                            or name == "monitor_uptime_ratio" and not 0 <= value <= 1):
                        raise ValueError("invalid monitor value")
                    if name == "monitor_response_time" and value == -1:
                        continue
                    if name != "monitor_cert_days_remaining" and value < 0:
                        raise ValueError("invalid negative value")
                elif sample.labels or value < 0:
                    raise ValueError("unexpected runtime dimensions")
                key = (name, tuple(sorted(labels.items())))
                if key in series and series[key] != value:
                    raise ValueError("conflicting series")
                series[key] = value
                if len(series) > 10000:
                    raise ValueError("too many series")
        except (ValueError, KeyError, TypeError):
            rejected.add(name)
    return [(name, value, dict(labels), allowed[name])
            for (name, labels), value in series.items() if name not in rejected], recognized and not rejected


def metric_families(rows):
    families = {}
    for name, value, labels, kind in rows:
        if name not in families:
            cls = CounterMetricFamily if kind == "counter" else GaugeMetricFamily
            families[name] = cls(name, name.replace("_", " "), labels=sorted(labels))
        families[name].add_metric([labels[key] for key in sorted(labels)], value)
    return families.values()


def text(value):
    if not isinstance(value, str) or not value or len(value) > 256:
        raise ValueError("invalid text field")
    return value


def number(value):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        raise ValueError("invalid numeric field")
    return value


def boolean(value):
    if type(value) is not bool:
        raise ValueError("invalid boolean field")
    return int(value)


def row(name, value, labels=None, kind="gauge"):
    return ("haos_" + name, number(value), labels or {}, kind)


def resource_rows(data, component, app=""):
    # These are fundamental to the verified stats contract; optional counters
    # and windowed percentages may be missing or null, never fabricated as zero.
    for field in ("cpu_usage", "memory_usage", "memory_limit"):
        number(data[field])
    return [row(name, number(data[field]) * scale,
                {"component": component, "app": app}, kind)
            for field, (name, kind, scale) in RESOURCE_FIELDS.items()
            if data.get(field) is not None]


def version_rows(data, component, app="", name=""):
    labels = {"component": component, "app": app}
    return [row("component_info", 1, dict(labels, name=name,
                 version=text(data["version"]), version_latest=text(data["version_latest"]))),
            row("update_available", boolean(data["update_available"]), labels)]


def inventory_rows(data):
    addons = data["addons"]
    if not isinstance(addons, list) or len(addons) > 256:
        raise ValueError("invalid inventory")
    result, seen = [], set()
    for app in addons:
        slug = text(app["slug"])
        if not re.fullmatch(r"[a-zA-Z0-9_-]{1,100}", slug) or slug in seen:
            raise ValueError("invalid slug")
        seen.add(slug)
        result.extend(version_rows(app, "app", slug, text(app["name"])))
        state = text(app["state"])
        result.append(row("app_state", 1, {"component": "app", "app": slug,
                                          "state": state if state in STATES else "unknown"}))
    return result


def supervisor_rows(data):
    result = version_rows(data, "supervisor")
    for field in ("healthy", "supported"):
        if data.get(field) is not None:
            result.append(row("supervisor_" + field, boolean(data[field])))
    return result


def host_rows(data):
    result = []
    for field in ("disk_total", "disk_used", "disk_free"):
        if data.get(field) is not None:
            result.append(row("host_" + field + "_bytes", number(data[field]) * 1024**3))
    if data.get("boot_timestamp") is not None and number(data["boot_timestamp"]) > 0:
        result.append(row("host_boot_completion_timestamp_seconds", data["boot_timestamp"] / 1e6))
    labels = {key: text(data[key]) for key in ("kernel", "operating_system")
              if data.get(key) is not None}
    if labels:
        result.append(row("host_info", 1, labels))
    return result


def os_rows(data):
    return [row("os_info", 1, {"version": text(data["version"]),
                              "version_latest": text(data["version_latest"])}),
            row("os_update_available", boolean(data["update_available"]))]


class Collector:
    """Own atomic per-source snapshots; a scrape never contacts an upstream."""

    def __init__(self, upstream, token, clock=time.time):
        self.upstream = urlsplit(upstream)
        if (self.upstream.scheme not in ("http", "https") or not self.upstream.hostname
                or self.upstream.username or self.upstream.password
                or self.upstream.path not in ("", "/") or self.upstream.query
                or self.upstream.fragment):
            raise ValueError("invalid Supervisor URL")
        if not isinstance(token, str) or not token.strip():
            raise ValueError("missing Supervisor token")
        self.token = token
        self.clock = clock
        self.lock = threading.Lock()
        self.running_apps = set()
        self.snapshots = {(source, ""): (False, 0, 0, 0, []) for source in SOURCES}
        self.native_options = {}
        self.native_snapshots = {source: (False, 0, 0, 0, []) for source in NATIVE}

    def configure_native(self, options):
        for source in NATIVE:
            if type(options.get("native_" + source, False)) is not bool:
                raise ValueError("invalid native setting")
        key = options.get("kuma_api_key", "")
        if (not isinstance(key, str) or len(key) > 4096
                or key and not re.fullmatch(r"uk[0-9]+_[A-Za-z0-9_-]+", key)):
            raise ValueError("invalid dedicated Kuma key")
        with self.lock:
            self.native_options = {"native_" + source: options.get("native_" + source, False)
                                   for source in NATIVE}
            self.native_options["kuma_api_key"] = key
            self.native_snapshots = {source: (False, 0, 0, 0, []) for source in NATIVE}

    def request_body(self, host, port, path, headers, secure=False):
        # A disposable process is the cancellation boundary, including DNS,
        # connect/TLS, send, and http.client's blocking status/header parser.
        # Credentials travel only over a private pipe, never argv or logs.
        deadline = time.monotonic() + 5
        transport = os.path.join(os.path.dirname(__file__), "transport.py")
        with subprocess.Popen([sys.executable, transport],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL) as worker:
            try:
                body, _ = worker.communicate(
                    json.dumps([host, port, path, headers, secure]).encode(),
                    timeout=max(0, deadline - time.monotonic()))
            except BaseException:
                worker.kill()
                worker.wait()
                raise
            if worker.returncode or time.monotonic() >= deadline:
                raise ValueError("upstream request failed")
            return body

    def fetch(self, path):
        envelope = json.loads(self.request_body(self.upstream.hostname, self.upstream.port,
                            path, {"Authorization": "Bearer " + self.token},
                            self.upstream.scheme == "https"))
        if envelope["result"] != "ok" or not isinstance(envelope["data"], dict):
            raise ValueError("Supervisor API failure")
        return envelope["data"]

    def native_status(self, source, options):
        if not options.get("native_" + source, False):
            return "disabled"
        if source == "kuma" and not options.get("kuma_api_key"):
            return "auth-required"
        return "enabled"

    def poll_native(self, source):
        slug, port = NATIVE[source]
        with self.lock:
            options = self.native_options
            expected = self.native_snapshots[source]
            if self.native_status(source, options) != "enabled" or slug not in self.running_apps:
                return
        start = time.monotonic()
        rows, success = [], False
        try:
            info = self.fetch("/addons/" + slug + "/info")
            if type(info["ip_address"]) is not str:
                raise ValueError("invalid app address type")
            address = ipaddress.ip_address(info["ip_address"])
            if (info["host_network"] is not False or address.version != 4
                    or not (address.is_private or address.is_loopback)
                    or address.is_unspecified or address.is_multicast or address.is_link_local):
                raise ValueError("invalid app network")
            headers = {}
            if source == "kuma":
                headers["Authorization"] = "Basic " + base64.b64encode(
                    (":" + options["kuma_api_key"]).encode()).decode()
            body = self.request_body(str(address), port, "/metrics", headers)
            rows, success = native_rows(body.decode("utf-8"), source)
        except Exception:
            pass
        completed = self.clock()
        with self.lock:
            if (self.native_snapshots[source] is not expected or options is not self.native_options
                    or slug not in self.running_apps):
                return
            self.native_snapshots[source] = (success, completed if success else expected[1],
                                            time.monotonic() - start, completed, rows)

    def poll_source(self, source, app, path, parser):
        start = time.monotonic()
        with self.lock:
            expected = self.snapshots.get((source, app))
            if source == "app_stats" and app not in self.running_apps:
                return None
        data, rows, success = None, [], False
        try:
            data = self.fetch(path)
            rows = parser(data)
            success = True
        except Exception:
            # Neither exception strings nor payloads are safe with manager access.
            # Publish failure metadata instead of logging upstream contents.
            data = None
        completed = self.clock()
        with self.lock:
            # An old in-flight reply cannot restore samples after membership
            # changed, inventory failed, or a newer app result was committed.
            if source == "app_stats" and (app not in self.running_apps
                    or self.snapshots.get((source, app)) is not expected):
                return None
            if source == "inventory":
                self.running_apps = {item["slug"] for item in data["addons"]
                                     if item["state"] == "started"} if data is not None else set()
                for native, (slug, _) in NATIVE.items():
                    if slug not in self.running_apps:
                        old = self.native_snapshots[native]
                        self.native_snapshots[native] = (False, old[1], old[2], 0, [])
                for key in list(self.snapshots):
                    if key[0] != "app_stats":
                        continue
                    if data is None:
                        old = self.snapshots[key]
                        self.snapshots[key] = (False, old[1], old[2], old[3], [])
                    elif key[1] not in self.running_apps:
                        del self.snapshots[key]
                for slug in self.running_apps:
                    self.snapshots.setdefault(("app_stats", slug), (False, 0, 0, completed, []))
                # Inventory and dependent membership become visible together.
            previous = self.snapshots.get((source, app), (False, 0, 0, 0, []))
            self.snapshots[(source, app)] = (success, completed if success else previous[1],
                                           time.monotonic() - start, completed, rows)
        return data

    def poll(self):
        inventory = self.poll_source("inventory", "", "/addons", inventory_rows)
        jobs = [
            ("core_info", "", "/core/info", lambda d: version_rows(d, "core")),
            ("core_stats", "", "/core/stats", lambda d: resource_rows(d, "core")),
            ("supervisor_info", "", "/supervisor/info", supervisor_rows),
            ("supervisor_stats", "", "/supervisor/stats", lambda d: resource_rows(d, "supervisor")),
            ("host", "", "/host/info", host_rows),
            ("os", "", "/os/info", os_rows),
        ]
        running = {app["slug"] for app in inventory["addons"] if app["state"] == "started"} if inventory else set()
        for slug in sorted(running):
            jobs.append(("app_stats", slug, "/addons/" + slug + "/stats",
                         lambda d, slug=slug: resource_rows(d, "app", slug)))
        with ThreadPoolExecutor(max_workers=4) as executor:
            list(executor.map(lambda job: self.poll_source(*job), jobs))
            list(executor.map(self.poll_native, NATIVE))

    def run(self):
        while True:
            start = time.monotonic()
            self.poll()
            time.sleep(max(0, 30 - (time.monotonic() - start)))

    def collect(self):
        with self.lock:
            snapshots = dict(self.snapshots)
            native = dict(self.native_snapshots)
            options = self.native_options
        rows = []
        now = self.clock()
        for source, slug in UNSUPPORTED.items():
            rows.append(row("native_source_status", 1, {"source": source, "app": slug,
                                                       "status": "unsupported"}))
        for source, (slug, _) in NATIVE.items():
            status = self.native_status(source, options)
            success, last, duration, completed, _ = native[source]
            fresh = success and 0 <= now - completed < 90
            rows.append(row("native_source_status", 1, {"source": source, "app": slug,
                        "status": status if status != "enabled" or fresh else "failing"}))
            labels = {"source": "native_" + source, "app": slug}
            rows.extend([row("collection_success", int(fresh), labels),
                         row("collection_last_success_timestamp_seconds", last, labels),
                         row("collection_duration_seconds", duration, labels)])
        for (source, app), (success, last_success, duration, completed, operational) in snapshots.items():
            fresh = success and 0 <= now - completed < 90
            labels = {"source": source, "app": app}
            rows.extend([row("collection_success", int(fresh), labels),
                         row("collection_last_success_timestamp_seconds", last_success, labels),
                         row("collection_duration_seconds", duration, labels)])
            if fresh:
                rows.extend(operational)
        families = {}
        for name, value, labels, kind in rows:
            if name not in families:
                cls = CounterMetricFamily if kind == "counter" else GaugeMetricFamily
                families[name] = cls(name, name.removeprefix("haos_").replace("_", " "), labels=sorted(labels))
            families[name].add_metric([labels[key] for key in sorted(labels)], value)
        yield from families.values()

    def collect_native(self, source):
        with self.lock:
            _, _, _, completed, rows = self.native_snapshots[source]
        # Rejected families are absent, while independently valid families remain.
        if 0 <= self.clock() - completed < 90:
            yield from metric_families(rows)


def make_server(collector, metrics_token, host="0.0.0.0", port=9126):
    if not isinstance(metrics_token, str) or not metrics_token.strip():
        raise ValueError("missing metrics token")
    expected = ("Bearer " + metrics_token).encode()
    registry = CollectorRegistry()
    registry.register(collector)
    ProcessCollector(namespace="haos_collector", registry=registry)

    class Server(ThreadingHTTPServer):
        def __init__(self, *args):
            self.clients = threading.BoundedSemaphore(16)
            super().__init__(*args)

        def process_request(self, request, client_address):
            # Admission happens before allocating either a handler or timer.
            if not self.clients.acquire(blocking=False):
                self.shutdown_request(request)
                return

            def expire():
                try:
                    request.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

            timer = threading.Timer(5, expire)
            timer.daemon = True

            def serve():
                try:
                    self.process_request_thread(request, client_address)
                finally:
                    timer.cancel()
                    timer.join()
                    self.clients.release()

            try:
                request.settimeout(5)
                timer.start()
                threading.Thread(target=serve, daemon=True).start()
            except BaseException:
                timer.cancel()
                if timer.ident is not None:
                    timer.join()
                self.shutdown_request(request)
                self.clients.release()
                raise

        def handle_error(self, request, client_address):
            # Disconnects/deadlines are expected; parser errors can contain URLs.
            pass

    class Handler(BaseHTTPRequestHandler):
        def handle_request(self):
            authorization = self.headers.get("Authorization", "").encode()
            if not hmac.compare_digest(authorization, expected):
                status, body = 401, b"Unauthorized\n"
            elif self.command != "GET":
                status, body = 405, b"Method not allowed\n"
            elif self.path not in ("/metrics", *("/metrics/" + source for source in NATIVE)):
                status, body = 404, b"Not found\n"
            else:
                if self.path == "/metrics":
                    output_registry = registry
                else:
                    source = self.path.removeprefix("/metrics/")
                    class NativeCollector:
                        def collect(self):
                            return collector.collect_native(source)
                    output_registry = CollectorRegistry()
                    output_registry.register(NativeCollector())
                status, body = 200, generate_latest(output_registry)
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            if status == 401:
                self.send_header("WWW-Authenticate", "Bearer")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            self.close_connection = True

        def __getattr__(self, name):
            # Authenticate even unknown HTTP methods before rejecting them.
            if name.startswith("do_"):
                return self.handle_request
            raise AttributeError(name)

        def log_message(self, *args):
            # URLs can also contain secrets; do not emit access logs.
            pass

    return Server((host, port), Handler)


def main():
    try:
        with open(os.environ.get("OPTIONS_PATH", "/data/options.json")) as handle:
            options = json.load(handle)
        collector = Collector(os.environ.get("SUPERVISOR_URL", "http://supervisor"),
                              os.environ.get("SUPERVISOR_TOKEN"))
        collector.configure_native(options)
        server = make_server(collector, options.get("metrics_token"),
                             port=int(os.environ.get("METRICS_PORT", "9126")))
    except Exception:
        print("Collector configuration invalid; check private local options and token", file=sys.stderr)
        return 1
    threading.Thread(target=collector.run, daemon=True).start()
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
