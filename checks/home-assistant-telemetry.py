"""Operational collector contract; run with the locked Nix Python environment."""

import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from prometheus_client.parser import text_string_to_metric_families


ROOT = Path(__file__).resolve().parents[1]
COLLECTOR = ROOT / "packages/home-assistant-telemetry/collector.py"
SECRET = "SENSITIVE_FIXTURE_ONLY"
PRIVATE = "PRIVATE_FIXTURE_ENTITY"


def stats(memory=123456789, rx=1111111):
    return dict(cpu_usage=12345678901, cpu_percent=123.45,
                memory_usage=memory, memory_limit=987654321,
                memory_percent=12.5, network_rx=rx, network_tx=2222222,
                blk_read=3333333, blk_write=4444444, options={"token": SECRET},
                entity_state=PRIVATE)


def inventory(slug, state="started"):
    return dict(slug=slug, name="Fixture " + slug, version="1.2.3",
                version_latest="1.2.4", update_available=True, state=state,
                options={"password": SECRET}, entity_state=PRIVATE)


class Fixture:
    def __init__(self):
        info = dict(version="2026.10.3", version_latest="2026.10.4",
                    update_available=True, options={"token": SECRET})
        self.data = {
            "/addons": {"addons": [inventory("alpha"), inventory("beta"),
                                    inventory("once", "stopped")]},
            "/core/info": copy.deepcopy(info),
            "/supervisor/info": dict(info, healthy=True, supported=False),
            "/os/info": dict(info, data_disk=PRIVATE),
            "/host/info": dict(disk_total=123.4, disk_used=45.6, disk_free=70.1,
                               boot_timestamp=1700000123456789,
                               kernel="fixture-kernel", operating_system="Fixture OS"),
            "/core/stats": stats(321, 444),
            "/supervisor/stats": stats(654, 777),
            "/addons/alpha/stats": stats(),
            "/addons/beta/stats": stats(333333333, 7654321),
        }
        self.fail = {}
        self.gates = {}
        self.calls = []
        self.active = self.peak = 0
        self.lock = threading.Lock()
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                with fixture.lock:
                    fixture.calls.append((self.command, self.path,
                                          self.headers.get("Authorization")))
                    fixture.active += 1
                    fixture.peak = max(fixture.peak, fixture.active)
                try:
                    mode = fixture.fail.get(self.path)
                    if gate := fixture.gates.get(self.path):
                        entered, release = gate
                        entered.set()
                        release.wait(4)
                    if mode == "timeout":
                        time.sleep(5.3)
                    if mode == "slow-headers":
                        self.connection.sendall(b"HTTP/1.1 200 OK\r\nX-Slow: ")
                        try:
                            for _ in range(32):
                                self.connection.sendall(b"x")
                                time.sleep(.25)
                            self.connection.sendall(b"\r\nContent-Length: 0\r\n\r\n")
                        except OSError:
                            pass
                        return
                    if mode == "redirect":
                        self.send_response(302)
                        self.send_header("Location", fixture.url + "/credential-trap")
                        self.end_headers()
                        return
                    if mode == "error":
                        body = json.dumps({"result": "error", "message": SECRET}).encode()
                    elif mode == "oversize":
                        body = b" " * (1024 * 1024 + 1)
                    elif mode == "invalid-json":
                        body = SECRET.encode()
                    else:
                        body = json.dumps({"result": "ok", "data": fixture.data.get(self.path)}).encode()
                    self.send_response(200)
                    self.end_headers()
                    with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                        self.wfile.write(body)
                finally:
                    with fixture.lock:
                        fixture.active -= 1

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%s" % self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


def request(url, token="metrics-fixture", method="GET", path="/metrics"):
    headers = {} if token is None else {"Authorization": "Bearer " + token}
    try:
        response = urlopen(Request(url + path, headers=headers, method=method), timeout=3)
    except HTTPError as error:
        response = error
    with response:
        return response.status, response.read().decode()


def samples(body):
    return {(sample.name, tuple(sorted(sample.labels.items()))): sample.value
            for family in text_string_to_metric_families(body) for sample in family.samples}


