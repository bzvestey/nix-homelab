"""Real release contracts, not a substitute Socket.IO server.

2.5.6 server/server.js:401/450 loginByToken(token)/login({username,password})
ack {ok:true}; login also returns token; MFA returns {tokenRequired:true}.
afterLogin:1834 emits monitorList (ID-keyed object), then info with version,
then heartbeatList, BEFORE login ack. Initial info:390 hides version.
getMonitorList():1001 emits complete monitorList before {ok:true} ack.
getMonitor(id):1017 -> {ok:true,monitor:{...}}; add(payload):743 ->
{ok:true,monitorID:int}; editMonitor(full payload):818 -> same ack.
getMonitorBeats(id,hours):1059 -> {ok:true,data:[raw heartbeat records]}.
uptime-kuma-server.js:259 queries ALL user monitors, not just active ones.
add requires accepted_statuscodes as string ranges and conditions as an array
(conditions is NOT NULL in SQLite); notificationIDList is an ID-to-bool map.
The async connection handler awaits initial info before registering login.
Tests use public setup/notification/pause/history APIs only, never the DB.
"""

import importlib.util
from copy import deepcopy
import base64
import hashlib
import hmac
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import socket
import ssl
import stat
import subprocess
import tempfile
import threading
import time
import unittest
from urllib.parse import parse_qs, urlsplit
from unittest.mock import patch

import requests
import socketio


PASSWORD = "Disposable-Kuma-Contract-42!"


def desired_document():
    document = {
        "schemaVersion": 1,
        "groups": [{"key": "group:example", "name": "example"}],
        "checks": [{"key": "node:one", "name": "one", "type": "ping",
                    "parentKey": "group:example", "target": {"hostname": "192.0.2.1"}}],
        "adoptions": {},
        "policy": {"notificationPolicy": None, "newChecks": {
            "ping": {"interval": 60, "timeout": 10, "maxretries": 2, "retryInterval": 30},
            "http": {"interval": 60, "timeout": 10, "maxretries": 2, "retryInterval": 30,
                     "method": "GET", "ignoreTls": False, "maxredirects": 10,
                     "accepted_statuscodes": ["200-299"]}}},
    }
    return seal(document)


