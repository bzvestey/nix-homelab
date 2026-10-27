"""Acceptance of actual module services against the pinned disposable server."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shutil
import socket
import subprocess
import threading
import time

spec = importlib.util.spec_from_file_location("contracts", os.environ["CONTRACTS_FILE"])
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)
# Fix only the fixture's selected listen port to the module's test origin.
contracts.port = lambda: 8443
fixture = contracts.Contracts


def run(*args, success=True):
    result = subprocess.run(args, text=True, capture_output=True)
    assert (result.returncode == 0) == success, result.stdout + result.stderr
    return result.stdout


def start(unit, success=True):
    run("systemctl", "reset-failed")
    run("systemctl", "start", unit, success=success)
    print(unit, run("systemctl", "show", unit, "-p", "Result").strip(), flush=True)


try:
    fixture.setUpClass()
    shutil.copyfile(fixture.ca, "/run/kuma-test-ca.pem")
    Path("/run/kuma-test-ca.pem").chmod(0o644)
    credential = {"origin": fixture.endpoint, "caFile": "/run/kuma-test-ca.pem",
                  "loginToken": fixture.login["token"]}
    Path("/run/kuma-test.json").write_text(json.dumps(credential))
    Path("/run/kuma-test.json").chmod(0o600)
    client = fixture.module.KumaClient(fixture.endpoint, "/run/kuma-test.json")
    try:
        notification = fixture.raw.call("addNotification", ({
            "name": "service-preserved-notification", "type": "webhook", "webhookURL": fixture.endpoint,
            "isDefault": False, "active": False}, None), timeout=10)
        assert notification["ok"]
        group = client.create_monitor({"name": "nix-homelab", "type": "group",
            "accepted_statuscodes": [], "conditions": []})
        monitor = client.create_monitor({"name": "one", "type": "ping", "hostname": "127.0.0.1",
            "parent": group, "interval": 77, "timeout": 10, "maxretries": 2,
            "retryInterval": 30, "description": "preserve service settings",
            "accepted_statuscodes": [], "conditions": [],
            "notificationIDList": {str(notification["id"]): True}})
        assert (group, monitor) == (1, 2)
        for _ in range(60):
            beats = fixture.raw.call("getMonitorBeats", (monitor, 24), timeout=10)["data"]
            if beats:
                break
            time.sleep(0.5)
        assert beats, "fixture history must predate the hardened service"
        assert fixture.raw.call("pauseMonitor", monitor, timeout=10)["ok"]
        before = client.snapshot()
        state = Path("/var/lib/kuma-reconciler")
        start("kuma-reconciler.service")
        assert client.snapshot() == before, "timer dry-run wrote remote state"
        assert not (state / "ownership.json").exists()
        start("kuma-reconciler-ongoing.service", success=False)
        assert client.snapshot() == before, "ongoing bootstrapped without approval"
        start("kuma-reconciler-plan.service")
        plan = json.loads(Path("/var/lib/kuma-reconciler-review/plan.json").read_text())
        assert plan["valid"] and plan["operations"], "explicit review required"
        assert plan["schemaVersion"] == 2 and plan["origin"] == fixture.endpoint
        # Disposable fixture-only authorization, never automatic timer bootstrap.
        start("kuma-reconciler-bootstrap.service")
        owned = json.loads((state / "ownership.json").read_text())
        assert owned["bootstrapComplete"] and owned["acceptedPolicy"]
        assert owned["schemaVersion"] == 2 and owned["origin"] == fixture.endpoint
        assert owned["owned"]["node:one"]["id"] == monitor
        after = client.snapshot()
        for _ in range(2):
            start("kuma-reconciler-ongoing.service")
            assert client.snapshot() == after
        # Stored legacy/foreign namespaces fail in the actual hardened units,
        # including manual apply; never auto-bind old IDs to the current server.
        for invalid in ({k: v for k, v in owned.items() if k != "origin"},
                        dict(owned, origin="https://127.0.0.1:8444")):
            with (state / "lock").open("r+") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                (state / "ownership.json").write_text(json.dumps(invalid))
            for unit in ("kuma-reconciler.service", "kuma-reconciler-ongoing.service",
                         "kuma-reconciler-plan.service", "kuma-reconciler-bootstrap.service"):
                start(unit, success=False)
                assert client.snapshot() == after
        with (state / "lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            (state / "ownership.json").write_text(json.dumps(owned))
        original = next(m for m in before["monitors"] if m["id"] == monitor)
        current = next(m for m in after["monitors"] if m["id"] == monitor)
        for field in ("id", "interval", "description", "active", "notificationIDList", "parent"):
            assert current[field] == original[field], field
        history = fixture.raw.call("getMonitorBeats", (monitor, 24), timeout=10)["data"]
        assert all(beat in history for beat in beats)
        account = pwd.getpwnam("kuma-reconciler")
        assert state.stat().st_uid == account.pw_uid and state.stat().st_mode & 0o777 == 0o700
        # All manual/timer services contend on the CLI's same nonblocking flock.
        with (state / "lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            start("kuma-reconciler.service", success=False)
        # Direct assertion on the actual timer unit through the existing
        # node-exporter systemd collector, not just a journal/unit-text check.
        import requests
        for _ in range(30):
            metrics = requests.get("http://127.0.0.1:9100/metrics", timeout=5).text
            if 'node_systemd_unit_state{name="kuma-reconciler.service",state="failed",type="oneshot"} 1' in metrics:
                break
            time.sleep(0.5)
        else:
            raise AssertionError("failed reconciler absent from systemd monitoring")
        print("failed-unit collector: kuma-reconciler.service failed=1", flush=True)
        start("kuma-reconciler.service")
        marker = state / "mutation.pending"
        marker.write_text('{"schemaVersion":1}\n')
        marker.chmod(0o600)
        os.chown(marker, account.pw_uid, account.pw_gid)
        for unit in ("kuma-reconciler.service", "kuma-reconciler-ongoing.service",
                     "kuma-reconciler-plan.service", "kuma-reconciler-bootstrap.service"):
            start(unit, success=False)
            assert marker.exists(), "startup discarded independent recovery barrier"
            assert client.snapshot() == after
        # This marker was test-created, not an ambiguous mutation. Remove only
        # under the common lock; actual recovery remains an operator obligation.
        with (state / "lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            marker.unlink()
        # Force real systemd activation timeout while TLS waits on a blackhole;
        # production limits remain 150s and the unchanged CLI budget remains 120s.
        # Allow ARM parent/child startup, but cancel before transport's own 10s budget.
        listener = socket.socket()
        listener.bind(("127.0.0.1", 8444))
        listener.listen()
        peer = []
        connected = threading.Event()
        def accept():
            conn, _ = listener.accept()
            peer.append(conn)
            connected.set()
            while conn.recv(4096):
                pass
        thread = threading.Thread(target=accept, daemon=True)
        thread.start()
        dropin = Path("/run/systemd/system/kuma-reconciler.service.d")
        dropin.mkdir(parents=True)
        command = run("systemctl", "show", "kuma-reconciler.service", "-p", "ExecStart", "--value")
        # Read the generated argv instead of constructing a substitute program.
        argv = command.split("argv[]=")[1].split(" ;")[0]
        (dropin / "timeout.conf").write_text("[Service]\nTimeoutStartSec=5s\nExecStart=\nExecStart="
            + argv.replace(":8443", ":8444") + "\n")
        blackhole = dict(credential, origin="https://127.0.0.1:8444")
        Path("/run/kuma-test.json").write_text(json.dumps(blackhole))
        run("systemctl", "daemon-reload")
        started = time.monotonic()
        run("systemctl", "reset-failed")
        activation = subprocess.Popen(["systemctl", "start", "kuma-reconciler.service"],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        connected.wait(timeout=4)
        assert peer, "real child transport never reached TLS blackhole"
        processes = Path("/sys/fs/cgroup/system.slice/kuma-reconciler.service/cgroup.procs").read_text().split()
        assert len(processes) >= 2, "must exercise both parent and child transport"
        for pid in processes:
            status = Path(f"/proc/{pid}/status").read_text()
            assert f"Uid:\t{account.pw_uid}\t{account.pw_uid}" in status
            assert "NoNewPrivs:\t1" in status and "CapBnd:\t0000000000000000" in status
            for field in ("cmdline", "environ"):
                assert credential["loginToken"].encode() not in Path(f"/proc/{pid}/{field}").read_bytes()
        _, stderr = activation.communicate(timeout=8)
        assert activation.returncode != 0, stderr
        assert time.monotonic() - started < 8
        assert "timeout" in run("systemctl", "show", "kuma-reconciler.service", "-p", "Result")
        thread.join(timeout=5)
        assert peer and not thread.is_alive(), "transport survived service cancellation"
        listener.close()
        (dropin / "timeout.conf").unlink()
        Path("/run/kuma-test.json").write_text(json.dumps(credential))
        run("systemctl", "daemon-reload")
        start("kuma-reconciler.service")
        assert client.snapshot() == after
        assert credential["loginToken"] not in run("journalctl", "-u", "kuma-reconciler*", "--no-pager")
        print("parent/child: dedicated UID, no capabilities, NoNewPrivileges; token absent argv/env/journal", flush=True)
        print("real hardened services: dry-run/bootstrap/no-op/history/lock/barrier/timeout recovery OK", flush=True)
    finally:
        client.close()
finally:
    fixture.doClassCleanups()
