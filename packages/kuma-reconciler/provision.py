"""One-time interactive login; persist only SOPS-encrypted management JSON."""

import argparse
import getpass
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import sys
import threading
from urllib.parse import urlsplit
import warnings

import socketio

from client import KumaError, _OriginSession


def provision(args):
    parts = urlsplit(args.endpoint)
    if (parts.scheme != "https" or not parts.hostname or parts.username is not None
            or parts.password is not None or parts.path or "?" in args.endpoint
            or "#" in args.endpoint or parts.netloc.endswith(":")
            or any(c.isspace() for c in args.endpoint) or parts.port == 0):
        raise KumaError("origin")
    host = parts.hostname.lower()
    host = f"[{host}]" if ":" in host else host
    origin = "https://" + host + (f":{parts.port}" if parts.port not in (None, 443) else "")
    if args.endpoint != origin:
        raise KumaError("origin")
    if (len(set(args.recipient)) != 2 or len(args.recipient) != 2
            or any(not re.fullmatch(r"age1[0-9a-z]{58}", value) for value in args.recipient)):
        raise KumaError("recipients")
    output = Path(args.output)
    if output.exists() or output.is_symlink() or not output.parent.is_dir():
        raise KumaError("output")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    warnings.simplefilter("error", getpass.GetPassWarning)
    with open("/dev/tty", "w") as terminal:
        if not terminal.isatty():
            raise KumaError("terminal")
        username = getpass.getpass("Username: ", stream=terminal)
        password = getpass.getpass("Password: ", stream=terminal)
        if not username or not password:
            raise KumaError("credential")
        initial = threading.Event()
        authenticated_info = threading.Event()
        info = {}
        session = _OriginSession(origin, args.ca_file or True)
        client = socketio.Client(
            http_session=session, reconnection=False, request_timeout=10,
            logger=False, engineio_logger=False,
            websocket_extra_options={"redirect_limit": 0, "http_no_proxy": ["*"]},
        )

        @client.on("info")
        def receive_info(data):
            if isinstance(data, dict) and isinstance(data.get("version"), str):
                info["version"] = data["version"]
                authenticated_info.set()
            initial.set()

        try:
            client.connect(origin, transports=["websocket"], wait_timeout=10)
            if not initial.wait(10):
                raise KumaError("timeout")
            credentials = {"username": username, "password": password}
            reply = client.call("login", credentials, timeout=10)
            if isinstance(reply, dict) and reply.get("tokenRequired") is True:
                credentials["token"] = getpass.getpass("MFA code: ", stream=terminal)
                if not credentials["token"]:
                    raise KumaError("auth")
                reply = client.call("login", credentials, timeout=10)
            if (not isinstance(reply, dict) or reply.get("ok") is not True
                    or not isinstance(reply.get("token"), str) or not reply["token"]):
                raise KumaError("auth")
            if not authenticated_info.wait(10):
                raise KumaError("timeout")
            if info.get("version") != "2.5.6":
                raise KumaError("version")
            credential = {"origin": origin, "loginToken": reply["token"]}
            if args.ca_file:
                credential["caFile"] = args.ca_file
        finally:
            client.disconnect()
            session.close()
    # SOPS receives plaintext only on an anonymous pipe. Neither its diagnostics
    # nor upstream exception payloads may reach the terminal or a log.
    encrypted = subprocess.run(
        ["sops", "--config", "/dev/null", "encrypt", "--age", ",".join(args.recipient),
         "--input-type", "json", "--output-type", "yaml",
         "--filename-override", "kuma-management.yaml"],
        input=json.dumps({"kuma-reconciler-management": json.dumps(credential)}).encode(),
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30,
    )
    if encrypted.returncode != 0 or not encrypted.stdout:
        raise KumaError("encryption")
    # Never replace an existing credential, even if it appeared during login.
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as destination:
            destination.write(encrypted.stdout)
            destination.flush()
            os.fsync(destination.fileno())
    except BaseException:
        output.unlink()
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True, help="Exact canonical HTTPS origin")
    parser.add_argument("--output", required=True, help="New encrypted YAML file; never overwritten")
    parser.add_argument("--recipient", action="append", required=True,
                        help="Public age recipient; supply exactly administrator and target host")
    parser.add_argument("--ca-file", help="Trusted CA bundle for private-CA installations")
    args = parser.parse_args()
    try:
        provision(args)
    except KumaError as error:
        print(f"Provisioning failed ({error}); no usable credential published.", file=sys.stderr)
        return 1
    except (Exception, KeyboardInterrupt):
        print("Provisioning failed; no usable credential published.", file=sys.stderr)
        return 1
    print("Encrypted credential saved. No monitor writes or reconciler enablement performed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
