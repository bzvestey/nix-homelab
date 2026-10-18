"""Exercise the collector CLI with representative LocalAPI status responses.

No real enrollment: only the read-only tailscale command boundary is substituted.
"""
import json
import os
import pathlib
import subprocess
import sys
import tempfile

collector = sys.argv[1]
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    cli = root / "tailscale"
    cli.write_text('#!/bin/sh\ntest "$2" = status && test "$3" = --json && test "$#" = 3 || exit 2\ncat "$FIXTURE"\nexit "${STATUS:-0}"\n')
    cli.chmod(0o755)
    fixture = root / "status.json"
    output = root / "tailscale.prom"
    env = dict(os.environ, FIXTURE=str(fixture))

    def run(status, code="0"):
        fixture.write_text(json.dumps(status))
        subprocess.run([sys.executable, collector, str(cli), str(output),
                        "native=/run/tailscale/tailscaled.sock",
                        "foundry=/run/tailscale-foundry/tailscaled.sock"],
                       check=True, env=dict(env, STATUS=code))
        text = output.read_text()
        assert "secret-peer" not in text and "private-name" not in text
        return text

    running = {"BackendState": "Running", "Self": {"Online": True},
               "Peer": {"secret-peer": {"Online": True, "DNSName": "private-name"},
                        "other": {"Online": False}}}
    text = run(running)
    assert 'tailscale_status_collection_success{identity="native"} 1' in text
    assert 'tailscale_identity_online{identity="native"} 1' in text
    assert 'tailscale_peers_total{identity="native"} 2' in text
    assert 'tailscale_peer_online{identity="native"} 1' in text
    assert 'tailscale_peer_online{identity="foundry"} 1' in text
    text = run(dict(running, Peer={}))
    assert 'tailscale_peer_online{identity="native"} 0' in text
    assert 'tailscale_status_collection_success{identity="native"} 1' in text
    text = run({"BackendState": "Stopped", "Self": {"Online": False}, "Peer": None})
    assert 'tailscale_identity_online{identity="native"} 0' in text
    assert 'tailscale_peer_online{identity="native"} 0' in text
    assert 'tailscale_status_collection_success{identity="native"} 1' in text
    text = run({"BackendState": "NeedsLogin", "Self": None, "Peer": None})
    assert 'tailscale_identity_online{identity="native"} 0' in text
    assert 'tailscale_status_collection_success{identity="native"} 1' in text
    for value, code in [({}, "0"), (running, "1"),
                        (dict(running, Peer=[]), "0"),
                        ({"BackendState": "Running", "Peer": {"bad": {}}}, "0")]:
        text = run(value, code)
        assert 'tailscale_status_collection_success{identity="native"} 0' in text
        assert not any(line.startswith(("tailscale_peer_online{", "tailscale_identity_online{")) for line in text.splitlines())
