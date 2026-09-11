"""Emit a small public cloud-init summary; never emit free-form guest output."""

import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time


LIMIT = 65536
TIMEOUT = 5
STATUSES = {
    "not started",
    "running",
    "done",
    "error",
    "error - done",
    "error - running",
    "degraded done",
    "degraded running",
    "disabled",
}
STAGES = {"init-local", "init", "modules-config", "modules-final"}
UNAVAILABLE = {
    "diagnostic": "unavailable",
    "status": "unknown",
    "stage": "unknown",
    "errors": None,
    "recoverable_errors": None,
}
PACKAGE_UNAVAILABLE = {
    "package_phase": "unknown",
    "package_state": "unknown",
    "package_cpu_activity": "unavailable",
    "package_sample_ms": None,
}
# Linux comm is limited to 15 visible bytes. No argv or environment is read.
PACKAGE_PROGRAMS = {
    name[:15]: phase
    for phase, names in {
        "apt": ("apt", "apt-get"),
        "dpkg": ("dpkg", "dpkg-deb", "dpkg-trigger"),
        "initramfs": ("update-initramfs", "mkinitramfs"),
        "grub": ("update-grub", "update-grub2", "grub-mkconfig", "grub-install"),
    }.items()
    for name in names
}


def process_snapshot(root, deadline):
    """Keep only stat identities, counters and fixed program classifications."""
    rows = {}
    with os.scandir(root) as entries:
        for count, entry in enumerate(entries):
            if count >= 4096 or time.monotonic() >= deadline:
                raise ValueError("unavailable")
            if not entry.name.isascii() or not entry.name.isdecimal():
                continue
            with (Path(entry.path) / "stat").open("rb") as stream:
                raw = stream.read(4097)
            if len(raw) > 4096:
                raise ValueError("unavailable")
            prefix, rest = raw.decode("ascii").split("(", 1)
            name, tail = rest.rsplit(")", 1)
            fields = tail.split()
            if (
                int(prefix) != int(entry.name)
                or len(fields) < 20
                or fields[0]
                not in {"R", "S", "D", "Z", "T", "t", "W", "X", "x", "K", "P", "I"}
            ):
                raise ValueError("unavailable")
            values = [int(fields[index]) for index in (1, 11, 12, 19)]
            if any(value < 0 or value > 2**63 - 1 for value in values):
                raise ValueError("unavailable")
            rows[int(entry.name)] = {
                "parent": values[0],
                "cpu": values[1] + values[2],
                "start": values[3],
                "state": fields[0],
                "phase": PACKAGE_PROGRAMS.get(name),
                "cloud_init": name == "cloud-init",
            }
    return rows


def package_scope(rows, deadline):
    """Select package descendants of exactly one visible cloud-init worker."""
    roots, anchors = set(), set()
    for pid, row in rows.items():
        if time.monotonic() >= deadline:
            raise ValueError("unavailable")
        if row["phase"] is None:
            continue
        seen, parents, current = set(), [], pid
        while current:
            if current in seen or current not in rows or len(seen) >= 64:
                raise ValueError("unavailable")
            seen.add(current)
            if rows[current]["cloud_init"]:
                parents.append(current)
            current = rows[current]["parent"]
        if len(parents) > 1:
            raise ValueError("unavailable")
        if parents:
            roots.add((parents[0], rows[parents[0]]["start"]))
            anchors.add(pid)
    if len(roots) > 1:
        raise ValueError("unavailable")
    children = {}
    for pid, row in rows.items():
        children.setdefault(row["parent"], []).append(pid)
    selected, pending = set(), list(anchors)
    while pending:
        if time.monotonic() >= deadline:
            raise ValueError("unavailable")
        pid = pending.pop()
        if pid not in selected:
            selected.add(pid)
            pending.extend(children.get(pid, []))
    return roots, {pid: rows[pid] for pid in selected}


