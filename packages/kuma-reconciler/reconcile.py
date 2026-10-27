"""Kuma planner and explicitly authorized, fail-closed reconciliation.

Ownership v2: {schemaVersion: 2, origin: canonical HTTPS origin,
owned: {stableKey: {id: int, type: str}},
bootstrapComplete: bool, intents: {...}, acceptedPolicy?: {...}}. Nonempty
intents require operator recovery, never an automatic mutation retry.
Bootstrap completion is never inferred from claims or ongoing authorization.
Only a pristine in-memory state may have origin: null; persisted state is bound.
Plans contain desired patches and opaque live fingerprints, never live objects.
"""

import argparse
from contextlib import contextmanager
from copy import deepcopy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import tempfile
import time
from urllib.parse import urlsplit


class PlanError(Exception):
    """A bounded, non-sensitive input category."""


def _json(value):
    # Nix toJSON emits UTF-8, sorted attrs and compact separators. Manifest
    # validation excludes floats (Nix/Python float serialization differs).
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False)


def _digest(value):
    return hashlib.sha256(_json(value).encode("utf-8")).hexdigest()


def normalize_target(monitor: dict) -> tuple:
    """Only hostname case, HTTP default ports and empty root are normalized."""
    kind = monitor["type"]
    target = monitor.get("target", monitor)
    if kind == "group":
        return ("group", monitor["name"])
    if kind == "ping":
        hostname = target["hostname"]
        if not isinstance(hostname, str) or not hostname or any(c.isspace() for c in hostname):
            raise ValueError
        return ("ping", hostname)
    if kind != "http":
        raise ValueError
    url = target["url"]
    parts = urlsplit(url)
    if (parts.scheme not in ("http", "https") or not parts.hostname
            or parts.username is not None or parts.password is not None
            or "#" in url or any(c.isspace() for c in url)
            or parts.netloc.endswith(":")):
        raise ValueError
    return ("http", parts.scheme, parts.hostname.lower(),
            parts.port if parts.port is not None else (443 if parts.scheme == "https" else 80),
            parts.path or "/", "?" + parts.query if "?" in url else "")


def _key(key):
    return isinstance(key, str) and re.fullmatch(r"(?:group|node|site):[A-Za-z0-9._:-]{1,200}", key)


def _identity(item, group=False):
    if not isinstance(item, dict):
        raise ValueError
    kind = item.get("type", "group" if group else None)
    if kind not in ("group", "ping", "http"):
        raise ValueError
    if not isinstance(item.get("name"), str) or not item["name"] or len(item["name"]) > 256:
        raise ValueError
    result = dict(item, type=kind)
    if kind != "group":
        expected = "url" if kind == "http" else "hostname"
        if set(item["target"]) != {expected}:
            raise ValueError
    normalize_target(result)
    return result