class NativeFixture:
    def __init__(self, port):
        self.body = ""
        self.status = 200
        self.calls = []
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                fixture.calls.append((self.path, self.headers.get("Authorization")))
                self.send_response(fixture.status)
                if fixture.status == 302:
                    self.send_header("Location", "http://127.0.0.1:3000/trap")
                self.end_headers()
                self.wfile.write(fixture.body.encode())

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class Contract(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.close)
        # Establish fixture reachability before asserting missing production behavior.
        with urlopen(self.fixture.url + "/core/stats") as response:
            self.assertEqual(json.load(response)["result"], "ok")
        self.assertTrue(COLLECTOR.exists(), "collector behavior is missing (fixture is reachable)")
        spec = importlib.util.spec_from_file_location("collector", COLLECTOR)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.now = 1700000200.0
        self.collector = self.module.Collector(self.fixture.url, "supervisor-fixture",
                                               clock=lambda: self.now)
        self.server = self.module.make_server(self.collector, "metrics-fixture", "127.0.0.1", 0)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = "http://127.0.0.1:%s" % self.server.server_port

    def scrape(self):
        status, body = request(self.url)
        self.assertEqual(status, 200)
        self.body = body
        return samples(body)

    def value(self, data, name, **labels):
        return data[(name, tuple(sorted(labels.items())))]

    def native_setup(self, source="kuma", key="uk17_fixture"):
        ports = {"kuma": 3001, "grafana": 3000, "influxdb": 8086}
        native = NativeFixture(ports[source])
        self.addCleanup(native.close)
        slug = "a0d7b954_" + ("uptime-kuma" if source == "kuma" else source)
        self.fixture.data["/addons"]["addons"].append(inventory(slug))
        self.fixture.data["/addons/" + slug + "/stats"] = stats()
        self.fixture.data["/addons/" + slug + "/info"] = {
            "ip_address": "127.0.0.1", "host_network": False, "options": SECRET}
        self.collector.configure_native({"native_" + source: True, "kuma_api_key": key})
        return native, slug

    def native_scrape(self, source):
        status, body = request(self.url, path="/metrics/" + source)
        self.assertEqual(status, 200)
        for private in (SECRET, PRIVATE, "Productivity", "private.invalid", "uk17_fixture"):
            self.assertNotIn(private, body)
        promtool = os.environ.get("PROMTOOL", "promtool")
        result = subprocess.run([promtool, "check", "metrics"], input=body,
                                text=True, capture_output=True)
        # Preserve the source-verified family/unit rather than rename it to
        # silence promtool's base-unit naming lint. All other lint stays strict.
        if source == "kuma" and "monitor_cert_days_remaining" in body:
            self.assertEqual(result.returncode, 3)
            self.assertEqual(result.stdout + result.stderr,
                             'monitor_cert_days_remaining use base unit "seconds" instead of "days"\n')
        else:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return body, samples(body)

    def kuma_metric(self, name, value, extra="", identity=True):
        labels = 'monitor_id="17",monitor_name="Synthetic service",monitor_type="http"' if identity else 'monitor_name="Synthetic service"'
        return (f"# HELP {name} {SECRET}\n# TYPE {name} gauge\n"
                f'{name}{{{labels}{extra}}} {value}\n')

    def test_native_kuma_privacy_units_windows_and_auth(self):
        native, slug = self.native_setup()
        native.body = "".join(self.kuma_metric(name, value, extra) for name, value, extra in (
            ("monitor_status", 2, ',Productivity="PRIVATE_FIXTURE_ENTITY",monitor_url="https://private.invalid"'),
            ("monitor_response_time", 123, ""),
            ("monitor_response_time_seconds", .456, ',window="30d"'),
            ("monitor_uptime_ratio", .987, ',window="365d"'),
            ("monitor_cert_days_remaining", -2, ""),
            ("monitor_cert_is_valid", 0, ""),
            ("sensor_private", 99, ',entity_id="PRIVATE_FIXTURE_ENTITY"')))
        self.collector.poll()
        body, data = self.native_scrape("kuma")
        self.assertEqual(len(data), 6)
        self.assertIn(" 123.0", body)
        self.assertIn(" -2.0", body)
        self.assertNotIn("sensor_private", body)
        self.assertEqual(native.calls, [("/metrics", "Basic OnVrMTdfZml4dHVyZQ==")])
        self.assertEqual(request(self.url, None, path="/metrics/kuma")[0], 401)
        self.assertEqual(request(self.url, path="/metrics/kuma?target=evil")[0], 404)
        self.now += 89
        self.assertEqual(len(self.native_scrape("kuma")[1]), 6)
        self.now += 1
        self.assertEqual(self.native_scrape("kuma")[1], {})

    def test_native_fail_closed_filter_and_healthy_control(self):
        native, slug = self.native_setup()
        for body in (self.kuma_metric("monitor_status", 1, identity=False),
                     self.kuma_metric("monitor_uptime_ratio", .5, ',window="2d"'),
                     self.kuma_metric("monitor_uptime_ratio", 1.5, ',window="1d"'),
                     self.kuma_metric("monitor_status", 9),
                     self.kuma_metric("monitor_response_time", -2),
                     self.kuma_metric("monitor_status", 1).replace("Synthetic service", "x" * 257),
                     self.kuma_metric("monitor_cert_is_valid", "NaN")):
            with self.subTest(body=body):
                native.body = body
                self.collector.poll()
                self.assertEqual(self.native_scrape("kuma")[1], {})
                data = self.scrape()
                self.assertEqual(self.value(data, "haos_collection_success", source="native_kuma", app=slug), 0)
                self.assertEqual(self.value(data, "haos_memory_usage_bytes", component="core", app=""), 321)
        native.body = self.kuma_metric("monitor_response_time", -1)
        self.collector.poll()
        self.assertEqual(self.native_scrape("kuma")[1], {})
        self.assertEqual(self.value(self.scrape(), "haos_collection_success", source="native_kuma", app=slug), 1)

    def test_native_review_wrong_counter_type_rejects_approved_gauge(self):
        for source, name in (("grafana", "go_goroutines"), ("kuma", "monitor_status")):
            native, slug = self.native_setup(source)
            if source == "kuma":
                good = self.kuma_metric("monitor_cert_is_valid", 1)
                bad = self.kuma_metric(name, 1).replace(" gauge\n", " counter\n")
                expected = "monitor_cert_is_valid"
            else:
                good = ("# TYPE process_resident_memory_bytes gauge\n"
                        "process_resident_memory_bytes 42\n"
                        "# TYPE process_cpu_seconds_total counter\n"
                        "process_cpu_seconds_total 3\n")
                bad = f"# TYPE {name} counter\n{name} 7\n"
                bad += f"# TYPE {name}_total counter\n{name}_total 123\n"
                expected = "process_resident_memory_bytes"
            native.body = good + bad
            self.collector.poll()
            body, data = self.native_scrape(source)
            self.assertNotIn(name, body)
            self.assertIn(expected, body)
            if source == "grafana":
                self.assertEqual(self.value(data, "process_cpu_seconds_total"), 3)
            platform = self.scrape()
            self.assertEqual(self.value(platform, "haos_collection_success", source="native_" + source, app=slug), 0)
            self.assertEqual(self.value(platform, "haos_memory_usage_bytes", component="core", app=""), 321)
            self.now += 89
            self.assertIn(expected, self.native_scrape(source)[0])
            self.now += 1
            self.assertEqual(self.native_scrape(source)[1], {})

    def test_native_review_nonstring_address_never_reaches_app(self):
        native, slug = self.native_setup()
        native.body = self.kuma_metric("monitor_status", 1)
        self.collector.poll()
        self.assertTrue(self.native_scrape("kuma")[1])
        self.assertEqual(native.calls, [("/metrics", "Basic OnVrMTdfZml4dHVyZQ==")])
        last_success = self.now
        for invalid in (2130706433, True, False, None, [], {}, 2130706433.0):
            with self.subTest(address=invalid):
                self.fixture.data["/addons/" + slug + "/info"]["ip_address"] = invalid
                self.now += 1
                self.collector.poll()
                self.assertEqual(len(native.calls), 1, "malformed info reached app transport")
                self.assertEqual(self.native_scrape("kuma")[1], {})
                data = self.scrape()
                self.assertEqual(self.value(data, "haos_collection_success", source="native_kuma", app=slug), 0)
                self.assertEqual(self.value(data, "haos_collection_last_success_timestamp_seconds", source="native_kuma", app=slug), last_success)

    def test_native_empty_unsupported_malformed_and_oversize_responses(self):
        native, slug = self.native_setup()
        for body in ("", "# TYPE unknown_sensor gauge\nunknown_sensor 1\n",
                     "not prometheus !\n", " " * (1048576 + 1)):
            with self.subTest(length=len(body)):
                native.body = body
                self.collector.poll()
                self.assertEqual(self.native_scrape("kuma")[1], {})
                self.assertEqual(self.value(self.scrape(), "haos_collection_success", source="native_kuma", app=slug), 0)

    def test_native_inventory_failure_invalidates_inflight_and_reconfiguration(self):
        native, slug = self.native_setup()
        native.body = self.kuma_metric("monitor_status", 1)
        self.collector.poll()
        entered, release = threading.Event(), threading.Event()
        self.fixture.gates["/addons/" + slug + "/info"] = (entered, release)
        worker = threading.Thread(target=self.collector.poll_native, args=("kuma",))
        worker.start()
        try:
            self.assertTrue(entered.wait(2))
            self.fixture.fail["/addons"] = "error"
            self.collector.poll()
            self.assertEqual(self.native_scrape("kuma")[1], {})
        finally:
            release.set()
            worker.join(6)
        self.assertFalse(worker.is_alive())
        self.assertEqual(self.native_scrape("kuma")[1], {})
        self.fixture.fail.clear()
        self.fixture.gates.clear()
        self.collector.poll()
        self.assertTrue(self.native_scrape("kuma")[1])
        self.collector.configure_native({})
        self.assertEqual(self.native_scrape("kuma")[1], {})
        calls = len(native.calls)
        self.collector.poll()
        self.assertEqual(len(native.calls), calls)

    def test_native_collisions_equal_conflicting(self):
        native, slug = self.native_setup()
        for second, expected in ((1, 1), (0, 0)):
            native.body = (self.kuma_metric("monitor_status", 1, ',tag="a"') +
                           self.kuma_metric("monitor_status", second, ',tag="b"') +
                           self.kuma_metric("monitor_cert_is_valid", 1))
            self.collector.poll()
            body, data = self.native_scrape("kuma")
            self.assertEqual("monitor_status" in body, bool(expected))
            self.assertIn("monitor_cert_is_valid", body)
            self.assertEqual(self.value(self.scrape(), "haos_collection_success", source="native_kuma", app=slug), expected)

    def test_native_redirect_401_and_metadata_validation(self):
        native, slug = self.native_setup()
        trap = NativeFixture(3000)
        self.addCleanup(trap.close)
        for status in (302, 401):
            native.status = status
            self.collector.poll()
            self.assertEqual(self.native_scrape("kuma")[1], {})
            self.assertEqual(self.value(self.scrape(), "haos_collection_success", source="native_kuma", app=slug), 0)
        self.assertEqual(trap.calls, [])
        count = len(native.calls)
        for invalid in ({"ip_address": "evil.invalid", "host_network": False},
                        {"ip_address": "8.8.8.8", "host_network": False},
                        {"ip_address": "127.0.0.1", "host_network": True}):
            self.fixture.data["/addons/" + slug + "/info"] = invalid
            self.collector.poll()
        self.assertEqual(len(native.calls), count)

    def test_native_runtime_label_free_and_coverage(self):
        data = self.scrape()
        self.assertEqual(self.value(data, "haos_native_source_status", source="grafana", app="a0d7b954_grafana", status="disabled"), 1)
        self.assertEqual(self.value(data, "haos_native_source_status", source="tailscale", app="a0d7b954_tailscale", status="unsupported"), 1)
        self.collector.configure_native({"native_kuma": True})
        self.assertEqual(self.value(self.scrape(), "haos_native_source_status", source="kuma", app="a0d7b954_uptime-kuma", status="auth-required"), 1)
        for source in ("grafana", "influxdb"):
            native, slug = self.native_setup(source)
            names = ["process_cpu_seconds_total", "process_resident_memory_bytes",
                     "process_start_time_seconds", "go_goroutines", "go_memstats_alloc_bytes"]
            if source == "grafana":
                names += ["grafana_database_conn_open", "grafana_database_conn_idle", "grafana_database_conn_in_use"]
            native.body = "".join(f'# HELP {name} {SECRET}\n# TYPE {name} {"counter" if name.endswith("_total") else "gauge"}\n{name} 7\n' for name in names)
            native.body += ('# TYPE go_memstats_alloc_bytes_total counter\n'
                            'go_memstats_alloc_bytes_total 123456\n')
            native.body += f'unknown_sensor{{entity_id="{PRIVATE}"}} 99\n'
            native.body += ('# TYPE grafana_http_request_duration_seconds histogram\n'
                            f'grafana_http_request_duration_seconds_bucket{{handler="{PRIVATE}",le="+Inf"}} 9\n')
            self.collector.poll()
            body, data = self.native_scrape(source)
            self.assertEqual(len(data), len(names))
            self.assertEqual(self.value(data, "go_memstats_alloc_bytes"), 7)
            self.assertTrue(all(not labels for _, labels in data))
            self.assertNotIn("grafana_http", body)
            self.assertEqual(self.value(self.scrape(), "haos_native_source_status", source=source, app=slug, status="enabled"), 1)
            self.assertEqual(native.calls[-1], ("/metrics", None))
            native.body = '# TYPE go_goroutines gauge\ngo_goroutines{secret="SENSITIVE_FIXTURE_ONLY"} 4\n'
            self.collector.poll()
            self.assertEqual(self.native_scrape(source)[1], {})
            self.assertEqual(self.value(self.scrape(), "haos_collection_success", source="native_" + source, app=slug), 0)

    def test_authentication_routes_and_no_management_writes(self):
        self.collector.poll()
        before = len(self.fixture.calls)
        for token in (None, "wrong"):
            self.assertEqual(request(self.url, token)[0], 401)
            self.assertEqual(request(self.url, token, path="/unknown")[0], 401)
        self.assertEqual(request(self.url, path="/unknown")[0], 404)
        for method in ("POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS", "TRACE", "CONNECT", "BREW"):
            self.assertEqual(request(self.url, method=method)[0], 405)
            self.assertEqual(request(self.url, None, method=method)[0], 401)
        self.assertEqual(request(self.url)[0], 200)
        self.assertEqual(len(self.fixture.calls), before)

    def test_transport_slow_headers_deadline_and_poll_recovery(self):
        self.fixture.fail["/core/stats"] = "slow-headers"
        start = time.monotonic()
        self.collector.poll()
        elapsed = time.monotonic() - start
        print(f"slow-header poll completed in {elapsed:.3f}s", flush=True)
        self.assertLess(elapsed, 6.5)
        self.assertGreater(elapsed, 4.5)
        data = self.scrape()
        self.assertEqual(self.value(data, "haos_collection_success", source="core_stats", app=""), 0)
        self.assertEqual(self.value(data, "haos_memory_usage_bytes", component="supervisor", app=""), 654)
        # The upstream observes disconnect, not just a timed-out Future.
        until = time.monotonic() + 1
        while self.fixture.active and time.monotonic() < until:
            time.sleep(.05)
        self.assertEqual(self.fixture.active, 0)
        self.fixture.fail.clear()
        start = time.monotonic()
        self.collector.poll()
        recovered = time.monotonic() - start
        print(f"next healthy poll completed in {recovered:.3f}s", flush=True)
        self.assertLess(recovered, 3)
        self.assertEqual(self.value(self.scrape(), "haos_collection_success", source="core_stats", app=""), 1)

    def test_transport_idle_partial_and_drip_clients_are_bounded(self):
        clients = []
        stop = threading.Event()
        def drip(client):
            while not stop.wait(.2):
                try:
                    client.sendall(b"x")
                except OSError:
                    return
        try:
            start = time.monotonic()
            for index in range(48):
                client = socket.create_connection(self.server.server_address, timeout=1)
                clients.append(client)
                if index % 3:
                    with contextlib.suppress(OSError):
                        client.sendall(b"GET /metrics HTTP/1.1\r\nX-Slow: ")
                if index % 3 == 2:
                    threading.Thread(target=drip, args=(client,), daemon=True).start()
                time.sleep(.01)
            def closed(client):
                client.settimeout(.01)
                try:
                    return client.recv(1) == b""
                except (ConnectionResetError, BrokenPipeError):
                    return True
                except socket.timeout:
                    return False
            retained = sum(not closed(client) for client in clients)
            print(f"idle/partial clients retained: {retained}/48", flush=True)
            self.assertLessEqual(retained, 16)
            # Free one admitted slot; an authenticated scrape must work even
            # while the other unauthenticated slots remain occupied.
            clients[0].close()
            time.sleep(.1)
            self.assertEqual(request(self.url)[0], 200)
            time.sleep(max(0, start + 5.8 - time.monotonic()))
            self.assertTrue(all(closed(client) for client in clients[1:]))
            print(f"all idle/partial/drip clients closed by {time.monotonic() - start:.3f}s", flush=True)
            self.assertEqual(request(self.url)[0], 200)
            self.assertEqual(request(self.url, None)[0], 401)
        finally:
            stop.set()
            for client in clients:
                client.close()

    def test_transport_nonreading_response_clients_release_capacity(self):
        # Synthetic large exposition forces real sendall backpressure even on
        # loopback. No transport or HTTP parser is replaced.
        from prometheus_client.core import GaugeMetricFamily
        class LargeCollector:
            def collect(self):
                family = GaugeMetricFamily("fixture_large", "Synthetic response", labels=["item"])
                for index in range(20000):
                    family.add_metric([str(index) + "x" * 256], 1)
                yield family

            def collect_native(self, source):
                return iter(())

        server = self.module.make_server(LargeCollector(), "metrics-fixture", "127.0.0.1", 0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        clients = []
        try:
            start = time.monotonic()
            for _ in range(16):
                client = socket.socket()
                client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                client.settimeout(1)
                client.connect(server.server_address)
                client.sendall(b"GET /metrics HTTP/1.1\r\nHost: fixture\r\n"
                               b"Authorization: Bearer metrics-fixture\r\n\r\n")
                clients.append(client)
                time.sleep(.02)
            url = "http://127.0.0.1:%s" % server.server_port
            with self.assertRaises(OSError):
                request(url, path="/metrics/grafana")
            time.sleep(max(0, start + 6 - time.monotonic()))
            # Peers still hold open their sockets and have read no response.
            # Successful new work proves blocked sends relinquish admission.
            self.assertEqual(request(url, path="/metrics/grafana")[0], 200)
            print(f"nonreading response clients: authenticated recovery at {time.monotonic() - start:.3f}s", flush=True)
        finally:
            for client in clients:
                client.close()
            server.shutdown()
            server.server_close()
            thread.join()

    def test_resource_units_types_and_privacy(self):
        self.collector.poll()
        data = self.scrape()
        expected = {
            "cpu_seconds_total": 12.345678901, "cpu_percent": 123.45,
            "memory_usage_bytes": 123456789, "memory_limit_bytes": 987654321,
            "memory_percent": 12.5, "network_receive_bytes_total": 1111111,
            "network_transmit_bytes_total": 2222222,
            "block_read_bytes_total": 3333333, "block_write_bytes_total": 4444444,
        }
        for suffix, value in expected.items():
            self.assertAlmostEqual(self.value(data, "haos_" + suffix,
                                             component="app", app="alpha"), value)
        for component, app, memory, rx in (("app", "beta", 333333333, 7654321),
                                          ("core", "", 321, 444),
                                          ("supervisor", "", 654, 777)):
            self.assertEqual(self.value(data, "haos_memory_usage_bytes", component=component, app=app), memory)
            self.assertEqual(self.value(data, "haos_network_receive_bytes_total", component=component, app=app), rx)
        for name, value in (("disk_total_bytes", 132499741081.6),
                            ("disk_used_bytes", 48962627174.4),
                            ("disk_free_bytes", 75269301862.4),
                            ("boot_completion_timestamp_seconds", 1700000123.456789)):
            self.assertAlmostEqual(self.value(data, "haos_host_" + name), value)
        self.assertEqual(self.value(data, "haos_supervisor_healthy"), 1)
        self.assertEqual(self.value(data, "haos_supervisor_supported"), 0)
        self.assertIn('version="2026.10.3"', self.body)
        self.assertNotIn('component="core",state=', self.body)
        self.assertNotIn('component="supervisor",state=', self.body)
        for secret in (SECRET, PRIVATE, "supervisor-fixture", "metrics-fixture", "options", "entity_state"):
            self.assertNotIn(secret, self.body)
        families = {f.name: f.type for f in text_string_to_metric_families(self.body)}
        self.assertEqual(families["haos_cpu_seconds"], "counter")
        self.assertEqual(families["haos_memory_usage_bytes"], "gauge")
        self.assertLessEqual(self.fixture.peak, 4)
        self.assertTrue(all(method == "GET" for method, _, _ in self.fixture.calls))
        self.assertTrue(all(auth == "Bearer supervisor-fixture" for _, _, auth in self.fixture.calls[1:]))
        if os.environ.get("METRICS_OUTPUT"):
            Path(os.environ["METRICS_OUTPUT"]).write_text(self.body)

    def test_stopped_removed_and_new_apps(self):
        self.collector.poll()
        data = self.scrape()
        self.assertEqual(self.value(data, "haos_app_state", component="app", app="once", state="stopped"), 1)
        self.assertNotIn("/addons/once/stats", [p for _, p, _ in self.fixture.calls])
        self.assertNotIn(("haos_memory_usage_bytes", (("app", "once"), ("component", "app"))), data)
        self.fixture.data["/addons"]["addons"] = [inventory("beta", "stopped"), inventory("new")]
        self.fixture.data["/addons/new/stats"] = stats(12, 34)
        self.collector.poll()
        self.scrape()
        self.assertNotIn('app="alpha"', self.body)
        self.assertNotIn('app="once"', self.body)
        self.assertEqual(self.value(samples(self.body), "haos_memory_usage_bytes", component="app", app="new"), 12)
        self.assertNotIn('haos_memory_usage_bytes{app="beta"', self.body)

    def test_timeout_isolated_and_failure_clears_samples(self):
        self.collector.poll()
        self.now += 30
        self.fixture.fail["/addons/alpha/stats"] = "timeout"
        self.fixture.data["/addons/beta/stats"]["memory_usage"] = 42
        start = time.monotonic()
        self.collector.poll()
        self.assertLess(time.monotonic() - start, 6.5)
        data = self.scrape()
        self.assertEqual(self.value(data, "haos_collection_success", source="app_stats", app="alpha"), 0)
        self.assertEqual(self.value(data, "haos_collection_last_success_timestamp_seconds", source="app_stats", app="alpha"), 1700000200)
        self.assertEqual(self.value(data, "haos_memory_usage_bytes", component="app", app="beta"), 42)
        self.assertNotIn(("haos_memory_usage_bytes", (("app", "alpha"), ("component", "app"))), data)

    def test_inventory_failure_is_unknown_not_zero(self):
        self.collector.poll()
        self.fixture.fail["/addons"] = "error"
        self.collector.poll()
        data = self.scrape()
        self.assertEqual(self.value(data, "haos_collection_success", source="inventory", app=""), 0)
        self.assertNotIn("haos_app_state", self.body)
        self.assertNotIn("haos_app_count", self.body)
        self.assertIn("haos_memory_usage_bytes", self.body)

    def test_inventory_publication_and_inflight_app_results_are_consistent(self):
        # A line trace controls scheduling only: no parser/client is replaced,
        # and every consistency assertion reads the authenticated HTTP contract.
        for transition in ("failure", "lifecycle"):
            with self.subTest(transition=transition):
                self.fixture.fail.clear()
                self.fixture.gates.clear()
                self.fixture.data["/addons"]["addons"] = [inventory("alpha"), inventory("beta")]
                self.collector.poll()
                gates = {slug: (threading.Event(), threading.Event()) for slug in ("alpha", "beta")}
                self.fixture.gates.update({"/addons/" + slug + "/stats": gate
                                           for slug, gate in gates.items()})
                old_poll = threading.Thread(target=self.collector.poll)
                published, resume = threading.Event(), threading.Event()

                def trace(frame, event, arg):
                    if (event == "line" and frame.f_code.co_filename == str(COLLECTOR)
                            and frame.f_code.co_name == "poll" and "inventory" in frame.f_locals
                            and not published.is_set()):
                        published.set()
                        resume.wait(4)
                    return trace

                def publish_inventory():
                    sys.settrace(trace)
                    try:
                        self.collector.poll()
                    finally:
                        sys.settrace(None)

                new_poll = threading.Thread(target=publish_inventory)

                def assert_membership():
                    data = self.scrape()
                    self.assertEqual(self.value(data, "haos_collection_success", source="inventory", app=""),
                                     0 if transition == "failure" else 1)
                    for slug in ("alpha", "beta"):
                        self.assertNotIn(("haos_memory_usage_bytes", (("app", slug), ("component", "app"))), data)
                        key = ("haos_collection_success", (("app", slug), ("source", "app_stats")))
                        if transition == "failure":
                            self.assertEqual(data[key], 0)
                        else:
                            self.assertNotIn(key, data)
                    if transition == "lifecycle":
                        self.assertNotIn('app="alpha"', self.body)
                        self.assertEqual(self.value(data, "haos_app_state", component="app", app="beta", state="stopped"), 1)
                        self.assertEqual(self.value(data, "haos_app_state", component="app", app="new", state="started"), 1)
                        self.assertEqual(self.value(data, "haos_collection_success", source="app_stats", app="new"), 0)
                        self.assertNotIn(("haos_memory_usage_bytes", (("app", "new"), ("component", "app"))), data)
                    self.assertEqual(self.value(data, "haos_memory_usage_bytes", component="core", app=""), 321)

                old_poll.start()
                try:
                    for entered, _ in gates.values():
                        self.assertTrue(entered.wait(2), "old app request did not enter the HTTP fixture")
                    if transition == "failure":
                        self.fixture.fail["/addons"] = "error"
                    else:
                        self.fixture.data["/addons"]["addons"] = [inventory("beta", "stopped"), inventory("new")]
                        self.fixture.data["/addons/new/stats"] = stats(12, 34)
                    new_poll.start()
                    self.assertTrue(published.wait(2), "inventory poll did not reach publication boundary")
                    assert_membership()
                    for _, release in gates.values():
                        release.set()
                    old_poll.join(2)
                    self.assertFalse(old_poll.is_alive(), "old app requests did not finish")
                    # Late replies from the old membership cannot resurrect usage.
                    assert_membership()
                finally:
                    for _, release in gates.values():
                        release.set()
                    resume.set()
                    old_poll.join(6)
                    if new_poll.ident is not None:
                        new_poll.join(6)
                self.assertFalse(new_poll.is_alive())
                data = self.scrape()
                if transition == "lifecycle":
                    self.assertEqual(self.value(data, "haos_memory_usage_bytes", component="app", app="new"), 12)

    def test_disk_conversion_overflow_fails_entire_host_snapshot(self):
        for field in ("disk_total", "disk_used", "disk_free"):
            with self.subTest(field=field):
                self.collector.poll()
                original = self.fixture.data["/host/info"][field]
                self.fixture.data["/host/info"][field] = 1e308
                self.now += 1
                try:
                    self.collector.poll()
                    data = self.scrape()
                    self.assertEqual(self.value(data, "haos_collection_success", source="host", app=""), 0)
                    self.assertEqual(self.value(data, "haos_collection_last_success_timestamp_seconds", source="host", app=""), self.now - 1)
                    self.assertFalse(any(name.startswith("haos_host_") for name, _ in data))
                    self.assertNotIn("+Inf", self.body)
                    self.assertEqual(self.value(data, "haos_memory_usage_bytes", component="core", app=""), 321)
                finally:
                    self.fixture.data["/host/info"][field] = original

    def test_malformed_required_optional_absence_and_upstream_failures(self):
        self.collector.poll()
        del self.fixture.data["/core/stats"]["cpu_usage"]
        del self.fixture.data["/addons/beta/stats"]["network_rx"]
        self.fixture.data["/host/info"]["boot_timestamp"] = None
        self.fixture.data["/host/info"]["disk_free"] = None
        for path, mode in (("/supervisor/stats", "oversize"),
                           ("/os/info", "redirect"), ("/core/info", "invalid-json")):
            self.fixture.fail[path] = mode
        with contextlib.redirect_stderr(io.StringIO()) as logs:
            self.collector.poll()
            data = self.scrape()
        for source in ("core_stats", "supervisor_stats", "os", "core_info"):
            self.assertEqual(self.value(data, "haos_collection_success", source=source, app=""), 0)
        self.assertNotIn(("haos_network_receive_bytes_total", (("app", "beta"), ("component", "app"))), data)
        self.assertNotIn("haos_host_boot_completion_timestamp_seconds", self.body)
        self.assertNotIn("haos_host_disk_free_bytes", self.body)
        self.assertNotIn("/credential-trap", [p for _, p, _ in self.fixture.calls])
        self.assertNotIn(SECRET, logs.getvalue())

    def test_stalled_worker_89_and_90_second_boundary(self):
        self.collector.poll()
        self.now += 89
        data = self.scrape()
        self.assertEqual(self.value(data, "haos_collection_success", source="core_stats", app=""), 1)
        self.assertIn("haos_cpu_seconds_total", self.body)
        self.now += 1
        data = self.scrape()
        self.assertEqual(self.value(data, "haos_collection_success", source="core_stats", app=""), 0)
        self.assertEqual(self.value(data, "haos_collection_last_success_timestamp_seconds", source="core_stats", app=""), 1700000200)
        self.assertIn("haos_collection_duration_seconds", self.body)
        self.assertNotIn("haos_cpu_seconds_total", self.body)
        self.assertNotIn("haos_component_info", self.body)

    def test_parser_exception_cannot_leave_previous_success(self):
        self.collector.poll()
        self.fixture.data["/addons"]["addons"] = [None]
        self.fixture.data["/core/stats"]["memory_usage"] = {"bad": SECRET}
        self.now += 30
        self.collector.poll()
        data = self.scrape()
        for source in ("inventory", "core_stats"):
            self.assertEqual(self.value(data, "haos_collection_success", source=source, app=""), 0)
        self.assertNotIn(("haos_memory_usage_bytes", (("app", ""), ("component", "core"))), data)

    def test_executable_config_startup_and_logs(self):
        with tempfile.TemporaryDirectory() as directory:
            options = Path(directory) / "options.json"
            env = dict(os.environ, SUPERVISOR_TOKEN="supervisor-fixture",
                       SUPERVISOR_URL=self.fixture.url, OPTIONS_PATH=str(options), METRICS_PORT="0")
            for config in ({}, {"metrics_token": ""}, {"metrics_token": "   "}):
                options.write_text(json.dumps(config))
                result = subprocess.run([sys.executable, str(COLLECTOR)], env=env,
                                        capture_output=True, text=True, timeout=4)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("supervisor-fixture", result.stderr)
            # Reserve an ephemeral port long enough to select it for this subprocess.
            server = ThreadingHTTPServer(("127.0.0.1", 0), BaseHTTPRequestHandler)
            port = server.server_port
            server.server_close()
            env["METRICS_PORT"] = str(port)
            options.write_text(json.dumps({"metrics_token": "metrics-fixture", "private": SECRET}))
            process = subprocess.Popen([sys.executable, str(COLLECTOR)], env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 8
                while True:
                    try:
                        status, body = request("http://127.0.0.1:%s" % port)
                        if "haos_cpu_seconds_total" in body:
                            break
                    except OSError:
                        pass
                    if time.monotonic() >= deadline:
                        self.fail("executable failed to serve fresh authenticated metrics")
                    time.sleep(0.05)
                self.assertEqual(status, 200)
                request("http://127.0.0.1:%s" % port, SECRET, path="/" + PRIVATE)
            finally:
                process.terminate()
                out, err = process.communicate(timeout=4)
            for value in (SECRET, PRIVATE, "metrics-fixture", "supervisor-fixture"):
                self.assertNotIn(value, out + err + body)


if __name__ == "__main__":
    unittest.main(verbosity=2)
