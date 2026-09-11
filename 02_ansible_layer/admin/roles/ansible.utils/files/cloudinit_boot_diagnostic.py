"""Emit a small public cloud-init summary; never emit free-form guest output."""

import json
import os
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


def status_output():
    """Bound wall time and bytes, including a child holding stdout open."""
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
    try:
        result = summarize(status_output())
    except (OSError, ValueError, TypeError, RecursionError, subprocess.TimeoutExpired):
        result = UNAVAILABLE
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