def _validate_manifest(desired):
    if not isinstance(desired, dict) or set(desired) != {
            "schemaVersion", "digest", "groups", "checks", "adoptions", "policy"}:
        raise ValueError
    if type(desired["schemaVersion"]) is not int or desired["schemaVersion"] != 1:
        raise ValueError
    # Integer-only JSON matches the generator and avoids float canonicalization
    # ambiguity, including nested notification policy values.
    def json_types(value):
        if isinstance(value, dict):
            return all(isinstance(k, str) and json_types(v) for k, v in value.items())
        if isinstance(value, list):
            return all(json_types(v) for v in value)
        return value is None or type(value) in (str, int, bool)
    if not json_types(desired):
        raise ValueError
    if desired["digest"] != _digest({k: v for k, v in desired.items() if k != "digest"}):
        raise PlanError("manifest-digest")
    items = {}
    for section in ("groups", "checks"):
        if not isinstance(desired[section], list):
            raise ValueError
        for item in desired[section]:
            group = section == "groups"
            fields = {"key", "name"} if group else {"key", "name", "type", "parentKey", "target"}
            if set(item) != fields or not _key(item["key"]) or item["key"] in items:
                raise ValueError
            validated = _identity(item, group)
            if (validated["type"] == "group") != group:
                raise ValueError
            items[item["key"]] = validated
    groups = {k for k, v in items.items() if v["type"] == "group"}
    for item in items.values():
        if item["type"] != "group" and item["parentKey"] not in groups:
            raise ValueError
    names = [v["name"] for v in items.values()]
    if len(names) != len(set(names)):
        raise ValueError
    for kind in ("group", "ping", "http"):
        targets = [normalize_target(v) for v in items.values() if v["type"] == kind]
        if len(targets) != len(set(targets)):
            raise ValueError
    if not isinstance(desired["adoptions"], dict):
        raise ValueError
    ids = []
    for key, anchor in desired["adoptions"].items():
        if not _key(key) or set(anchor) != ({"id", "type", "name"} if anchor.get("type") == "group"
                                           else {"id", "type", "name", "target"}):
            raise ValueError
        _identity(anchor)
        if type(anchor["id"]) is not int or anchor["id"] <= 0:
            raise ValueError
        ids.append(anchor["id"])
    if len(ids) != len(set(ids)):
        raise ValueError
    policy = desired["policy"]
    if not isinstance(policy, dict) or set(policy) != {"newChecks", "notificationPolicy"}:
        raise ValueError
    common = {"interval": 60, "timeout": 10, "maxretries": 2, "retryInterval": 30}
    if policy["newChecks"] != {"ping": common, "http": dict(
            common, method="GET", ignoreTls=False, maxredirects=10, accepted_statuscodes=["200-299"])}:
        raise ValueError
    if policy["notificationPolicy"] is not None and not isinstance(policy["notificationPolicy"], dict):
        raise ValueError
    return items


def _validate_origin(origin):
    """Validate the canonical local-origin contract without importing transport."""
    if not isinstance(origin, str) or any(c.isspace() for c in origin):
        raise ValueError
    parts = urlsplit(origin)
    host = parts.hostname
    if not host:
        raise ValueError
    authority = f"[{host}]" if ":" in host else host
    if parts.port not in (None, 443):
        authority += f":{parts.port}"
    if parts.port == 0 or origin != "https://" + authority:
        raise ValueError


def _validate_state(state):
    if (not isinstance(state, dict) or set(state) not in (
            {"schemaVersion", "origin", "bootstrapComplete", "owned", "intents"},
            {"schemaVersion", "origin", "bootstrapComplete", "owned", "intents", "acceptedPolicy"})
            or type(state["schemaVersion"]) is not int or state["schemaVersion"] != 2
            or type(state["bootstrapComplete"]) is not bool
            or not isinstance(state["owned"], dict) or not isinstance(state["intents"], dict)):
        raise ValueError
    if state["origin"] is None:
        if state["bootstrapComplete"] or state["owned"] or state["intents"] or "acceptedPolicy" in state:
            raise ValueError
    else:
        _validate_origin(state["origin"])
    ids = []
    for key, record in state["owned"].items():
        if (not _key(key) or not isinstance(record, dict) or set(record) != {"id", "type"}
                or type(record["id"]) is not int or record["id"] <= 0
                or record["type"] not in ("group", "ping", "http")):
            raise ValueError
        ids.append(record["id"])
    if len(ids) != len(set(ids)):
        raise ValueError
    for key, intent in state["intents"].items():
        if (not _key(key) or not isinstance(intent, dict)
                or set(intent) != {"action", "type", "id", "inventoryDigest", "baseline"}
                or intent["action"] not in ("create", "update")
                or intent["type"] not in ("group", "ping", "http")
                or (intent["id"] is not None and (type(intent["id"]) is not int or intent["id"] <= 0))
                or (intent["action"] == "update" and intent["id"] is None)
                or not isinstance(intent["inventoryDigest"], str)
                or not re.fullmatch("[0-9a-f]{64}", intent["inventoryDigest"])
                or (intent["baseline"] is not None and (not isinstance(intent["baseline"], str)
                    or not re.fullmatch("[0-9a-f]{64}", intent["baseline"])))):
            raise ValueError
        if intent["action"] == "create":
            if key in state["owned"] or intent["id"] is not None or intent["baseline"] is not None:
                raise ValueError
        elif (state["owned"].get(key) != {"id": intent["id"], "type": intent["type"]}
              or intent["baseline"] is None):
            raise ValueError
    if "acceptedPolicy" in state:
        policy = state["acceptedPolicy"]
        if (not isinstance(policy, dict) or set(policy) != {"groups", "nodeParents", "adoptions", "policy"}
                or not isinstance(policy["groups"], list) or not isinstance(policy["nodeParents"], list)):
            raise ValueError
        # Reuse strict manifest validation rather than accept an opaque blob.
        document = {"schemaVersion": 1, "groups": policy["groups"], "checks": [],
                    "adoptions": policy["adoptions"], "policy": policy["policy"]}
        document["digest"] = _digest(document)
        _validate_manifest(document)
        group_keys = {g["key"] for g in policy["groups"]}
        if (any(not isinstance(k, str) or k not in group_keys for k in policy["nodeParents"])
                or len(set(policy["nodeParents"])) != len(policy["nodeParents"])):
            raise ValueError