def seal(document):
    document.pop("digest", None)
    document["digest"] = hashlib.sha256(json.dumps(
        document, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
    return document


class PlannerContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(os.environ["RECONCILE_FILE"])
        assert path.is_file(), "Missing read-only planner implementation"
        spec = importlib.util.spec_from_file_location("reconcile", path)
        cls.planner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.planner)

    def setUp(self):
        self.desired = desired_document()
        self.live = {"origin": "https://kuma.example", "version": "2.5.6", "monitors": []}
        self.state = {"schemaVersion": 2, "origin": self.live["origin"],
                      "bootstrapComplete": False, "owned": {}, "intents": {}}

    def plan(self):
        return self.planner.build_plan(self.desired, self.live, self.state)

    def blocked(self, category):
        plan = self.plan()
        self.assertFalse(plan["valid"])
        self.assertEqual(plan["operations"], [])
        self.assertIn(category, [c["category"] for c in plan["conflicts"]])

    def test_paused_unmanaged_collision_blocks_all_writes(self):
        self.live["monitors"] = [{"id": 7, "type": "ping", "name": "manual", "active": False,
                                  "hostname": "192.0.2.1"}]
        self.blocked("unmanaged-collision")

    def test_cross_type_planned_names_block_before_any_operations(self):
        for left, right in ((0, 1), (0, 2), (1, 2)):
            with self.subTest(pair=(left, right)):
                self.desired = desired_document()
                self.desired["checks"].append({
                    "key": "site:web", "name": "web", "type": "http",
                    "parentKey": "group:example", "target": {"url": "https://web.example/"}})
                seal(self.desired)
                self.assertTrue(self.plan()["valid"])
                items = self.desired["groups"] + self.desired["checks"]
                items[right]["name"] = items[left]["name"]
                seal(self.desired)
                self.blocked("manifest")

    def test_duplicate_group_blocks_adoption(self):
        self.desired["adoptions"] = {"group:example": {"id": 4, "name": "example", "type": "group"}}
        seal(self.desired)
        self.live["monitors"] = [{"id": i, "type": "group", "name": "example"} for i in (4, 5)]
        self.blocked("ambiguous-identity")

    def test_missing_owned_id_is_not_recreated(self):
        self.state["owned"] = {"node:one": {"id": 19, "type": "ping"}}
        self.blocked("missing-owned-id")

    def test_missing_or_changed_adoption_requires_review(self):
        self.desired["adoptions"] = {"node:one": {
            "id": 7, "name": "one", "type": "ping", "target": {"hostname": "192.0.2.1"}}}
        seal(self.desired)
        self.blocked("adoption-identity")
        self.live["monitors"] = [{"id": 7, "name": "one", "type": "ping", "hostname": "192.0.2.99"}]
        self.blocked("adoption-identity")

    def test_bootstrap_changed_address_uses_reviewed_old_anchor(self):
        self.desired["adoptions"] = {"node:one": {
            "id": 7, "name": "one", "type": "ping", "target": {"hostname": "192.0.2.9"}}}
        seal(self.desired)
        self.live["monitors"] = [{"id": 7, "name": "one", "type": "ping", "hostname": "192.0.2.9"}]
        ops = self.plan()["operations"]
        self.assertEqual([(o["action"], o["key"]) for o in ops],
                         [("create", "group:example"), ("adopt", "node:one"), ("update", "node:one")])
        self.assertEqual(ops[2]["patch"], {"hostname": "192.0.2.1", "parentKey": "group:example"})

    def test_http_collision_normalization_and_distinct_targets(self):
        self.desired["checks"] = [{"key": "site:one", "name": "one", "type": "http",
                                   "parentKey": "group:example", "target": {"url": "https://example.org/"}}]
        seal(self.desired)
        for url, blocked in [("https://EXAMPLE.org:443", True), ("http://example.org/", False),
                             ("https://example.org:80/", False), ("https://example.org/health", False),
                             ("https://example.org/?x=1", False)]:
            with self.subTest(url=url):
                self.live["monitors"] = [{"id": 8, "type": "http", "name": "manual", "url": url, "active": False}]
                self.assertEqual(self.plan()["valid"], not blocked)

    def test_report_only_removal_and_fingerprint_detects_private_drift(self):
        self.state["owned"] = {"site:removed": {"id": 8, "type": "http"}}
        self.live["monitors"] = [{"id": 8, "name": "unrelated", "type": "http", "url": "https://old.example/",
                                  "notificationIDList": {"SECRET-SENTINEL": True}}]
        before = self.plan()
        self.assertEqual(before["removals"], [{"key": "site:removed", "id": 8}])
        self.live["monitors"][0]["notificationIDList"] = {"SECOND-SENTINEL": True}
        after = self.plan()
        self.assertNotEqual(before["fingerprints"], after["fingerprints"])
        self.assertEqual(before["operations"], after["operations"])
        self.assertNotIn("SENTINEL", json.dumps(before) + json.dumps(after))

    def test_adoption_preserves_id_and_settings(self):
        self.desired["adoptions"] = {
            "group:example": {"id": 4, "type": "group", "name": "example"},
            "node:one": {"id": 7, "type": "ping", "name": "one", "target": {"hostname": "192.0.2.1"}}}
        seal(self.desired)
        self.live["monitors"] = [
            {"id": 999, "type": "group", "name": "manual-parent", "parent": None},
            {"id": 4, "type": "group", "name": "example", "parent": 999},
            {"id": 8, "type": "ping", "name": "manual-child", "hostname": "192.0.2.88", "parent": 4,
             "description": "UNRELATED-PRIVATE-SENTINEL"},
            {"id": 7, "type": "ping", "name": "one", "hostname": "192.0.2.1", "parent": 4,
             "active": False, "interval": 333, "notificationIDList": {"SECRET-SENTINEL": True}}]
        before = deepcopy((self.desired, self.live, self.state))
        plan = self.plan()
        self.assertTrue(plan["valid"])
        self.assertEqual([(o["action"], o["key"], o["id"]) for o in plan["operations"]],
                         [("adopt", "group:example", 4), ("adopt", "node:one", 7)])
        self.assertNotIn("SECRET-SENTINEL", json.dumps(plan))
        self.assertNotIn("UNRELATED-PRIVATE-SENTINEL", json.dumps(plan))
        self.assertNotIn("patch", plan["operations"][0])
        self.assertEqual(before, (self.desired, self.live, self.state))
        self.live["monitors"].reverse()
        self.assertEqual(plan, self.plan())
        self.state["owned"] = {"group:example": {"id": 4, "type": "group"},
                               "node:one": {"id": 7, "type": "ping"}}
        self.assertEqual(self.plan()["operations"], [])

    def test_owned_address_name_parent_updates_only(self):
        self.state["owned"] = {"group:example": {"id": 4, "type": "group"},
                               "node:one": {"id": 7, "type": "ping"}}
        self.live["monitors"] = [
            {"id": 4, "type": "group", "name": "example", "parent": 999},
            {"id": 7, "type": "ping", "name": "old", "hostname": "192.0.2.9", "parent": None,
             "active": False, "timeout": 99, "notificationIDList": {"SECRET-SENTINEL": True}}]
        ops = self.plan()["operations"]
        self.assertEqual(len(ops), 1)
        self.assertEqual(ops[0]["patch"], {"name": "one", "hostname": "192.0.2.1", "parentKey": "group:example"})
        self.assertNotIn("SECRET-SENTINEL", json.dumps(self.plan()))

    def test_removed_anchors_are_not_adoptions_or_missing_ids(self):
        self.desired["adoptions"]["site:removed"] = {
            "id": 88, "type": "http", "name": "old", "target": {"url": "https://old.example/"}}
        seal(self.desired)
        self.assertTrue(self.plan()["valid"])
        self.assertEqual([o["action"] for o in self.plan()["operations"]], ["create", "create"])
        self.state["owned"]["site:removed"] = {"id": 88, "type": "http"}
        self.blocked("missing-owned-id")

    def test_normalize_only_documented_http_identity(self):
        norm = self.planner.normalize_target
        base = norm({"type": "http", "url": "https://EXAMPLE.org:443"})
        self.assertEqual(base, ("http", "https", "example.org", 443, "/", ""))
        self.assertEqual(base, norm({"type": "http", "url": "https://example.org/"}))
        for url in ("http://example.org/", "https://example.org:80/", "https://example.org/health",
                    "https://example.org/?x=1", "https://example.org:444/", "https://example.org:0/",
                    "https://example.org/?"):
            self.assertNotEqual(base, norm({"type": "http", "url": url}))

    def test_malformed_manifest_state_and_snapshot_block(self):
        original = deepcopy(self.desired)
        for change in ({"checks": None}, {"groups": [{"key": "group:bad", "name": "bad", "parentKey": "group:example"}]},
                       {"policy": {}}, {"adoptions": {"node:bad": None}}, {"schemaVersion": True}):
            with self.subTest(change=change):
                self.desired = seal(dict(original, **change))
                self.blocked("manifest")
        self.desired = original
        self.state["owned"] = {"node:one": {"id": True, "type": "ping"}}
        self.blocked("state")
        self.state = {"schemaVersion": 2, "origin": self.live["origin"],
                      "bootstrapComplete": False, "owned": {}, "intents": {}}
        self.live["monitors"] = [{"id": 1}, {"id": 1}]
        self.blocked("snapshot")

    def test_bootstrap_completion_is_explicit_not_inferred_from_claims(self):
        self.state["bootstrapComplete"] = True
        self.assertTrue(self.plan()["valid"])
        self.state["bootstrapComplete"] = "yes"
        self.blocked("state")

    def test_origin_required_canonical_and_bound_before_id_interpretation(self):
        for origin in (None, "http://kuma.example", "https://KUMA.example", "https://kuma.example:443",
                       "https://kuma.example/", "https://user@kuma.example", "https://kuma.example:0"):
            with self.subTest(origin=origin):
                self.live["origin"] = origin
                self.blocked("origin")
        del self.live["origin"]
        self.blocked("origin")
        self.live = {"origin": "https://other.example", "version": "2.5.6", "monitors": [{"id": 1}]}
        self.blocked("origin")  # Must not even inspect this invalid ID record.
        self.assertEqual(self.plan()["fingerprints"], {})

    def test_validation_stale_digest_version_state_and_intents(self):
        self.desired["checks"][0]["name"] = "changed"
        self.blocked("manifest-digest")
        seal(self.desired)
        self.live["version"] = "2.5.7"
        self.blocked("unsupported-version")
        self.live["version"] = "2.5.6"
        self.state["intents"] = {"node:one": {"action": "create", "type": "ping", "id": None,
                                               "inventoryDigest": self.desired["digest"], "baseline": None}}
        self.blocked("unresolved-intent")

    def test_real_nix_digest_and_unicode(self):
        rendered = json.loads(Path(os.environ["DESIRED_FILE"]).read_text())
        plan = self.planner.build_plan(rendered, self.live, self.state)
        self.assertTrue(plan["valid"], plan["conflicts"])

    def test_intent_payloads_are_strict_and_fail_closed(self):
        intent = {"action": "create", "type": "ping", "id": None,
                  "inventoryDigest": self.desired["digest"], "baseline": None}
        for alteration in ({"extra": True}, {"id": 42}, {"baseline": "0" * 64},
                           {"action": "update", "id": 42, "baseline": "0" * 64}):
            with self.subTest(alteration=alteration):
                self.state["intents"] = {"node:one": dict(intent, **alteration)}
                self.blocked("state")

    def test_cli_stale_manifest_rejected_before_auth(self):
        with tempfile.TemporaryDirectory() as root:
            desired = Path(root) / "desired.json"
            self.desired["checks"][0]["name"] = "changed"
            desired.write_text(json.dumps(self.desired))
            result = subprocess.run([
                os.environ["RECONCILE_BIN"], "plan", "--desired", str(desired),
                "--credential-file", str(Path(root) / "no-credentials"),
                "--endpoint", "https://example.invalid", "--state-dir", str(Path(root) / "state"),
            ], text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertNotIn("changed", result.stdout + result.stderr)


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Contracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.tmp.cleanup)
        cls.root = Path(cls.tmp.name)
        cls.ca = cls.root / "ca.pem"
        cls.key = cls.root / "key.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(cls.key), "-out", str(cls.ca), "-days", "1",
            "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1",
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.endpoint = cls.start_server("real", fault="audit")
        cls.raw = cls.raw_client(cls.endpoint)
        cls.addClassCleanup(cls.raw.disconnect)
        assert cls.raw.call("setup", ("contract", PASSWORD), timeout=10)["ok"]
        cls.login = cls.raw.call("login", {"username": "contract", "password": PASSWORD}, timeout=10)
        assert cls.login["ok"]
        cls.credential = cls.write_credential("login.json", {
            "origin": cls.endpoint, "caFile": str(cls.ca),
            "username": "contract", "password": PASSWORD,
        })
        client_path = Path(os.environ["CLIENT_FILE"])
        assert client_path.is_file(), "Missing KumaClient implementation (fixture setup/login succeeded)"
        spec = importlib.util.spec_from_file_location("kuma_client", client_path)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    @classmethod
    def write_credential(cls, name, value):
        path = cls.root / name
        path.write_text(json.dumps(value))
        path.chmod(0o600)
        return str(path)

    @classmethod
    def raw_client(cls, endpoint):
        session = requests.Session()
        session.verify = str(cls.ca)
        client = socketio.Client(
            http_session=session, reconnection=False, logger=False, engineio_logger=False,
            websocket_extra_options={"redirect_limit": 0, "http_no_proxy": ["*"]},
        )
        client.contract_events = []
        initial_info = threading.Event()

        def record_info(data):
            client.contract_events.append(("info", (data,)))
            initial_info.set()

        client.on("info", record_info)
        for event in ("monitorList", "heartbeatList"):
            client.on(event, lambda *args, event=event: client.contract_events.append((event, args)))
        client.connect(endpoint, transports=["websocket"], wait_timeout=10)
        assert initial_info.wait(10), "Kuma must finish async connection initialization"
        return client

    @classmethod
    def start_server(cls, name, version=None, fault=None, cleanup_register=None):
        data = cls.root / name
        data.mkdir()
        (data / "db-config.json").write_text('{"type":"sqlite"}')
        source = Path(os.environ["KUMA_ROOT"])
        if version or fault:
            target = cls.root / f"{name}-runtime"
            target.mkdir()
            # Link whole immutable dependency directories, not thousands of
            # individual files (which exhausts the test VM's temporary space).
            for entry in source.iterdir():
                if entry.name not in ("package.json", "server"):
                    (target / entry.name).symlink_to(entry)
            package = json.loads((source / "package.json").read_text())
            if version:
                package["version"] = version
            (target / "package.json").write_text(json.dumps(package))
            # Resolve server code locally, not through the store symlink.
            shutil.copytree(source / "server", target / "server")
            server = target / "server/server.js"
            code = server.read_text()
            audit_anchor = "        // Add a new monitor"
            assert code.count(audit_anchor) == 1
            code = code.replace(audit_anchor, '''        socket.onAny((event) => {
            if (["deleteMonitor", "pauseMonitor", "resumeMonitor", "addMonitorTag",
                 "editMonitorTag", "deleteMonitorTag", "addTag", "editTag", "deleteTag"].includes(event)) {
                console.log("RECONCILE_FORBIDDEN:" + event);
            }
        });
''' + audit_anchor)
            if fault == "delayed-info":
                old = '        await sendInfo(socket, true);'
                new = '        await new Promise(resolve => setTimeout(resolve, 250));\n' + old
            elif fault == "late-auth-info":
                old = '        sendInfo(socket),'
                new = '        Promise.resolve().then(() => { setTimeout(() => sendInfo(socket), 1000); }),'
            elif fault in ("lost-ack", "lost-check-ack", "slow-add-ack"):
                old = '''                callback({
                    ok: true,
                    msg: "successAdded",
                    msgi18n: true,
                    monitorID: bean.id,
                });'''
                new = '                // Fault injection: mutation committed; ack lost.'
                if fault == "lost-check-ack":
                    new = '                if (monitor.type === "group") {\n' + old + '\n                }'
                elif fault == "slow-add-ack":
                    new = '                await new Promise(resolve => setTimeout(resolve, 9000));\n' + old
            else:
                old = new = ""
            if old:
                assert code.count(old) == 1
                code = code.replace(old, new)
            server.chmod(0o600)
            server.write_text(code)
            source = target
        endpoint = f"https://127.0.0.1:{port()}"
        log = open(data / "server.log", "w+")
        register = cleanup_register or cls.addClassCleanup
        register(log.close)
        process = subprocess.Popen(
            ["node", "server/server.js"], cwd=source,
            env={**os.environ, "DATA_DIR": str(data), "UPTIME_KUMA_HOST": "127.0.0.1",
                 "UPTIME_KUMA_PORT": endpoint.rsplit(":", 1)[1],
                 "NODE_EXTRA_CA_CERTS": str(cls.ca),
                 "UPTIME_KUMA_SSL_KEY": str(cls.key), "UPTIME_KUMA_SSL_CERT": str(cls.ca)},
            stdout=log, stderr=log,
        )

        def cleanup():
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        register(cleanup)
        for _ in range(120):
            try:
                response = requests.get(endpoint, verify=str(cls.ca), timeout=1)
                if response.status_code == 200:
                    return endpoint
            except requests.RequestException:
                pass
            if process.poll() is not None:
                break
            time.sleep(0.5)
        log.seek(0)
        raise AssertionError(log.read())

    def client(self, credential=None, endpoint=None):
        client = self.module.KumaClient(endpoint or self.endpoint, credential or self.credential)
        self.addCleanup(client.close)
        return client

    def provision(self, output, endpoint=None, password=PASSWORD, ca=True, mfa=None):
        binary = os.environ.get("PROVISION_BIN", "")
        self.assertTrue(binary and Path(binary).is_file(), "Missing secure provisioning CLI")
        keys = []
        recipients = []
        key_directory = tempfile.TemporaryDirectory(dir=self.root)
        self.addCleanup(key_directory.cleanup)
        for index in range(2):
            key = Path(key_directory.name) / f"{index}.age"
            subprocess.run(["age-keygen", "-o", str(key)], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            keys.append(key)
            recipients += ["--recipient", subprocess.check_output(
                ["age-keygen", "-y", str(key)], text=True).strip()]
        command = [binary, "--endpoint", endpoint or self.endpoint, "--output", str(output), *recipients]
        if ca:
            command += ["--ca-file", str(self.ca)]
        terminal, slave = pty.openpty()
        process = subprocess.Popen(["setsid", "--ctty", *command],
                                   stdin=slave, stdout=slave, stderr=slave)
        os.close(slave)
        transcript = b""
        prompts = [(b"Username:", "contract"), (b"Password:", password)]
        if mfa is not None:
            prompts.append((b"MFA code:", mfa))
        deadline = time.monotonic() + 35
        try:
            while time.monotonic() < deadline:
                if select.select([terminal], [], [], 0.1)[0]:
                    try:
                        data = os.read(terminal, 65536)
                    except OSError:
                        break
                    if not data:
                        break
                    transcript += data
                    if prompts and prompts[0][0] in transcript:
                        _, value = prompts.pop(0)
                        os.write(terminal, (value + "\n").encode())
            else:
                self.fail("Provisioning CLI did not finish")
        finally:
            os.close(terminal)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        self.assertNotIn(password.encode(), transcript)
        if mfa is not None:
            self.assertNotIn(mfa.encode(), transcript)
        return process.returncode, keys, transcript

    def test_provision_cli_encrypts_reusable_origin_bound_token_without_monitor_writes(self):
        # Catches plaintext output, storing the password, wrong recipients/origin,
        # an unusable token, leaking hidden input, and modifying existing monitors.
        output = self.root / "provisioned.yaml"
        before = self.client().snapshot()
        code, keys, transcript = self.provision(output)
        self.assertEqual(code, 0, transcript)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        self.assertNotIn(PASSWORD, output.read_text())
        for key in keys:
            document = json.loads(subprocess.check_output(
                ["sops", "decrypt", "--output-type", "json", str(output)],
                env={**os.environ, "SOPS_AGE_KEY_FILE": str(key)}, stderr=subprocess.DEVNULL))
            credential = json.loads(document["kuma-reconciler-management"])
            self.assertEqual(set(credential), {"origin", "loginToken", "caFile"})
            self.assertEqual(credential["origin"], self.endpoint)
            self.assertNotIn(credential["loginToken"].encode(), transcript)
            path = self.write_credential("provisioned.json", credential)
            self.assertEqual(self.client(path).snapshot(), before)

    def test_provision_waits_for_authenticated_version_after_login_ack(self):
        endpoint = self.start_server("provision-late-info", fault="late-auth-info")
        raw = self.raw_client(endpoint)
        self.addCleanup(raw.disconnect)
        self.assertTrue(raw.call("setup", ("contract", PASSWORD), timeout=10)["ok"])
        output = self.root / "late-info.yaml"
        code, _, transcript = self.provision(output, endpoint=endpoint)
        self.assertEqual(code, 0, transcript)
        self.assertTrue(output.is_file())

    def test_provision_cli_failures_leave_no_credential_and_never_overwrite(self):
        wrong = self.start_server("provision-version", "2.5.7")
        raw = self.raw_client(wrong)
        self.addCleanup(raw.disconnect)
        self.assertTrue(raw.call("setup", ("contract", PASSWORD), timeout=10)["ok"])
        for name, options in (
            ("bad-password", {"password": "Wrong-Private-Password-42!"}),
            ("bad-tls", {"ca": False}),
            ("bad-version", {"endpoint": wrong}),
            ("bad-origin", {"endpoint": self.endpoint + "/extra"}),
        ):
            with self.subTest(name=name):
                output = self.root / f"{name}.yaml"
                code, _, _ = self.provision(output, **options)
                self.assertNotEqual(code, 0)
                self.assertFalse(output.exists())
        output = self.root / "existing-provision.yaml"
        output.write_text("retain-existing-ciphertext")
        code, _, _ = self.provision(output)
        self.assertNotEqual(code, 0)
        self.assertEqual(output.read_text(), "retain-existing-ciphertext")
        link = self.root / "provision-symlink.yaml"
        link.symlink_to(output)
        code, keys, _ = self.provision(link)
        self.assertNotEqual(code, 0)
        self.assertTrue(link.is_symlink())
        self.assertEqual(output.read_text(), "retain-existing-ciphertext")
        # No controlling terminal: a pipe must never become a secret-input fallback.
        output = self.root / "no-terminal.yaml"
        command = [os.environ["PROVISION_BIN"], "--endpoint", self.endpoint,
                   "--output", str(output)]
        for key in keys:
            command += ["--recipient", subprocess.check_output(
                ["age-keygen", "-y", str(key)], text=True).strip()]
        result = subprocess.run(command, input=PASSWORD.encode(), start_new_session=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(PASSWORD.encode(), result.stdout + result.stderr)
        self.assertFalse(output.exists())

    def payload(self, name, kind="http", **overrides):
        return {
            "name": name, "type": kind, "parent": None,
            "url": self.endpoint, "hostname": "127.0.0.1", "method": "GET",
            "interval": 60, "timeout": 10, "maxretries": 2, "retryInterval": 30,
            "maxredirects": 10, "ignoreTls": False,
            "accepted_statuscodes": ["200-299"], "notificationIDList": {},
            "conditions": [],
            **overrides,
        }

    def apply_inputs(self, suffix):
        # Exercise the supported token flow for rapid Task 4 sessions, without
        # altering the server's real 20-password-logins/minute limiter or the
        # existing password/MFA/failed-auth success boundaries.
        self.credential = self.write_credential("apply-token.json", {
            "origin": self.endpoint, "caFile": str(self.ca), "loginToken": self.login["token"]})
        spec = importlib.util.spec_from_file_location("apply_reconcile", os.environ["RECONCILE_FILE"])
        planner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(planner)
        self.assertTrue(callable(getattr(planner, "apply_plan", None)), "Missing durable apply_plan")
        original = planner._apply_locked

        def audited_apply(*args, **kwargs):
            logs = list(self.root.glob("*/server.log"))
            before = {p: p.read_text().count("RECONCILE_FORBIDDEN:") for p in logs}
            try:
                return original(*args, **kwargs)
            finally:
                for p, count in before.items():
                    self.assertEqual(p.read_text().count("RECONCILE_FORBIDDEN:"), count,
                                     "apply must not delete/pause/resume/tag")

        planner._apply_locked = audited_apply
        desired = desired_document()
        desired["groups"][0]["name"] = "apply-" + suffix
        desired["checks"][0]["name"] = "node-" + suffix
        desired["checks"][0]["target"]["hostname"] = "192.0.2." + str({
            "latest": 106, "repeat": 107, "persist": 108, "stale": 109, "lost": 110}[suffix])
        desired["policy"]["notificationPolicy"] = {"notificationIDList": {}}
        seal(desired)
        directory = self.root / ("state-" + self._testMethodName)
        state = {"schemaVersion": 2, "origin": None,
                 "bootstrapComplete": False, "owned": {}, "intents": {}}
        return planner, desired, directory, state

    def test_ownership_and_approval_are_bound_to_configured_origin(self):
        planner, desired, directory, state = self.apply_inputs("repeat")
        clients = []
        raws = []
        tokens = []
        for label in ("origin-a", "origin-b"):
            endpoint = self.start_server(label, fault="audit", cleanup_register=self.addCleanup)
            raw = self.raw_client(endpoint)
            self.addCleanup(raw.disconnect)
            self.assertTrue(raw.call("setup", ("contract", PASSWORD), timeout=10)["ok"])
            login = raw.call("login", {"username": "contract", "password": PASSWORD}, timeout=10)
            credential = self.write_credential(label + ".json", {
                "origin": endpoint, "caFile": str(self.ca), "loginToken": login["token"]})
            client = self.client(credential, endpoint)
            self.assertEqual(client.create_monitor(self.payload("manual-group", "group")), 1)
            self.assertEqual(client.create_monitor(self.payload(
                "manual-node", "ping", hostname="192.0.2.200", parent=1)), 2)
            clients.append((client, endpoint))
            raws.append(raw)
            tokens.append(login["token"])
        (a, origin_a), (b, origin_b) = clients
        desired["adoptions"] = {
            "group:example": {"id": 1, "type": "group", "name": "manual-group"},
            "node:one": {"id": 2, "type": "ping", "name": "manual-node",
                         "target": {"hostname": "192.0.2.200"}}}
        seal(desired)
        # Identical IDs/identities, but independent databases/origins. This
        # approval must not bootstrap even an unbound B with an empty manifest.
        empty = deepcopy(desired)
        empty["groups"], empty["checks"], empty["adoptions"] = [], [], {}
        seal(empty)
        stale = planner.build_plan(empty, a.snapshot(), state)
        other = planner.build_plan(empty, b.snapshot(), state)
        self.assertNotEqual(stale["liveIdentityDigest"], other["liveIdentityDigest"])
        self.assertEqual(stale["fingerprints"], other["fingerprints"])
        self.assertNotEqual(stale["origin"], other["origin"])
        self.assertEqual({k: v for k, v in stale.items() if k not in ("origin", "liveIdentityDigest")},
                         {k: v for k, v in other.items() if k not in ("origin", "liveIdentityDigest")})
        plan = planner.build_plan(desired, a.snapshot(), state)
        self.assertTrue(plan["valid"], plan["conflicts"])
        planner.apply_plan(plan, desired, a, directory)
        saved = json.loads((directory / "ownership.json").read_text())
        before_b = b.snapshot()
        with patch.object(b, "create_monitor", wraps=b.create_monitor) as create, \
                patch.object(b, "edit_monitor", wraps=b.edit_monitor) as edit:
            with self.assertRaises(planner.PlanError):
                planner.reconcile(desired, b, directory, authorize_ongoing=True)
            create.assert_not_called()
            edit.assert_not_called()
        self.assertEqual(b.snapshot(), before_b)
        self.assertEqual(json.loads((directory / "ownership.json").read_text()), saved)
        self.assertEqual(saved["origin"], origin_a)
        blocked = planner.build_plan(desired, b.snapshot(), saved)
        self.assertFalse(blocked["valid"])
        self.assertEqual(blocked["operations"], [])
        with self.assertRaisesRegex(planner.PlanError, "stale-plan"):
            planner.apply_plan(stale, empty, b, self.root / "unbound-b")
        self.assertFalse((self.root / "unbound-b" / "ownership.json").exists())
        self.assertEqual(b.snapshot(), before_b)
        # Same origin, genuinely new token: no ownership or approval reset.
        time.sleep(1.1)  # JWT issuance timestamp must differ.
        rotated = raws[0].call("login", {"username": "contract", "password": PASSWORD}, timeout=10)
        self.assertNotEqual(rotated["token"], tokens[0])
        token_file = self.write_credential("rotated-origin-a.json", {
            "origin": origin_a, "caFile": str(self.ca), "loginToken": rotated["token"]})
        rotated_client = self.client(token_file, origin_a + "/")
        before_a = a.snapshot()
        planner.reconcile(desired, rotated_client, directory, authorize_ongoing=True)
        self.assertEqual(a.snapshot(), before_a)
        for legacy in (dict(saved, schemaVersion=1), {k: v for k, v in saved.items() if k != "origin"},
                       {k: v for k, v in dict(saved, schemaVersion=1).items() if k != "origin"},
                       dict(saved, origin=None), dict(state),
                       {k: v for k, v in state.items() if k != "origin"}):
            (directory / "ownership.json").write_text(json.dumps(legacy))
            with self.assertRaises(planner.PlanError):
                planner.reconcile(desired, a, directory, authorize_ongoing=True)
            with self.assertRaises(planner.PlanError):
                planner.apply_plan(plan, desired, a, directory)
            self.assertEqual(a.snapshot(), before_a)
        print("origin regression: zero B mutations; stale unbound approval rejected; token rotation; legacy refusal")

    def test_second_reconciliation_has_no_changes(self):
        planner, desired, directory, state = self.apply_inputs("repeat")
        client = self.client()
        plan = planner.build_plan(desired, client.snapshot(), state)
        planner.apply_plan(plan, desired, client, directory)
        saved = json.loads((directory / "ownership.json").read_text())
        self.assertTrue(saved["bootstrapComplete"])
        self.assertEqual(planner.build_plan(desired, client.snapshot(), saved)["operations"], [])
        desired["checks"].append({"key": "node:two", "name": "node-repeat-two", "type": "ping",
                                  "parentKey": "group:example", "target": {"hostname": "192.0.2.222"}})
        desired["checks"].append({"key": "node:three", "name": "node-repeat-three", "type": "ping",
                                  "parentKey": "group:example", "target": {"hostname": "192.0.2.223"}})
        seal(desired)
        planner.reconcile(desired, client, directory, authorize_ongoing=True)
        before = client.snapshot()
        planner.reconcile(desired, client, directory, authorize_ongoing=True)
        self.assertEqual(before, client.snapshot())
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual((directory / "ownership.json").stat().st_mode & 0o777, 0o600)
        desired["policy"]["notificationPolicy"] = {"notificationIDList": {"999": True}}
        seal(desired)
        with self.assertRaisesRegex(planner.PlanError, "policy"):
            planner.reconcile(desired, client, directory, authorize_ongoing=True)
        self.assertEqual(before, client.snapshot())
        with self.assertRaisesRegex(planner.PlanError, "authorization"):
            planner.reconcile(desired, client, directory)

    def test_stale_plan_refuses_apply(self):
        planner, desired, directory, state = self.apply_inputs("stale")
        client = self.client()
        plan = planner.build_plan(desired, client.snapshot(), state)
        client.create_monitor(self.payload("stale-extra"))
        before = client.snapshot()
        with self.assertRaisesRegex(planner.PlanError, "stale"):
            planner.apply_plan(plan, desired, client, directory)
        self.assertEqual(before, client.snapshot())
        self.assertFalse((directory / "ownership.json").exists())

    def test_total_deadline_on_real_slow_ack_sequence(self):
        planner, desired, directory, state = self.apply_inputs("lost")
        endpoint = self.start_server("slow-apply", fault="slow-add-ack")
        raw = self.raw_client(endpoint)
        self.addCleanup(raw.disconnect)
        self.assertTrue(raw.call("setup", ("contract", PASSWORD), timeout=10)["ok"])
        credential = self.write_credential("slow-apply.json", {
            "origin": endpoint, "caFile": str(self.ca), "username": "contract", "password": PASSWORD})
        desired["checks"] = [
            {"key": f"node:slow-{i:02}", "name": f"slow-{i:02}", "type": "ping",
             "parentKey": "group:example", "target": {"hostname": f"192.0.2.{140 + i}"}}
            for i in range(15)]
        seal(desired)
        client = self.client(credential, endpoint)
        plan = planner.build_plan(desired, client.snapshot(), state)
        started = time.monotonic()
        with self.assertRaises((planner.PlanError, self.module.KumaError)):
            planner.apply_plan(plan, desired, client, directory)
        elapsed = time.monotonic() - started
        self.assertGreater(elapsed, 118)
        self.assertLess(elapsed, 122)
        saved = json.loads((directory / "ownership.json").read_text())
        self.assertFalse(saved["bootstrapComplete"])
        self.assertTrue(saved["intents"])
        self.assertGreaterEqual(len(saved["owned"]), 10)
        observer = self.client(credential, endpoint)
        before = observer.snapshot()
        with self.assertRaisesRegex(planner.PlanError, "unresolved-intent"):
            planner.apply_plan(plan, desired, observer, directory)
        self.assertEqual(before, observer.snapshot())
        self.assertNotIn("RECONCILE_FORBIDDEN:", (self.root / "slow-apply/server.log").read_text())
        print(f"Total real slow-ack budget: {elapsed:.3f}s; confirmed={len(saved['owned'])}; "
              f"pending={len(saved['intents'])}; remote={len(before['monitors'])}", flush=True)

    def test_lost_create_ack_does_not_duplicate_after_restart(self):
        planner, desired, directory, state = self.apply_inputs("lost")
        endpoint = self.start_server("apply-lost", fault="lost-check-ack")
        raw = self.raw_client(endpoint)
        self.addCleanup(raw.disconnect)
        self.assertTrue(raw.call("setup", ("contract", PASSWORD), timeout=10)["ok"])
        credential = self.write_credential("apply-lost.json", {
            "origin": endpoint, "caFile": str(self.ca), "username": "contract", "password": PASSWORD})
        client = self.client(credential, endpoint)
        plan = planner.build_plan(desired, client.snapshot(), state)
        with self.assertRaisesRegex(self.module.KumaError, "timeout"):
            planner.apply_plan(plan, desired, client, directory)
        restarted = self.client(credential, endpoint)
        self.assertEqual(len(restarted.snapshot()["monitors"]), 2)
        self.assertEqual(len([m for m in restarted.snapshot()["monitors"] if m["type"] == "ping"]), 1)
        with self.assertRaisesRegex(planner.PlanError, "unresolved-intent"):
            planner.apply_plan(plan, desired, restarted, directory)
        self.assertEqual(len(restarted.snapshot()["monitors"]), 2)
        saved = json.loads((directory / "ownership.json").read_text())
        self.assertEqual(set(saved["owned"]), {"group:example"})
        self.assertEqual(set(saved["intents"]), {"node:one"})

    def test_state_persist_failure_blocks_next_write(self):
        planner, desired, directory, state = self.apply_inputs("persist")
        client = self.client()
        plan = planner.build_plan(desired, client.snapshot(), state)
        original = os.replace
        writes = []

        def fail_confirmation(src, dst):
            writes.append(dst)
            if len(writes) == 4:
                raise OSError("fixture local persistence failure")
            return original(src, dst)

        with patch.object(planner.os, "replace", fail_confirmation):
            with self.assertRaises(OSError):
                planner.apply_plan(plan, desired, client, directory)
        before = client.snapshot()
        self.assertEqual(len([m for m in before["monitors"] if m["name"] == "apply-persist"]), 1)
        self.assertEqual(len([m for m in before["monitors"] if m["name"] == "node-persist"]), 1)
        saved = json.loads((directory / "ownership.json").read_text())
        self.assertEqual(set(saved["owned"]), {"group:example"})
        self.assertEqual(set(saved["intents"]), {"node:one"})
        with self.assertRaisesRegex(planner.PlanError, "unresolved-intent"):
            planner.apply_plan(plan, desired, self.client(), directory)
        self.assertEqual(before, client.snapshot())

    def test_confirmation_directory_fsync_failure_blocks_create_and_update(self):
        for action, address in (("create", 230), ("update", 231)):
            with self.subTest(action=action):
                planner, desired, directory, state = self.apply_inputs("persist")
                directory = directory.with_name(directory.name + "-" + action)
                desired["groups"][0]["name"] = "fsync-group-" + action
                desired["checks"][0].update(name="fsync-node-" + action,
                                            target={"hostname": f"192.0.2.{address}"})
                seal(desired)
                client = self.client()
                planner.apply_plan(planner.build_plan(desired, client.snapshot(), state), desired, client, directory)
                self.assertFalse((directory / "mutation.pending").exists())
                if action == "update":
                    desired["checks"][0]["name"] += "-renamed"
                else:
                    desired["checks"].append({"key": "node:first", "name": "fsync-created-first",
                        "type": "ping", "parentKey": "group:example", "target": {"hostname": "192.0.2.232"}})
                desired["checks"].append({"key": "node:two", "name": "fsync-next-" + action,
                    "type": "ping", "parentKey": "group:example", "target": {"hostname": f"192.0.2.{address + 3}"}})
                seal(desired)
                acknowledged = []
                method = "create_monitor" if action == "create" else "edit_monitor"
                mutate = getattr(client, method)
                fsync = planner.os.fsync
                failures = []

                def acknowledged_mutation(payload):
                    result = mutate(payload)
                    acknowledged.append(result)
                    return result

                def fail_confirmation_directory(fd):
                    if (acknowledged and not failures and stat.S_ISDIR(os.fstat(fd).st_mode)
                            and not json.loads((directory / "ownership.json").read_text())["intents"]):
                        failures.append("post-replace-directory-fsync")
                        raise OSError("fixture confirmation directory fsync failure")
                    return fsync(fd)

                with patch.object(client, method, acknowledged_mutation), patch.object(planner.os, "fsync", fail_confirmation_directory):
                    with self.assertRaises(OSError):
                        planner.reconcile(desired, client, directory, authorize_ongoing=True)
                self.assertEqual(len(acknowledged), 1)
                self.assertEqual(failures, ["post-replace-directory-fsync"])
                visible = json.loads((directory / "ownership.json").read_text())
                self.assertEqual(visible["intents"], {})
                before = client.snapshot()
                self.assertFalse(any(m["name"] == "fsync-next-" + action for m in before["monitors"]))
                with self.assertRaisesRegex(planner.PlanError, "unresolved-intent"):
                    planner.reconcile(desired, self.client(), directory, authorize_ongoing=True)
                self.assertEqual(before, client.snapshot())
                barrier = directory / "mutation.pending"
                self.assertEqual(json.loads(barrier.read_text()), {"schemaVersion": 1})
                self.assertEqual(barrier.stat().st_mode & 0o777, 0o600)
                # Fixture-only operator recovery: inspect committed ID/name,
                # sync the reviewed mapping, then durably retire its barrier.
                owned_id = visible["owned"]["node:first" if action == "create" else "node:one"]["id"]
                self.assertEqual(client.get_monitor(owned_id)["name"],
                                 "fsync-created-first" if action == "create" else "fsync-node-update-renamed")
                with self.assertRaisesRegex(planner.PlanError, "unresolved-intent"):
                    with planner._locked_state(directory):
                        self.fail("unresolved barrier must refuse even a lock/state read")
                with open(directory / "lock", "a") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    planner._save_state(directory, visible)
                    barrier.unlink()
                    fd = os.open(directory, os.O_DIRECTORY | os.O_RDONLY)
                    try:
                        os.fsync(fd)
                    finally:
                        os.close(fd)
                planner.reconcile(desired, client, directory, authorize_ongoing=True)
                self.assertFalse(barrier.exists())
                desired["checks"][0]["name"] += "-success"
                seal(desired)
                planner.reconcile(desired, client, directory, authorize_ongoing=True)
                self.assertFalse(barrier.exists())
                self.assertEqual(json.loads((directory / "ownership.json").read_text())["intents"], {})

    def test_killed_apply_retains_intent_across_process_restart(self):
        planner, desired, directory, state = self.apply_inputs("lost")
        endpoint = self.start_server("killed-apply", fault="lost-check-ack")
        raw = self.raw_client(endpoint)
        self.addCleanup(raw.disconnect)
        self.assertTrue(raw.call("setup", ("contract", PASSWORD), timeout=10)["ok"])
        credential = self.write_credential("killed.json", {
            "origin": endpoint, "caFile": str(self.ca), "username": "contract", "password": PASSWORD})
        observer = self.client(credential, endpoint)
        plan = planner.build_plan(desired, observer.snapshot(), state)
        document = self.root / "killed-desired.json"
        approval = self.root / "killed-plan.json"
        document.write_text(json.dumps(desired))
        approval.write_text(json.dumps(plan))
        command = [os.environ["RECONCILE_BIN"], "apply", "--desired", str(document),
                   "--credential-file", credential, "--endpoint", endpoint,
                   "--state-dir", str(directory), "--plan-file", str(approval)]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            for _ in range(60):
                if len(observer.snapshot()["monitors"]) == 2:
                    break
                time.sleep(0.05)
            self.assertEqual(len(observer.snapshot()["monitors"]), 2)
            overlapping = subprocess.run(command, text=True, capture_output=True, timeout=10)
            self.assertIn("locked", overlapping.stderr)
        finally:
            process.kill()
            process.communicate(timeout=10)
        restarted = subprocess.run(command, text=True, capture_output=True, timeout=15)
        self.assertEqual(restarted.returncode, 1)
        self.assertIn("unresolved-intent", restarted.stderr)
        self.assertEqual(len(observer.snapshot()["monitors"]), 2)
        self.assertTrue(json.loads((directory / "ownership.json").read_text())["intents"])
        self.assertNotIn("RECONCILE_FORBIDDEN:", (self.root / "killed-apply/server.log").read_text())

    def test_latest_unmanaged_fields_survive_edit(self):
        planner, desired, directory, state = self.apply_inputs("latest")
        client = self.client()
        outer = client.create_monitor(self.payload("outer-latest", "group"))
        group = client.create_monitor(self.payload("apply-latest", "group", parent=outer))
        desired["checks"][0]["target"]["hostname"] = "127.0.0.2"
        notification = self.raw.call("addNotification", ({
            "name": "apply-existing-notification", "type": "webhook", "webhookURL": self.endpoint,
            "isDefault": False, "active": False}, None), timeout=10)
        self.assertTrue(notification["ok"])
        monitor = client.create_monitor(self.payload("node-latest", "ping", parent=group,
            hostname="127.0.0.2", interval=77, maxretries=0,
            notificationIDList={str(notification["id"]): True}))
        beats = []
        for _ in range(40):
            beats = self.raw.call("getMonitorBeats", (monitor, 24), timeout=10)["data"]
            if beats:
                break
            time.sleep(0.5)
        self.assertTrue(beats)
        self.assertTrue(self.raw.call("pauseMonitor", monitor, timeout=10)["ok"])
        desired["adoptions"] = {
            "group:example": {"id": group, "type": "group", "name": "apply-latest"},
            "node:one": {"id": monitor, "type": "ping", "name": "node-latest",
                         "target": {"hostname": "127.0.0.2"}}}
        desired["checks"][0]["name"] = "renamed-latest"
        seal(desired)
        stale = planner.build_plan(desired, client.snapshot(), state)
        client.edit_monitor({"id": monitor, "description": "latest private setting"})
        with self.assertRaisesRegex(planner.PlanError, "stale"):
            planner.apply_plan(stale, desired, client, directory)
        plan = planner.build_plan(desired, client.snapshot(), state)
        before = client.get_monitor(monitor)
        listed = next(m for m in client.snapshot()["monitors"] if m["id"] == monitor)
        self.assertEqual({k for k in listed if listed[k] != before[k]}, {"path", "pathName"})
        planner.apply_plan(plan, desired, client, directory)
        after = client.get_monitor(monitor)
        self.assertEqual(after["name"], "renamed-latest")
        self.assertTrue(after["notificationIDList"])
        for field in ("description", "interval", "notificationIDList", "active", "parent", "id"):
            self.assertEqual(before[field], after[field], field)
        self.assertEqual(client.get_monitor(group)["parent"], outer)
        history = self.raw.call("getMonitorBeats", (monitor, 24), timeout=10)["data"]
        self.assertTrue(all(beat in history for beat in beats))

    def test_apply_cli_authorization_state_loss_and_dry_run(self):
        planner, desired, directory, state = self.apply_inputs("stale")
        # Distinct from the stale-plan case, which runs later in this fixture.
        desired["groups"][0]["name"] = "cli-apply-group"
        desired["checks"][0].update(name="cli-apply-node", target={"hostname": "192.0.2.211"})
        desired_path = self.root / "apply-desired.json"
        desired_path.write_text(json.dumps(seal(desired)))
        review = self.root / "apply-review.json"
        options = ["--desired", str(desired_path), "--credential-file", self.credential,
                   "--endpoint", self.endpoint, "--state-dir", str(directory)]

        def invoke(mode, *extra):
            return subprocess.run([os.environ["RECONCILE_BIN"], mode, *options, *extra],
                                  text=True, capture_output=True, timeout=60)

        before = self.client().snapshot()
        result = invoke("reconcile", "--authorize-ongoing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("bootstrap-required", result.stderr)
        self.assertEqual(self.client().snapshot(), before)
        result = invoke("plan", "--output", str(review))
        self.assertEqual(result.returncode, 0, result.stderr)
        result = invoke("apply", "--plan-file", str(review))
        self.assertEqual(result.returncode, 0, result.stderr)
        before = self.client().snapshot()
        result = invoke("apply", "--plan-file", str(review))
        self.assertEqual(result.returncode, 1)
        self.assertIn("stale-plan", result.stderr)
        self.assertEqual(self.client().snapshot(), before)
        result = invoke("reconcile")
        self.assertEqual(result.returncode, 1)
        self.assertIn("authorization", result.stderr)
        result = invoke("plan", "--output", str(review))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(review.read_text())["operations"], [])
        self.assertEqual(self.client().snapshot(), before)
        result = invoke("reconcile", "--authorize-ongoing")
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = directory / "ownership.json"
        saved.unlink()
        result = invoke("reconcile", "--authorize-ongoing")
        self.assertIn("bootstrap-required", result.stderr)
        result = invoke("plan", "--output", str(review))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.client().snapshot(), before)
        self.assertNotIn("RECONCILE_FORBIDDEN:", (self.root / "real/server.log").read_text())

    def test_concurrent_edit_aborts_before_next_write(self):
        planner, desired, directory, state = self.apply_inputs("persist")
        desired["groups"][0]["name"] = "concurrent-group"
        desired["checks"][0].update(name="concurrent-node", target={"hostname": "192.0.2.212"})
        client = self.client()
        group = client.create_monitor(self.payload("concurrent-group", "group"))
        desired["adoptions"] = {"group:example": {"id": group, "type": "group", "name": "concurrent-group"}}
        seal(desired)
        plan = planner.build_plan(desired, client.snapshot(), state)
        original = planner._save_state

        def edit_after_adoption(path, saved):
            original(path, saved)
            client.edit_monitor({"id": group, "description": "concurrent UI setting"})

        with patch.object(planner, "_save_state", edit_after_adoption):
            with self.assertRaisesRegex(planner.PlanError, "baseline-drift"):
                planner.apply_plan(plan, desired, client, directory)
        self.assertFalse(any(m["name"] == "concurrent-node" for m in client.snapshot()["monitors"]))
        self.assertFalse(json.loads((directory / "ownership.json").read_text())["bootstrapComplete"])

    def test_deadline_leaves_durable_intent(self):
        planner, desired, directory, state = self.apply_inputs("lost")
        client = self.client()
        plan = planner.build_plan(desired, client.snapshot(), state)
        original = client.create_monitor

        def blocked(payload):
            # Start the injected short deadline at the controlled failure
            # window, not during variable real snapshot/durable-fsync setup.
            signal.setitimer(signal.ITIMER_REAL, 0.3)
            time.sleep(2)
            return original(payload)

        before = client.snapshot()
        with patch.object(client, "create_monitor", blocked):
            try:
                with self.assertRaisesRegex(planner.PlanError, "deadline"):
                    planner.apply_plan(plan, desired, client, directory)
            finally:
                signal.setitimer(signal.ITIMER_REAL, 0)
        self.assertEqual(before, self.client().snapshot())
        self.assertTrue(json.loads((directory / "ownership.json").read_text())["intents"])

    def test_edit_during_intent_persistence_aborts(self):
        planner, desired, directory, state = self.apply_inputs("latest")
        client = self.client()
        desired["groups"][0]["name"] = "intent-group"
        desired["checks"][0].update(name="intent-renamed", target={"hostname": "192.0.2.213"})
        group = client.create_monitor(self.payload("intent-group", "group"))
        monitor = client.create_monitor(self.payload("intent-original", "ping", parent=group,
                                                     hostname="192.0.2.213"))
        state["owned"] = {"group:example": {"id": group, "type": "group"},
                          "node:one": {"id": monitor, "type": "ping"}}
        state["origin"] = self.endpoint
        directory.mkdir(mode=0o700)
        planner._save_state(directory, state)
        seal(desired)
        plan = planner.build_plan(desired, client.snapshot(), state)
        original = planner._save_state

        def edit_after_intent(path, saved):
            original(path, saved)
            if saved["intents"]:
                client.edit_monitor({"id": monitor, "description": "changed during fsync"})

        with patch.object(planner, "_save_state", edit_after_intent):
            with self.assertRaisesRegex(planner.PlanError, "baseline-drift"):
                planner.apply_plan(plan, desired, client, directory)
        self.assertEqual(client.get_monitor(monitor)["name"], "intent-original")
        self.assertEqual(client.get_monitor(monitor)["description"], "changed during fsync")
        self.assertTrue(json.loads((directory / "ownership.json").read_text())["intents"])

    def test_ongoing_sites_domain_boundary_and_policy_reapproval(self):
        planner, desired, directory, state = self.apply_inputs("repeat")
        desired["groups"] = [{"key": "group:zone", "name": "approved.invalid"}]
        desired["checks"] = []
        client = self.client()
        seal(desired)
        planner.apply_plan(planner.build_plan(desired, client.snapshot(), state), desired, client, directory)
        desired["checks"] = [{"key": "site:new", "name": "new-approved-site", "type": "http",
                              "parentKey": "group:zone", "target": {"url": "https://new.approved.invalid/"}}]
        seal(desired)
        planner.reconcile(desired, client, directory, authorize_ongoing=True)
        saved = json.loads((directory / "ownership.json").read_text())
        new = client.get_monitor(saved["owned"]["site:new"]["id"])
        for field, value in {"interval": 60, "timeout": 10, "maxretries": 2, "retryInterval": 30,
                             "method": "GET", "ignoreTls": False, "maxredirects": 10,
                             "accepted_statuscodes": ["200-299"], "notificationIDList": {}}.items():
            self.assertEqual(new[field], value, field)
        before = client.snapshot()
        desired["checks"][0]["target"]["url"] = "https://notapproved.invalid/"
        seal(desired)
        with self.assertRaisesRegex(planner.PlanError, "policy-reapproval"):
            planner.reconcile(desired, client, directory, authorize_ongoing=True)
        self.assertEqual(before, client.snapshot())
        desired["policy"]["notificationPolicy"] = {"notificationIDList": {"99": False}}
        seal(desired)
        with self.assertRaisesRegex(planner.PlanError, "policy-reapproval"):
            planner.reconcile(desired, client, directory, authorize_ongoing=True)
        plan = planner.build_plan(desired, client.snapshot(), saved)
        planner.apply_plan(plan, desired, client, directory)
        # Explicit manual reapproval can change policy; it still does not bypass
        # zone restrictions for unattended work on the next invocation.
        with self.assertRaisesRegex(planner.PlanError, "policy-reapproval"):
            planner.reconcile(desired, client, directory, authorize_ongoing=True)

    def test_snapshot_includes_paused_monitor(self):
        client = self.client()
        active = client.create_monitor(self.payload("active"))
        paused = client.create_monitor(self.payload("paused", active=False))
        snapshot = client.snapshot()
        self.assertEqual(snapshot["version"], "2.5.6")
        monitors = {m["id"]: m for m in snapshot["monitors"]}
        self.assertTrue(monitors[active]["active"])
        self.assertFalse(monitors[paused]["active"])
        # Reconnecting with pre-existing monitors must not lose pre-ack events.
        self.assertEqual({m["id"] for m in self.client().snapshot()["monitors"]}, set(monitors))
        raw = self.raw_client(self.endpoint)
        self.addCleanup(raw.disconnect)
        self.assertTrue(raw.call("login", {"username": "contract", "password": PASSWORD}, timeout=10)["ok"])
        events = raw.contract_events
        self.assertNotIn("version", events[0][1][0])
        names = [event for event, _ in events]
        self.assertLess(names.index("monitorList"), names.index("heartbeatList"))
        inventory = next(args[0] for event, args in events if event == "monitorList")
        self.assertIn(str(paused), inventory)
        print("Observed pre-login-ack event order:", names, flush=True)

    def test_plan_cli_real_server_no_writes_and_no_claims(self):
        client = self.client()
        group = client.create_monitor(self.payload("cli-adoption", "group", parent=None,
                                                   description="CLI-PRIVATE-SENTINEL"))
        desired = desired_document()
        desired["groups"][0]["name"] = "cli-adoption"
        desired["adoptions"]["group:example"] = {"id": group, "type": "group", "name": "cli-adoption"}
        desired_path = self.root / "desired.json"
        desired_path.write_text(json.dumps(seal(desired)))
        state_dir = self.root / "plan-state"
        state_dir.mkdir(mode=0o700)
        output = self.root / "review.json"
        before = client.snapshot()
        command = [os.environ.get("RECONCILE_BIN", ""), "plan", "--desired", str(desired_path),
                   "--credential-file", self.credential, "--endpoint", self.endpoint,
                   "--state-dir", str(state_dir), "--output", str(output)]
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        plan = json.loads(output.read_text())
        self.assertTrue(plan["valid"])
        self.assertEqual([(o["action"], o["key"]) for o in plan["operations"]],
                         [("adopt", "group:example"), ("create", "node:one")])
        self.assertEqual(client.snapshot(), before)
        self.assertEqual([p.name for p in state_dir.iterdir()], ["lock"])
        self.assertNotIn(PASSWORD, result.stdout + result.stderr + output.read_text())
        self.assertNotIn("CLI-PRIVATE-SENTINEL", result.stdout + result.stderr + output.read_text())
        first = output.read_bytes()
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(first, output.read_bytes())
        desired["checks"][0]["target"] = {"hostname": "127.0.0.1"}
        desired_path.write_text(json.dumps(seal(desired)))
        client.create_monitor(self.payload("cli-paused", "ping", active=False))
        before = client.snapshot()
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(json.loads(output.read_text())["operations"], [])
        self.assertEqual(client.snapshot(), before)
        desired_path.write_text("not json")
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 1)

    def test_plan_cli_state_lock_output_and_auth_errors(self):
        desired = self.root / "errors-desired.json"
        desired.write_text(json.dumps(desired_document()))
        state_dir = self.root / "errors-state"
        state_dir.mkdir(mode=0o700)
        command = [os.environ["RECONCILE_BIN"], "plan", "--desired", str(desired),
                   "--credential-file", self.credential, "--endpoint", self.endpoint,
                   "--state-dir", str(state_dir)]
        state = state_dir / "ownership.json"
        state.symlink_to(state_dir / "missing.json")
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), "error: state")
        state.unlink()
        state.write_text(json.dumps({"schemaVersion": 2, "origin": self.endpoint,
                                     "bootstrapComplete": False, "owned": {}, "intents": {}}))
        state.chmod(0o600)
        before = state.read_bytes()
        state.chmod(0o644)
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), "error: state")
        state.chmod(0o600)
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(state.read_bytes(), before)
        self.assertEqual(sorted(p.name for p in state_dir.iterdir()), ["lock", "ownership.json"])
        with open(state_dir / "lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            result = subprocess.run(command, text=True, capture_output=True, timeout=60)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stderr.strip(), "error: locked")
        result = subprocess.run(command + ["--output", str(state)], text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(state.read_bytes(), before)
        state.write_text('{"schemaVersion":999}')
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), "error: state")
        state.write_bytes(before)
        bad = self.write_credential("cli-bad.json", {"origin": self.endpoint,
            "caFile": str(self.ca), "username": "contract", "password": "AUTH-PRIVATE-SENTINEL"})
        command[command.index("--credential-file") + 1] = bad
        result = subprocess.run(command, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("AUTH-PRIVATE-SENTINEL", result.stdout + result.stderr)

    def test_connection_waits_for_initial_info(self):
        endpoint = self.start_server("delayed", fault="delayed-info")
        raw = self.raw_client(endpoint)
        self.addCleanup(raw.disconnect)
        self.assertTrue(raw.call("setup", ("contract", PASSWORD), timeout=10)["ok"])
        path = self.write_credential("delayed.json", {
            "origin": endpoint, "caFile": str(self.ca), "username": "contract", "password": PASSWORD,
        })
        self.assertEqual(self.client(path, endpoint).snapshot(),
                         {"origin": endpoint, "version": "2.5.6", "monitors": []})

    def test_ack_timeout_never_retries_mutation(self):
        endpoint = self.start_server("lost-ack", fault="lost-ack")
        raw = self.raw_client(endpoint)
        self.addCleanup(raw.disconnect)
        self.assertTrue(raw.call("setup", ("contract", PASSWORD), timeout=10)["ok"])
        self.assertTrue(raw.call("login", {"username": "contract", "password": PASSWORD}, timeout=10)["ok"])
        path = self.write_credential("lost-ack.json", {
            "origin": endpoint, "caFile": str(self.ca), "username": "contract", "password": PASSWORD,
        })
        client = self.client(path, endpoint)
        start = time.monotonic()
        with self.assertRaisesRegex(self.module.KumaError, "timeout"):
            client.create_monitor(self.payload("uncertain"))
        self.assertLess(time.monotonic() - start, 12)
        with self.assertRaisesRegex(self.module.KumaError, "closed"):
            client.create_monitor(self.payload("must-not-retry"))
        lists = []
        raw.on("monitorList", lists.append)
        self.assertTrue(raw.call("getMonitorList", timeout=10)["ok"])
        self.assertEqual([m["name"] for m in lists[-1].values()], ["uncertain"])

    def test_server_version_and_auth_fail_closed(self):
        before = self.client().snapshot()["monitors"]
        for credentials in [
            {"username": "contract", "password": "wrong"},
            {"loginToken": "invalid"},
            {"loginToken": "invalid", "username": "contract", "password": PASSWORD},
        ]:
            path = self.write_credential("invalid.json", {
                "origin": self.endpoint, "caFile": str(self.ca), **credentials,
            })
            with self.assertRaises(self.module.KumaError):
                self.client(path).create_monitor(self.payload("must-not-exist"))
        self.assertEqual(before, self.client().snapshot()["monitors"])
        wrong = self.start_server("version", "2.5.7")
        raw = self.raw_client(wrong)
        self.addCleanup(raw.disconnect)
        self.assertTrue(raw.call("setup", ("contract", PASSWORD), timeout=10)["ok"])
        self.assertTrue(raw.call("login", {"username": "contract", "password": PASSWORD}, timeout=10)["ok"])
        path = self.write_credential("version.json", {
            "origin": wrong, "caFile": str(self.ca), "username": "contract", "password": PASSWORD,
        })
        with self.assertRaisesRegex(self.module.KumaError, "version"):
            self.client(path, wrong).create_monitor(self.payload("wrong-version"))
        lists = []
        raw.on("monitorList", lists.append)
        self.assertTrue(raw.call("getMonitorList", timeout=10)["ok"])
        self.assertEqual(lists[-1], {})

    def test_edit_preserves_unrelated_fields_and_history(self):
        client = self.client()
        notification = self.raw.call("addNotification", ({
            "name": "disposable", "type": "webhook", "webhookURL": self.endpoint,
            "isDefault": False, "active": False,
        }, None), timeout=10)
        self.assertTrue(notification["ok"], notification)
        monitor = client.create_monitor(self.payload("history", notificationIDList={str(notification["id"]): True}))
        beats = []
        for _ in range(40):
            beats = self.raw.call("getMonitorBeats", (monitor, 24), timeout=10)["data"]
            if beats:
                break
            time.sleep(0.5)
        self.assertTrue(beats, "real heartbeat must exist before edit")
        self.assertTrue(self.raw.call("pauseMonitor", monitor, timeout=10)["ok"])
        before = client.get_monitor(monitor)
        client.edit_monitor({"id": monitor, "name": "renamed only"})
        after = client.get_monitor(monitor)
        self.assertEqual(after["name"], "renamed only")
        for field in ("id", "notificationIDList", "active", "url", "interval", "ignoreTls", "parent"):
            self.assertEqual(before[field], after[field], field)
        self.assertTrue(after["notificationIDList"])
        self.assertFalse(after["active"])
        history = self.raw.call("getMonitorBeats", (monitor, 24), timeout=10)["data"]
        self.assertTrue(all(beat in history for beat in beats))

    def test_group_http_ping_and_token(self):
        path = self.write_credential("token.json", {
            "origin": self.endpoint, "caFile": str(self.ca), "loginToken": self.login["token"],
        })
        client = self.client(path)
        group = client.create_monitor(self.payload("group", "group"))
        client.edit_monitor({"id": group, "name": "renamed group"})
        self.assertEqual(client.get_monitor(group)["name"], "renamed group")
        for kind in ("http", "ping"):
            monitor = client.create_monitor(self.payload(kind, kind, parent=group))
            actual = client.get_monitor(monitor)
            self.assertEqual(actual["type"], kind)
            self.assertEqual(actual["parent"], group)
            beats = []
            for _ in range(40):
                beats = self.raw.call("getMonitorBeats", (monitor, 24), timeout=10)["data"]
                if beats:
                    break
                time.sleep(0.5)
            self.assertTrue(beats, f"{kind} must actually execute")
            self.assertEqual(beats[-1]["status"], 1, f"{kind}: {beats[-1]}")

    def test_origin_and_tls_fail_closed(self):
        for endpoint in ("http://127.0.0.1", self.endpoint + "?secret=x", self.endpoint + "#x",
                         self.endpoint + "?", self.endpoint + "#", self.endpoint + "/extra",
                         self.endpoint.replace("//", "//user:password@"), "https://example.invalid"):
            with self.assertRaisesRegex(self.module.KumaError, "origin"):
                self.client(endpoint=endpoint)
        path = self.write_credential("untrusted.json", {
            "origin": self.endpoint, "username": "contract", "password": PASSWORD,
        })
        with self.assertRaises(self.module.KumaError):
            self.client(path)

    def test_mfa_account_requires_operator_token(self):
        endpoint = self.start_server("mfa")
        raw = self.raw_client(endpoint)
        self.addCleanup(raw.disconnect)
        self.assertTrue(raw.call("setup", ("contract", PASSWORD), timeout=10)["ok"])
        login = raw.call("login", {"username": "contract", "password": PASSWORD}, timeout=10)
        self.assertTrue(login["ok"])
        preparation = raw.call("prepare2FA", PASSWORD, timeout=10)
        self.assertTrue(preparation["ok"])
        self.assertTrue(raw.call("save2FA", PASSWORD, timeout=10)["ok"])
        path = self.write_credential("mfa.json", {
            "origin": endpoint, "caFile": str(self.ca), "username": "contract", "password": PASSWORD,
        })
        with self.assertRaisesRegex(self.module.KumaError, "auth"):
            self.client(path, endpoint).create_monitor(self.payload("forbidden"))
        self.assertTrue(raw.call("twoFAStatus", timeout=10)["status"])
        token = self.write_credential("mfa-token.json", {
            "origin": endpoint, "caFile": str(self.ca), "loginToken": login["token"],
        })
        self.assertEqual(self.client(token, endpoint).snapshot()["monitors"], [])
        self.assertTrue(raw.call("twoFAStatus", timeout=10)["status"])
        # Obtain a fresh token using the real challenge, not the old pre-MFA token.
        secret = parse_qs(urlsplit(preparation["uri"]).query)["secret"][0]
        key = base64.b32decode(secret + "=" * (-len(secret) % 8))
        digest = hmac.new(key, (int(time.time()) // 30).to_bytes(8, "big"), hashlib.sha1).digest()
        offset = digest[-1] & 15
        code = f"{(int.from_bytes(digest[offset:offset + 4], 'big') & 0x7fffffff) % 1000000:06d}"
        output = self.root / "mfa-provisioned.yaml"
        result, keys, transcript = self.provision(output, endpoint=endpoint, mfa=code)
        self.assertEqual(result, 0, transcript)
        document = json.loads(subprocess.check_output(
            ["sops", "decrypt", "--output-type", "json", str(output)],
            env={**os.environ, "SOPS_AGE_KEY_FILE": str(keys[0])}, stderr=subprocess.DEVNULL))
        credential = json.loads(document["kuma-reconciler-management"])
        self.assertEqual(set(credential), {"origin", "loginToken", "caFile"})
        path = self.write_credential("mfa-provisioned.json", credential)
        self.assertEqual(self.client(path, endpoint).snapshot()["monitors"], [])
        self.assertTrue(raw.call("twoFAStatus", timeout=10)["status"])

    def test_api_error_is_bounded_and_close_prevents_writes(self):
        client = self.client()
        with self.assertRaises(self.module.KumaError) as error:
            client.get_monitor(-1)
        self.assertEqual(str(error.exception), "api")
        before = client.snapshot()
        client.close()
        client.close()
        with self.assertRaisesRegex(self.module.KumaError, "closed"):
            client.create_monitor(self.payload("closed"))
        self.assertEqual(self.client().snapshot(), before)

    def test_phased_tls_upgrade_has_one_connection_budget(self):
        # Both phases are below the socket timeout, but together exceed the
        # connection budget. Real verified TLS, not a mocked connect call.
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        listener.settimeout(15)
        stopped = threading.Event()
        peer_closed = threading.Event()
        phases = []
        failures = []

        def serve():
            try:
                raw, _ = listener.accept()
                with raw:
                    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                    context.load_cert_chain(self.ca, self.key)
                    with context.wrap_socket(raw, server_side=True, do_handshake_on_connect=False) as tls:
                        tls.settimeout(10)
                        if stopped.wait(6):
                            return
                        tls.do_handshake()
                        phases.append("verified-tls")
                        headers = b""
                        while b"\r\n\r\n" not in headers:
                            chunk = tls.recv(4096)
                            if not chunk:
                                peer_closed.set()
                                return
                            headers += chunk
                        phases.append("upgrade-request")
                        # Remain cancellable while delaying the upgrade response.
                        readable, _, _ = select.select([tls], [], [], 6)
                        if readable and tls.recv(4096) == b"":
                            peer_closed.set()
                            return
                        tls.sendall(b"HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n")
            except (OSError, ssl.SSLError) as error:
                failures.append(type(error).__name__)

        thread = threading.Thread(target=serve)
        thread.start()

        def cleanup():
            stopped.set()
            listener.close()
            thread.join(timeout=16)
            self.assertFalse(thread.is_alive(), "phased-delay listener must exit")
        self.addCleanup(cleanup)
        endpoint = f"https://127.0.0.1:{listener.getsockname()[1]}"
        credential = self.write_credential("phased.json", {
            "origin": endpoint, "caFile": str(self.ca), "loginToken": "disposable",
        })
        children = Path(f"/proc/self/task/{os.getpid()}/children")
        before = children.read_text()
        start = time.monotonic()
        with self.assertRaises(self.module.KumaError) as error:
            self.client(credential, endpoint)
        elapsed = time.monotonic() - start
        print(f"Phased TLS/upgrade cancellation returned in {elapsed:.3f}s", flush=True)
        self.assertLess(elapsed, 10.75, "one budget must include connection cancellation and cleanup")
        self.assertEqual(error.exception.category, "timeout")
        self.assertTrue(peer_closed.wait(1), "expiry must close the actual TLS connection")
        self.assertEqual(phases, ["verified-tls", "upgrade-request"])
        self.assertEqual(failures, [])
        self.assertEqual(children.read_text(), before, "cancelled worker must be reaped")

    def test_transport_timeout(self):
        # A real TCP listener that never answers TLS: connection must be bounded.
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        self.addCleanup(listener.close)
        endpoint = f"https://127.0.0.1:{listener.getsockname()[1]}"
        path = self.write_credential("timeout.json", {
            "origin": endpoint, "caFile": str(self.ca), "loginToken": "disposable",
        })
        start = time.monotonic()
        with self.assertRaises(self.module.KumaError):
            self.client(path, endpoint)
        self.assertLess(time.monotonic() - start, 12)


if __name__ == "__main__":
    unittest.main(verbosity=2)