def package_progress(root=Path("/proc"), *, deadline):
    """A short CPU observation is neither a health check nor a stall diagnosis."""
    try:
        if deadline - time.monotonic() < 0.1:
            raise ValueError("unavailable")
        before_roots, before = package_scope(process_snapshot(root, deadline), deadline)
        started = time.monotonic()
        if deadline - started < 0.1:
            raise ValueError("unavailable")
        time.sleep(0.1)
        after_roots, after = package_scope(process_snapshot(root, deadline), deadline)
        elapsed = int((time.monotonic() - started) * 1000)
        if time.monotonic() >= deadline or elapsed > 5000:
            raise ValueError("unavailable")
        if before_roots != after_roots or before.keys() != after.keys():
            raise ValueError("unavailable")
        for pid, row in after.items():
            if (
                any(
                    row[key] != before[pid][key] for key in ("start", "parent", "phase")
                )
                or row["cpu"] < before[pid]["cpu"]
            ):
                raise ValueError("unavailable")
        if not after:
            return {
                **PACKAGE_UNAVAILABLE,
                "package_phase": "none",
                "package_state": "none",
            }
        phases = {row["phase"] for row in after.values()}
        phase = next(
            value for value in ("grub", "initramfs", "dpkg", "apt") if value in phases
        )
        states = {row["state"] for row in after.values()}
        names = {
            "R": "running",
            "S": "sleeping",
            "D": "blocked",
            "T": "stopped",
            "t": "stopped",
            "Z": "zombie",
        }
        state = (
            "running"
            if "R" in states
            else names.get(next(iter(states)), "unknown")
            if len(states) == 1
            else "mixed"
        )
        return {
            "package_phase": phase,
            "package_state": state,
            "package_cpu_activity": "observed"
            if any(after[pid]["cpu"] > row["cpu"] for pid, row in before.items())
            else "not_observed",
            "package_sample_ms": elapsed,
        }
    except (OSError, ValueError, TypeError, IndexError, StopIteration):
        return PACKAGE_UNAVAILABLE.copy()


def status_output(deadline=None):
    """Bound wall time and bytes, including a child holding stdout open."""
    if deadline is None:
        deadline = time.monotonic() + TIMEOUT
    process = subprocess.Popen(
        ["cloud-init", "status", "--format=json"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        output = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise ValueError("unavailable")
                chunk = os.read(
                    process.stdout.fileno(), min(8192, LIMIT + 1 - len(output))
                )
                if not chunk:
                    break
                output.extend(chunk)
                if len(output) > LIMIT:
                    raise ValueError("unavailable")
        rc = process.wait(timeout=max(0, deadline - time.monotonic()))
        # Exit 1/2 can still provide a valid failed/degraded status document.
        if rc not in (0, 1, 2):
            raise ValueError("unavailable")
        return json.loads(output)
    finally:
        # Until wait() reaps the leader, its PID cannot be reused. A descendant
        # that keeps the pipe open also keeps this process group allocated.
        if process.returncode is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
        process.stdout.close()


def summarize(document):
    if not isinstance(document, dict):
        raise ValueError("unavailable")
    status = document.get("extended_status", document.get("status"))
    if status not in STATUSES:
        raise ValueError("unavailable")
    stage = "unknown"
    if "stage" in document:
        stage = "none" if document["stage"] is None else document["stage"]
        if stage != "none" and stage not in STAGES:
            raise ValueError("unavailable")
    errors = document.get("errors", [])
    recoverable = document.get("recoverable_errors", {})
    if not isinstance(errors, list) or not isinstance(recoverable, dict):
        raise ValueError("unavailable")
    if any(not isinstance(values, list) for values in recoverable.values()):
        raise ValueError("unavailable")
    return {
        "diagnostic": "available",
        "status": status,
        "stage": stage,
        "errors": len(errors) if "errors" in document else None,
        "recoverable_errors": sum(map(len, recoverable.values()))
        if "recoverable_errors" in document
        else None,
    }


def main():
    deadline = time.monotonic() + TIMEOUT
    try:
        result = summarize(status_output(deadline=deadline))
    except (OSError, ValueError, TypeError, RecursionError, subprocess.TimeoutExpired):
        result = UNAVAILABLE
    result = {**result, **package_progress(deadline=deadline)}
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