def build_plan(desired: dict, live: dict, ownership: dict) -> dict:
    """Pure plan; live requires the client's canonical configured `origin`."""
    plan = {"schemaVersion": 2, "origin": None, "valid": False, "inventoryDigest": None,
            "adoptionDigest": None, "ownershipDigest": None, "liveIdentityDigest": None,
            "fingerprints": {}, "operations": [], "conflicts": [], "removals": []}

    def conflict(category, key=None):
        item = {"category": category}
        if key is not None:
            item["key"] = key
        if item not in plan["conflicts"]:
            plan["conflicts"].append(item)

    try:
        items = _validate_manifest(desired)
        plan["inventoryDigest"] = desired["digest"]
        plan["adoptionDigest"] = _digest(desired["adoptions"])
    except PlanError as error:
        conflict(str(error))
        return plan
    except (ValueError, TypeError, KeyError, AttributeError):
        conflict("manifest")
        return plan
    try:
        _validate_state(ownership)
        plan["ownershipDigest"] = _digest(ownership)
    except (ValueError, TypeError, KeyError):
        conflict("state")
        return plan
    # Reject a foreign namespace BEFORE interpreting any monitor IDs.
    try:
        _validate_origin(live["origin"])
        plan["origin"] = live["origin"]
    except (ValueError, TypeError, KeyError, AttributeError):
        conflict("origin")
        return plan
    if ownership["origin"] is not None and ownership["origin"] != live["origin"]:
        conflict("origin")
        return plan
    if ownership["intents"]:
        conflict("unresolved-intent")
    try:
        if live["version"] != "2.5.6":
            conflict("unsupported-version")
        monitors = live["monitors"]
        if not isinstance(monitors, list):
            raise ValueError
        by_id = {}
        for monitor in monitors:
            id = monitor["id"]
            if type(id) is not int or id <= 0 or id in by_id:
                raise ValueError
            if not isinstance(monitor["type"], str) or not isinstance(monitor["name"], str):
                raise ValueError
            # Unknown monitor types remain unmanaged, but their names still
            # participate in collision checks. Known types require valid targets.
            if monitor["type"] in ("group", "ping", "http"):
                normalize_target(monitor)
            by_id[id] = monitor
        identities = [{"id": id, "type": m["type"], "name": m["name"],
                       "target": normalize_target(m) if m["type"] in ("group", "ping", "http") else None}
                      for id, m in sorted(by_id.items())]
        plan["liveIdentityDigest"] = _digest({"origin": live["origin"], "monitors": identities})
    except (ValueError, KeyError, TypeError, AttributeError):
        conflict("snapshot")
        return plan

    owned = ownership["owned"]
    bindings = dict(owned)
    claims = {v["id"]: k for k, v in owned.items()}
    for key, record in sorted(owned.items()):
        monitor = by_id.get(record["id"])
        if monitor is None:
            conflict("missing-owned-id", key)
        elif monitor["type"] != record["type"]:
            conflict("owned-type", key)
    # Historical anchors that are no longer desired are not adoption requests.
    for key in sorted(items.keys() & desired["adoptions"].keys() - owned.keys()):
        anchor = desired["adoptions"][key]
        monitor = by_id.get(anchor["id"])
        if anchor["id"] in claims and claims[anchor["id"]] != key:
            conflict("claimed-id", key)
        claims[anchor["id"]] = key
        if (monitor is None or monitor["type"] != anchor["type"] or monitor["name"] != anchor["name"]
                or normalize_target(monitor) != normalize_target(anchor)):
            conflict("adoption-identity", key)
        else:
            bindings[key] = {"id": anchor["id"], "type": anchor["type"]}

    operations = []
    ordered = sorted(items, key=lambda k: (items[k]["type"] != "group", k))
    for key in ordered:
        item = items[key]
        record = bindings.get(key)
        id = record["id"] if record else None
        target = normalize_target(item)
        for other_id, other in sorted(by_id.items()):
            if other_id == id:
                continue
            same_name = other["name"] == item["name"]
            same_target = other["type"] == item["type"] and normalize_target(other) == target
            # Also protect the reviewed old identity when a desired target/name
            # has changed during bootstrap.
            anchor = desired["adoptions"].get(key) if key not in owned else None
            old_match = anchor and (other["name"] == anchor["name"] or (
                other["type"] == anchor["type"] and normalize_target(other) == normalize_target(anchor)))
            if same_name or same_target or old_match:
                conflict("ambiguous-identity" if record else "unmanaged-collision", key)
                plan["fingerprints"][str(other_id)] = _digest(other)
        if record is None:
            operations.append({"action": "create", "key": key, "type": item["type"]})
            continue
        monitor = by_id.get(id)
        if monitor is None:
            continue
        plan["fingerprints"][str(id)] = _digest(monitor)
        if record["type"] != item["type"]:
            conflict("owned-type", key)
            continue
        if key not in owned:
            operations.append({"action": "adopt", "key": key, "id": id, "type": item["type"]})
        patch = {}
        if monitor["name"] != item["name"]:
            patch["name"] = item["name"]
        if item["type"] != "group":
            if normalize_target(monitor) != target:
                patch.update(item["target"])
            parent = bindings.get(item["parentKey"])
            if parent is None or monitor.get("parent") != parent["id"]:
                patch["parentKey"] = item["parentKey"]
        if patch:
            operations.append({"action": "update", "key": key, "id": id, "patch": patch})
    for key in sorted(owned.keys() - items.keys()):
        record = owned[key]
        plan["removals"].append({"key": key, "id": record["id"]})
        if record["id"] in by_id:
            plan["fingerprints"][str(record["id"])] = _digest(by_id[record["id"]])
    plan["conflicts"].sort(key=lambda c: (c.get("key", ""), c["category"]))
    plan["valid"] = not plan["conflicts"]
    if plan["valid"]:
        plan["operations"] = operations
    return plan


