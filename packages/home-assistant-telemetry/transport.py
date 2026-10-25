"""Disposable HTTP transport: keep startup independent of the metrics runtime."""

from http.client import HTTPConnection, HTTPSConnection
import json
import sys
import time


def request_body(host, port, path, headers, secure=False):
    connection_class = HTTPSConnection if secure else HTTPConnection
    connection = connection_class(host, port, timeout=5)
    deadline = time.monotonic() + 5
    try:
        connection.request("GET", path, headers=headers)
        sock = connection.sock
        sock.settimeout(max(0.001, deadline - time.monotonic()))
        response = connection.getresponse()
        if response.status != 200:
            raise ValueError("upstream HTTP failure")
        # Never follow redirects, for either Supervisor or app credentials.
        # The parent also enforces the absolute deadline, including imports/DNS.
        body = bytearray()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("upstream timeout")
            sock.settimeout(remaining)
            chunk = response.read1(min(65536, 1048577 - len(body)))
            if not chunk:
                break
            body.extend(chunk)
            if len(body) > 1048576:
                raise ValueError("upstream response too large")
        return body
    finally:
        connection.close()


if __name__ == "__main__":
    try:
        sys.stdout.buffer.write(request_body(*json.load(sys.stdin)))
    except Exception:
        # Headers and payloads can contain credentials; emit no diagnostic data.
        sys.exit(1)
