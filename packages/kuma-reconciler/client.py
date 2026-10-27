"""Pinned, synchronous Kuma 2.5.6 management boundary.

Private credential JSON binds credentials to an exact `origin` (HTTPS, no path).
Supply either `loginToken` or `username` and `password`, never both. Optional
`caFile` selects an explicit CA bundle; otherwise use the system trust store.
Snapshots are {"origin": canonical configured HTTPS origin, "version": "2.5.6",
"monitors": [full monitor dictionaries]}. Origin is local configuration verified
by TLS and credential binding, never server-supplied metadata.
Edit payloads are patches containing `id`; merge with a fresh getMonitor result
because upstream editMonitor replaces fields rather than applying a patch.
Instances are single-caller, disposable sessions, not durable mutation queues.
An uncertain mutation is NOT retried: downstream must re-read and reconcile.
"""

from copy import deepcopy
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import threading
import time
from urllib.parse import urlsplit

import requests
import socketio


class KumaError(Exception):
    """Only a bounded category is public; never include upstream error payloads."""

    def __init__(self, category):
        self.category = category
        super().__init__(category)


class _OriginSession(requests.Session):
    def __init__(self, origin, ca):
        super().__init__()
        self.origin = origin
        self.verify = ca
        self.trust_env = False

    def request(self, method, url, **kwargs):
        parts = urlsplit(url)
        if f"{parts.scheme}://{parts.netloc}" != self.origin:
            raise KumaError("origin")
        # No credential-bearing redirect, proxy inheritance, or TLS bypass.
        kwargs["allow_redirects"] = False
        kwargs["verify"] = self.verify
        return super().request(method, url, **kwargs)


class _SocketClient:
    def __init__(self, endpoint: str, credential_file: str):
        self._ready = False
        self._closed = False
        self._version = None
        self._monitors = None
        self._initial_info_event = threading.Event()
        self._info_event = threading.Event()
        self._list_event = threading.Event()
        try:
            parts = urlsplit(endpoint)
            if (parts.scheme != "https" or not parts.hostname or parts.username is not None
                    or parts.password is not None or "?" in endpoint or "#" in endpoint
                    or parts.path not in ("", "/") or parts.netloc.endswith(":")
                    or any(c.isspace() for c in endpoint) or parts.port == 0):
                raise ValueError
            host = parts.hostname.lower()
            if ":" in host:
                host = f"[{host}]"
            origin = "https://" + host + (f":{parts.port}" if parts.port not in (None, 443) else "")
        except (TypeError, ValueError):
            raise KumaError("origin") from None
        try:
            credentials = json.loads(Path(credential_file).read_text())
            if not isinstance(credentials, dict):
                raise ValueError
        except (OSError, ValueError):
            raise KumaError("credential") from None
        if credentials.get("origin") != origin:
            raise KumaError("origin")
        token_form = "loginToken" in credentials
        password_form = "username" in credentials or "password" in credentials
        fields = ("loginToken",) if token_form else ("username", "password")
        if token_form == password_form or any(
                not isinstance(credentials.get(key), str) or not credentials[key] for key in fields):
            raise KumaError("credential")
        ca = credentials.get("caFile", True)
        if ca is not True and (not isinstance(ca, str) or not ca):
            raise KumaError("credential")
        self._origin = origin
        self._session = _OriginSession(origin, ca)
        self._socket = socketio.Client(
            http_session=self._session, reconnection=False, request_timeout=10,
            logger=False, engineio_logger=False,
            websocket_extra_options={"redirect_limit": 0, "http_no_proxy": ["*"]},
        )
        # 2.5.6 emits the full inventory and authenticated info BEFORE login ack.
        self._socket.on("info", self._on_info)
        self._socket.on("monitorList", self._on_list)
        self._socket.on("disconnect", self._on_disconnect)
        try:
            connection_deadline = time.monotonic() + 10
            # Polling bursts from afterLogin exceed python-engineio's 16-packet
            # decoder limit with even a few monitors. WebSocket frames do not.
            self._socket.connect(origin, transports=["websocket"], wait=False)
            # Kuma's async connection handler awaits initial info BEFORE it
            # registers login handlers. Socket.IO connect alone is too early.
            if not self._initial_info_event.wait(max(0, connection_deadline - time.monotonic())):
                raise KumaError("timeout")
            _reply({"connected": True})
            if token_form:
                self._call("loginByToken", credentials["loginToken"], category="auth")
            else:
                self._call("login", {key: credentials[key] for key in fields}, category="auth")
            if not self._info_event.wait(10) or not self._list_event.wait(10):
                raise KumaError("timeout")
            if self._version != "2.5.6":
                raise KumaError("version")
            self._ready = True
        except KumaError:
            self.close()
            raise
        except Exception:
            self.close()
            raise KumaError("transport") from None

    def _on_info(self, data):
        self._initial_info_event.set()
        if isinstance(data, dict) and "version" in data:
            self._version = data["version"]
            self._info_event.set()

    def _on_list(self, data):
        if isinstance(data, dict) and all(isinstance(m, dict) for m in data.values()):
            self._monitors = deepcopy(list(data.values()))
            self._list_event.set()

    def _on_disconnect(self, *args):
        self._ready = False

    def _call(self, event, data=None, category="api"):
        try:
            ack = self._socket.call(event, data, timeout=10)
        except socketio.exceptions.TimeoutError:
            self._ready = False
            raise KumaError("timeout") from None
        except Exception:
            self._ready = False
            raise KumaError("transport") from None
        if not isinstance(ack, dict) or ack.get("ok") is not True:
            raise KumaError(category)
        return ack

    def _check_ready(self):
        if self._closed or not self._ready or not self._socket.connected:
            raise KumaError("closed")
        if self._version != "2.5.6":
            raise KumaError("version")

    def snapshot(self) -> dict:
        self._check_ready()
        self._list_event.clear()
        self._call("getMonitorList")
        if not self._list_event.wait(10):
            raise KumaError("timeout")
        return {"origin": self._origin, "version": self._version, "monitors": deepcopy(self._monitors)}

    def get_monitor(self, id: int) -> dict:
        self._check_ready()
        ack = self._call("getMonitor", id)
        if not isinstance(ack.get("monitor"), dict) or ack["monitor"].get("id") != id:
            raise KumaError("protocol")
        return deepcopy(ack["monitor"])

    def create_monitor(self, payload: dict) -> int:
        self._check_ready()
        ack = self._call("add", deepcopy(payload))
        if type(ack.get("monitorID")) is not int or ack["monitorID"] <= 0:
            self._ready = False
            raise KumaError("protocol")
        return ack["monitorID"]

    def edit_monitor(self, payload: dict) -> None:
        self._check_ready()
        if not isinstance(payload, dict) or type(payload.get("id")) is not int:
            raise KumaError("protocol")
        monitor = self.get_monitor(payload["id"])
        monitor.update(deepcopy(payload))
        self._call("editMonitor", monitor)

    def close(self) -> None:
        if not self._closed:
            self._ready = False
            self._closed = True
            try:
                self._socket.disconnect()
            finally:
                self._session.close()