def _read_json(path):
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError
            result[key] = value
        return result
    return json.loads(Path(path).read_text(), object_pairs_hook=unique_pairs)


@contextmanager
def _deadline(client=None):
    """Linux oneshot budget, including blocking I/O; nested calls cannot extend it."""
    started = time.monotonic()
    previous = signal.getsignal(signal.SIGALRM)
    remaining, interval = signal.getitimer(signal.ITIMER_REAL)

    def expired(signum, frame):
        raise PlanError("deadline")

    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, min(119.5, remaining) if remaining else 119.5)
    try:
        yield
    except PlanError as error:
        # Interrupting a pipe wait must not leave a worker able to write later.
        if client is not None and str(error) == "deadline":
            client.close()
        raise
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
        if remaining:
            signal.setitimer(signal.ITIMER_REAL, max(0.001, remaining - (time.monotonic() - started)), interval)


def _private(path, directory=False):
    info = path.lstat()
    if (info.st_uid != os.getuid() or (info.st_mode & 0o777) != (0o700 if directory else 0o600)
            or not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))
            or (not directory and info.st_nlink != 1)):
        raise PlanError("state")


@contextmanager
def _locked_state(state_dir):
    state_dir = Path(state_dir)
    state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    _private(state_dir, directory=True)
    fd = os.open(state_dir / "lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "a") as lock:
        _private(state_dir / "lock")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise PlanError("locked") from None
        path = state_dir / "ownership.json"
        if path.exists() or path.is_symlink():
            _private(path)
            state = _read_json(path)
            if not isinstance(state, dict) or state.get("origin") is None:
                raise PlanError("state")
        else:
            state = {"schemaVersion": 2, "origin": None,
                     "bootstrapComplete": False, "owned": {}, "intents": {}}
        try:
            _validate_state(state)
        except (ValueError, TypeError, KeyError, AttributeError):
            raise PlanError("state") from None
        barrier = state_dir / "mutation.pending"
        if barrier.exists() or barrier.is_symlink():
            _private(barrier)
            marker = _read_json(barrier)
            if (not isinstance(marker, dict) or set(marker) != {"schemaVersion"}
                    or type(marker["schemaVersion"]) is not int or marker["schemaVersion"] != 1):
                raise PlanError("state")
            raise PlanError("unresolved-intent")
        yield state


def _sync_directory(state_dir):
    fd = os.open(state_dir, os.O_DIRECTORY | os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _begin_mutation(state_dir):
    # Independent from ownership.json: a failed confirmation directory fsync
    # must not remove the only visible recovery barrier via atomic replacement.
    fd = os.open(Path(state_dir) / "mutation.pending",
                 os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(_json({"schemaVersion": 1}) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    _sync_directory(state_dir)


def _finish_mutation(state_dir):
    # Call only after the confirmed mapping's file AND directory fsync succeed.
    # A crash before durable removal may resurrect the barrier: safe extra review.
    barrier = Path(state_dir) / "mutation.pending"
    _private(barrier)
    barrier.unlink()
    _sync_directory(state_dir)


def _save_state(state_dir, state):
    _validate_state(state)
    if state["origin"] is None:
        raise PlanError("state")
    path = Path(state_dir) / "ownership.json"
    if path.exists() or path.is_symlink():
        _private(path)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=state_dir, delete=False) as handle:
            temporary = handle.name
            handle.write(_json(state) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        _sync_directory(state_dir)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def _accepted_policy(desired):
    notifications = desired["policy"]["notificationPolicy"]
    if (not isinstance(notifications, dict) or set(notifications) != {"notificationIDList"}
            or not isinstance(notifications["notificationIDList"], dict)
            or any(not re.fullmatch(r"[1-9][0-9]*", k) or type(v) is not bool
                   for k, v in notifications["notificationIDList"].items())):
        raise PlanError("notification-policy")
    return deepcopy({"groups": sorted(desired["groups"], key=lambda g: g["key"]),
                     "nodeParents": sorted({c["parentKey"] for c in desired["checks"] if c["type"] == "ping"}),
                     "adoptions": desired["adoptions"], "policy": desired["policy"]})


def _ongoing_policy(desired, state, authorized):
    if not authorized:
        raise PlanError("authorization")
    if not state["bootstrapComplete"] or "acceptedPolicy" not in state:
        raise PlanError("bootstrap-required")
    accepted = state["acceptedPolicy"]
    current = _accepted_policy(desired)
    # Node removal must not revoke the previously accepted node group. Zones,
    # anchors and notification/default policies require a fresh manual approval.
    if (any(current[k] != accepted[k] for k in ("groups", "adoptions", "policy"))
            or not set(current["nodeParents"]).issubset(accepted["nodeParents"])):
        raise PlanError("policy-reapproval")
    zones = {g["key"]: g["name"].lower() for g in accepted["groups"]
             if g["key"] not in accepted["nodeParents"]}
    for check in desired["checks"]:
        if check["type"] == "ping":
            if check["parentKey"] not in accepted["nodeParents"] or not check["key"].startswith("node:"):
                raise PlanError("policy-reapproval")
        else:
            host = urlsplit(check["target"]["url"]).hostname.lower()
            matches = [k for k, zone in zones.items() if host == zone or host.endswith("." + zone)]
            if (not matches or check["parentKey"] != max(matches, key=lambda k: len(zones[k]))
                    or not check["key"].startswith("site:")):
                raise PlanError("policy-reapproval")


def _apply_locked(plan, desired, client, state_dir, state, ongoing=False):
    items = _validate_manifest(desired)
    policy = state["acceptedPolicy"] if ongoing else _accepted_policy(desired)
    if state["intents"]:
        raise PlanError("unresolved-intent")
    baseline = client.snapshot()
    fresh = build_plan(desired, baseline, state)
    if not fresh["valid"] or fresh != plan:
        raise PlanError("stale-plan")
    # Bind only after exact approval comparison, before claims, intents or RPCs.
    # All durable progress (including partial bootstrap) keeps this namespace.
    state["origin"] = fresh["origin"]
    completed = 0
    for operation in plan["operations"]:
        # Compare all relevant baselines and the whole inventory identity before
        # every operation; update only our own affected baseline after success.
        current = client.snapshot()
        expected = build_plan(desired, baseline, state)
        actual = build_plan(desired, current, state)
        if (not actual["valid"] or actual["liveIdentityDigest"] != expected["liveIdentityDigest"]
                or actual["fingerprints"] != expected["fingerprints"]):
            raise PlanError("baseline-drift")
        key = operation["key"]
        item = items[key]
        action = operation["action"]
        id = operation.get("id")
        if action == "adopt":
            state["owned"][key] = {"id": id, "type": item["type"]}
            _save_state(state_dir, state)
            completed += 1
            continue
        patch = {}
        if action == "update":
            patch = dict(operation["patch"], id=id)
            if "parentKey" in patch:
                patch["parent"] = state["owned"][patch.pop("parentKey")]["id"]
        state["intents"][key] = {"action": action, "type": item["type"], "id": id,
                                  "inventoryDigest": desired["digest"],
                                  "baseline": actual["fingerprints"].get(str(id))}
        _save_state(state_dir, state)
        _begin_mutation(state_dir)
        # Durable I/O can itself take time. Recheck after intent persistence,
        # immediately before sending; a detected drift leaves a blocking intent.
        clean = dict(state, intents={})
        latest = build_plan(desired, client.snapshot(), clean)
        if (not latest["valid"] or latest["liveIdentityDigest"] != actual["liveIdentityDigest"]
                or latest["fingerprints"] != actual["fingerprints"]):
            raise PlanError("baseline-drift")
        if action == "update":
            # getMonitor is also the fresh full-object source used internally
            # by edit_monitor; the final read/write race is not server-side CAS.
            affected = next(m for m in current["monitors"] if m["id"] == id)
            # 2.5.6 getMonitor preloads {id,active} without name, so its
            # presentation-only path/pathName differ from getMonitorList.
            full = client.get_monitor(id)
            if ({k: v for k, v in full.items() if k not in ("path", "pathName")}
                    != {k: v for k, v in affected.items() if k not in ("path", "pathName")}):
                raise PlanError("baseline-drift")
        if action == "create":
            # Structural API requirements, not defaults for existing checks.
            payload = {"name": item["name"], "type": item["type"], "parent": None,
                       "conditions": [], "accepted_statuscodes": [], "notificationIDList": {}}
            if item["type"] != "group":
                payload.update(desired["policy"]["newChecks"][item["type"]])
                payload.update(item["target"])
                payload.update(desired["policy"]["notificationPolicy"])
                payload["parent"] = state["owned"][item["parentKey"]]["id"]
            id = client.create_monitor(payload)
            if type(id) is not int or id <= 0 or any(r["id"] == id for r in state["owned"].values()):
                raise PlanError("acknowledgement")
            state["owned"][key] = {"id": id, "type": item["type"]}
        else:
            client.edit_monitor(patch)
        # Confirmation replaces ownership.json, so its intent may disappear
        # visibly before directory fsync succeeds. Keep the independent barrier
        # until BOTH confirmation durability steps have completed successfully.
        del state["intents"][key]
        _save_state(state_dir, state)
        _finish_mutation(state_dir)
        after = client.snapshot()
        changed = next((m for m in after["monitors"] if m["id"] == id), None)
        if changed is None:
            raise PlanError("missing-owned-id")
        # Our own child creation/reparent/rename changes derived ancestor and
        # descendant presentation fields. Do not mistake these for UI drift,
        # and do not refresh away any unrelated configuration/identity change.
        def unrelated(snapshot):
            return {m["id"]: {k: v for k, v in m.items() if k not in ("path", "pathName", "childrenIDs")}
                    for m in snapshot["monitors"] if m["id"] != id}
        if unrelated(baseline) != unrelated(after):
            raise PlanError("baseline-drift")
        baseline = after
        completed += 1
    state["bootstrapComplete"] = True
    state["acceptedPolicy"] = policy
    _save_state(state_dir, state)
    return {"valid": True, "operations": completed, "removals": len(plan["removals"])}


def apply_plan(plan: dict, desired: dict, client, state_dir: Path) -> dict:
    """Apply an exact reviewed plan; never enables unattended reconciliation."""
    with _deadline(client), _locked_state(state_dir) as state:
        return _apply_locked(plan, desired, client, state_dir, state)


def reconcile(desired: dict, client, state_dir: Path, *, authorize_ongoing=False) -> dict:
    """Ongoing authorization is an explicit invocation/configuration decision."""
    with _deadline(client), _locked_state(state_dir) as state:
        _validate_manifest(desired)
        if state["intents"]:
            raise PlanError("unresolved-intent")
        _ongoing_policy(desired, state, authorize_ongoing)
        plan = build_plan(desired, client.snapshot(), state)
        return _apply_locked(plan, desired, client, state_dir, state, ongoing=True)


def _main(argv):
    parser = argparse.ArgumentParser(description="Explicitly authorized Kuma reconciliation")
    sub = parser.add_subparsers(dest="mode", required=True)
    for mode in ("plan", "apply", "reconcile"):
        command = sub.add_parser(mode)
        for option in ("desired", "credential-file", "endpoint", "state-dir"):
            command.add_argument("--" + option, required=True)
        if mode == "plan":
            command.add_argument("--output")
        elif mode == "apply":
            command.add_argument("--plan-file", required=True)
        else:
            command.add_argument("--authorize-ongoing", action="store_true")
    args = parser.parse_args(argv)
    # Import only in the CLI: the planner has no network/client dependency.
    from client import KumaClient, KumaError
    try:
        desired = _read_json(args.desired)
        try:
            _validate_manifest(desired)
        except PlanError as error:
            print("error: " + str(error), file=sys.stderr)
            return 2
        except (ValueError, TypeError, KeyError, AttributeError):
            print("error: manifest", file=sys.stderr)
            return 2
        state_dir = Path(args.state_dir)
        with _deadline(), _locked_state(state_dir) as state:
            if args.mode != "plan" and state["intents"]:
                raise PlanError("unresolved-intent")
            if args.mode == "reconcile":
                _ongoing_policy(desired, state, args.authorize_ongoing)
            approved = _read_json(args.plan_file) if args.mode == "apply" else None
            client = KumaClient(args.endpoint, args.credential_file)
            try:
                plan = build_plan(desired, client.snapshot(), state)
                if args.mode != "plan":
                    result = _apply_locked(approved if args.mode == "apply" else plan,
                                           desired, client, state_dir, state, ongoing=args.mode == "reconcile")
                    print(_json(result))
                    return 0
            finally:
                client.close()
            if args.output:
                output = Path(args.output)
                # Review output must not overwrite credentials, desired or state.
                if (output.resolve() in (Path(args.desired).resolve(), Path(args.credential_file).resolve())
                        or output.resolve().is_relative_to(state_dir.resolve())):
                    raise PlanError("output")
                temporary = None
                try:
                    with tempfile.NamedTemporaryFile(mode="w", dir=output.parent, delete=False) as handle:
                        temporary = handle.name
                        handle.write(_json(plan) + "\n")
                    os.replace(temporary, output)
                finally:
                    if temporary and os.path.exists(temporary):
                        os.unlink(temporary)
            categories = sorted({c["category"] for c in plan["conflicts"]})
            print(_json({"valid": plan["valid"], "operations": len(plan["operations"]),
                         "removals": len(plan["removals"]), "conflicts": len(plan["conflicts"]),
                         "categories": categories}))
            return 0 if plan["valid"] else 2
    except (OSError, ValueError, TypeError, RecursionError):
        print("error: input-state-output", file=sys.stderr)
        return 1
    except PlanError as error:
        print("error: " + str(error), file=sys.stderr)
        return 1
    except KumaError as error:
        print("error: " + error.category, file=sys.stderr)
        return 2 if error.category == "version" else 1


def main(argv: list[str] | None = None) -> int:
    with _deadline():
        return _main(argv)


if __name__ == "__main__":
    sys.exit(main())
