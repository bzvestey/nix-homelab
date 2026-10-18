"""Read existing private LocalAPI sockets; publish only bounded aggregate gauges."""
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

cli, destination, *identities = sys.argv[1:]
metrics = ["# TYPE " + name + " gauge" for name in (
    "tailscale_identity_online", "tailscale_peers_total", "tailscale_peer_online",
    "tailscale_status_collection_success", "tailscale_status_collection_timestamp_seconds",
)]
for entry in identities:
    identity, socket = entry.split("=", 1)
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", identity):
        raise ValueError("invalid configured identity")
    label = '{identity="' + identity + '"}'
    try:
        result = subprocess.run([cli, "--socket=" + socket, "status", "--json"],
                                check=True, capture_output=True, timeout=5)
        status = json.loads(result.stdout)
        state = status["BackendState"]
        if state not in ("Running", "Stopped", "NeedsLogin", "NeedsMachineAuth", "Starting", "NoState", "InUseOtherUser"):
            raise ValueError("invalid backend state")
        peers = status.get("Peer")
        if peers is None:
            peers = {}
        if not isinstance(peers, dict) or any(type(peer.get("Online")) is not bool for peer in peers.values()):
            raise ValueError("invalid peer state")
        online = (status.get("Self") or {}).get("Online")
        if state == "Running" and type(online) is not bool:
            raise ValueError("invalid self state")
        values = {
            "tailscale_identity_online": int(state == "Running" and online is True),
            "tailscale_peers_total": len(peers),
            "tailscale_peer_online": sum(peer["Online"] for peer in peers.values()),
        }
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, AttributeError):
        # Omit unknown values instead of turning collection failure into offline/zero.
        metrics.append("tailscale_status_collection_success" + label + " 0")
    else:
        metrics.append("tailscale_status_collection_success" + label + " 1")
        metrics.extend(name + label + " " + str(value) for name, value in values.items())
    metrics.append("tailscale_status_collection_timestamp_seconds" + label + " " + str(int(time.time())))

destination = pathlib.Path(destination)
with tempfile.NamedTemporaryFile(mode="w", dir=destination.parent, delete=False) as output:
    temporary = output.name
    output.write("\n".join(metrics) + "\n")
    output.flush()
    os.fchmod(output.fileno(), 0o644)
os.replace(temporary, destination)