def _reply(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def _worker():
    """One private pipe/session, not a reconnecting daemon or mutation queue."""
    client = None
    try:
        client = _SocketClient(**json.loads(sys.stdin.buffer.readline()))
        _reply({"result": None})
        for line in sys.stdin.buffer:
            try:
                request = json.loads(line)
                if request["method"] not in ("snapshot", "get_monitor", "create_monitor", "edit_monitor"):
                    raise KumaError("protocol")
                result = getattr(client, request["method"])(*request["args"])
                _reply({"result": result})
            except KumaError as error:
                _reply({"error": error.category})
    except KumaError as error:
        _reply({"error": error.category})
    except Exception:
        _reply({"error": "transport"})
    finally:
        if client is not None:
            client.close()


class KumaClient:
    """Own the blocking resolver/TLS stack in a killable, private subprocess.

    A thread cannot cancel libc DNS or a socket hidden inside synchronous
    websocket-client.connect. Killing this session closes ALL its descriptors
    and resolver/Socket.IO threads; no abandoned connector can later log in.
    The same worker retains the TLS session because it cannot safely be moved
    back to the caller after connection. Only the four public operations cross
    the pipe, without retries or persisted messages.
    """

    def __init__(self, endpoint: str, credential_file: str):
        self._closed = False
        self._process = None
        self._buffer = b""
        deadline = time.monotonic() + 10
        try:
            self._process = subprocess.Popen(
                [sys.executable, "-u", str(Path(__file__).resolve()), "--worker"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                bufsize=0, close_fds=True,
            )
            self._send({"endpoint": endpoint, "credential_file": credential_file})
            # Reserve bounded cleanup time INSIDE the absolute connection budget.
            if self._receive(deadline - 0.5) != {"connected": True}:
                raise KumaError("protocol")
            # Authentication keeps its separate upstream 10s ack deadline.
            self._receive(time.monotonic() + 30)
        except KumaError:
            self.close()
            raise
        except Exception:
            self.close()
            raise KumaError("transport") from None

    def _send(self, message):
        if self._closed:
            raise KumaError("closed")
        self._process.stdin.write((json.dumps(message) + "\n").encode())

    def _receive(self, deadline):
        while b"\n" not in self._buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self._process.stdout], [], [], remaining)[0]:
                self.close()
                raise KumaError("timeout")
            chunk = os.read(self._process.stdout.fileno(), 65536)
            if not chunk:
                self.close()
                raise KumaError("transport")
            self._buffer += chunk
        line, self._buffer = self._buffer.split(b"\n", 1)
        response = json.loads(line)
        if "error" in response:
            raise KumaError(response["error"])
        return response

    def _call(self, method, *args):
        try:
            self._send({"method": method, "args": args})
            return self._receive(time.monotonic() + 30)["result"]
        except KumaError:
            raise
        except Exception:
            self.close()
            raise KumaError("transport") from None

    def snapshot(self) -> dict:
        return self._call("snapshot")

    def get_monitor(self, id: int) -> dict:
        return self._call("get_monitor", id)

    def create_monitor(self, payload: dict) -> int:
        return self._call("create_monitor", payload)

    def edit_monitor(self, payload: dict) -> None:
        self._call("edit_monitor", payload)

    def close(self) -> None:
        if not self._closed:
            self._closed = True
            if self._process is not None:
                self._process.stdin.close()
                try:
                    self._process.wait(timeout=0.2)
                except subprocess.TimeoutExpired:
                    self._process.kill()
                    self._process.wait(timeout=0.3)
                finally:
                    self._process.stdout.close()


if __name__ == "__main__" and sys.argv[1:] == ["--worker"]:
    _worker()
