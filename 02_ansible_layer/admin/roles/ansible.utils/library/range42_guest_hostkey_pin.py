#!/usr/bin/python
"""Inspect or append one native guest pin; never replace an existing target."""
from contextlib import contextmanager
import base64
import fcntl
import hashlib
from ipaddress import IPv4Address
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import tempfile
import time

from ansible.module_utils.basic import AnsibleModule

DOCUMENTATION = r"""
module: range42_guest_hostkey_pin
short_description: Inspect or append an independently verified native guest SSH pin
description:
  - Role-local helper for the optional PVE guest-agent enrollment step.
  - Resolves the existing SSH configuration and preserves every existing target record.
  - Appends only a validated public key supplied by the role after its authenticated PVE checks.
author: Range42
options:
  phase:
    description: Inspect trust without writing, or append while the inspected state remains unchanged.
    type: str
    choices: [inspect, append]
    required: true
  ssh_host:
    description: Native SSH alias to resolve with the existing SSH command and configuration.
    type: str
    required: true
  expected_ip:
    description: Exact declared static IPv4 destination.
    type: str
    required: true
  known_hosts_file:
    description: Absolute private pin-file path owned by the current controller user/group.
    type: path
    required: true
  ssh_common_args:
    description: Existing trusted controller SSH common arguments.
    type: str
    default: ''
  ssh_extra_args:
    description: Existing trusted controller SSH extra arguments.
    type: str
    default: ''
  expected_state:
    description: Unmodified inspection state required before an append.
    type: dict
    default: {}
  public_key:
    description: Single verified Ed25519 public host key; required for append.
    type: str
    default: ''
"""

EXAMPLES = r"""
- name: Inspect the native target before optional PVE public-key enrollment
  range42_guest_hostkey_pin:
    phase: inspect
    ssh_host: "{{ ARG_vm_ssh_name }}"
    expected_ip: "{{ global_vm_ci_ip }}"
    known_hosts_file: "{{ deployer_cli_user_ssh_known_hosts }}"
    ssh_common_args: "{{ ansible_ssh_common_args | default('') }}"
    ssh_extra_args: "{{ ansible_ssh_extra_args | default('') }}"
  delegate_to: localhost
  become: false
  vars:
    ansible_become: false
  register: guest_pin
"""

RETURN = r"""
changed:
  description: Whether a new public pin was appended.
  type: bool
  returned: always
existing:
  description: An existing target record was found and left unchanged.
  type: bool
  returned: always
state:
  description: File snapshot and effective SSH binding to pass unchanged to the append phase.
  type: dict
  returned: phase is inspect
"""

def _private(info, mode):
    if info.st_uid != os.geteuid() or info.st_gid != os.getegid() or stat.S_IMODE(info.st_mode) != mode:
        raise ValueError("Host-pin storage must be private and owned by the current user/group")


@contextmanager
def _locked_parent(path):
    path = Path(path)
    if not path.is_absolute() or path.resolve() != path:
        raise ValueError("Host-pin path must be absolute and contain no symlinks")
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    lock = None
    try:
        _private(os.fstat(parent), 0o700)
        lock = os.open("." + path.name + ".range42-lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        info = os.fstat(lock)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("Host-pin lock must be a regular file")
        _private(info, 0o600)
        deadline = time.monotonic() + 5
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise ValueError("Host-pin storage is busy; no key was changed") from None
                time.sleep(0.05)
        yield parent, path.name
    finally:
        if lock is not None:
            os.close(lock)
        os.close(parent)


def _read_opened(fd):
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_size > 1024 * 1024:
        raise ValueError("Host-pin storage must be a bounded regular file")
    _private(info, 0o600)
    os.lseek(fd, 0, os.SEEK_SET)
    with os.fdopen(fd, "rb", closefd=False) as stream:
        data = stream.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024:
        raise ValueError("Host-pin storage exceeds its size bound")
    return data, {"exists": True, "device": info.st_dev, "inode": info.st_ino,
                  "mtime_ns": info.st_mtime_ns, "ctime_ns": info.st_ctime_ns,
                  "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def _read(parent, name):
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
    except FileNotFoundError:
        return b"", {"exists": False}
    try:
        return _read_opened(fd)
    finally:
        os.close(fd)


def _has_target(data, name):
    if not re.fullmatch(r"(?:[A-Za-z0-9][A-Za-z0-9_.:-]*|\[[0-9.]+\]:[0-9]+)", name):
        raise ValueError("Host-pin name must identify one SSH target")
    with tempfile.NamedTemporaryFile() as copied:
        copied.write(data)
        copied.flush()
        result = subprocess.run(["ssh-keygen", "-F", name, "-f", copied.name],
                                capture_output=True, timeout=5)
    if result.returncode not in (0, 1) or result.stderr:
        raise ValueError("Cannot inspect existing host-pin records")
    return bool(result.stdout)


def inspect_known_hosts(path, name):
    with _locked_parent(path) as (parent, filename):
        data, state = _read(parent, filename)
        return {"changed": False, "existing": _has_target(data, name), "state": state}


def _public_key(value):
    lines = value.strip().splitlines()
    if len(value.encode()) > 4096 or len(lines) != 1:
        raise ValueError("Expected one bounded Ed25519 public host key")
    fields = lines[0].split()
    if len(fields) < 2 or fields[0] != "ssh-ed25519":
        raise ValueError("Expected an Ed25519 public host key")
    try:
        data = base64.b64decode(fields[1], validate=True)
    except (ValueError, UnicodeError):
        raise ValueError("Invalid SSH public-key encoding") from None
    if len(data) != 51 or not data.startswith(b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"):
        raise ValueError("Invalid Ed25519 public-key data")
    return "ssh-ed25519 " + base64.b64encode(data).decode("ascii")


def append_known_host(path, name, public_key, expected_state):
    key = _public_key(public_key)
    with _locked_parent(path) as (parent, filename):
        data, state = _read(parent, filename)
        if _has_target(data, name):
            # A concurrent writer may have published a different pin. Preserve
            # it; the unchanged strict SSH wait decides whether it is trusted.
            return {"changed": False, "existing": True}
        if state != expected_state:
            raise ValueError("Host-pin storage changed during enrollment; no key was changed")
        flags = os.O_RDWR | os.O_APPEND | os.O_NOFOLLOW
        if not state["exists"]:
            flags |= os.O_CREAT | os.O_EXCL
        fd = os.open(filename, flags, 0o600, dir_fd=parent)
        try:
            opened_data, opened_state = _read_opened(fd)
            if (state["exists"] and opened_state != state) or (not state["exists"] and opened_data):
                raise ValueError("Host-pin storage changed before append; no key was changed")
            line = ((b"\n" if data and not data.endswith(b"\n") else b"")
                    + (name + " " + key + "\n").encode())
            if os.write(fd, line) != len(line):
                raise ValueError("Host-pin append did not complete; verify the private file")
            os.fsync(fd)
        finally:
            os.close(fd)
        return {"changed": True, "existing": False}


def _ssh_binding(module):
    values = module.params
    expected_ip = str(IPv4Address(values["expected_ip"]))
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", values["ssh_host"]):
        raise ValueError("Expected one native SSH alias")
    argv = [module.get_bin_path("ssh", required=True), "-G", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + json.dumps(values["known_hosts_file"])]
    argv += shlex.split(values["ssh_common_args"]) + shlex.split(values["ssh_extra_args"]) + [values["ssh_host"]]
    result = subprocess.run(argv, capture_output=True, text=True, timeout=5)
    if result.returncode:
        raise ValueError("Cannot resolve the native SSH configuration")
    options = dict(line.split(" ", 1) for line in result.stdout.splitlines() if " " in line)
    if options.get("hostname") != expected_ip:
        raise ValueError("Native SSH destination differs from the declared guest IP")
    port = int(options["port"])
    if not 1 <= port <= 65535:
        raise ValueError("Invalid native SSH port")
    alias = options.get("hostkeyalias")
    name = alias if alias is not None else expected_ip if port == 22 else f"[{expected_ip}]:{port}"
    return {"ip": expected_ip, "port": port, "name": name,
            "global_files": options.get("globalknownhostsfile", "").split()}


def _global_pin(binding):
    files = binding["global_files"]
    if files in (["/dev/null"], ["none"]):
        return False
    if files != ["/etc/ssh/ssh_known_hosts", "/etc/ssh/ssh_known_hosts2"]:
        raise ValueError("Optional enrollment requires standard global SSH trust files or /dev/null")
    return any(_has_target(Path(path).read_bytes(), binding["name"]) for path in files if Path(path).is_file())


def main():
    module = AnsibleModule(argument_spec={
        "phase": {"choices": ["inspect", "append"], "required": True},
        "ssh_host": {"type": "str", "required": True},
        "expected_ip": {"type": "str", "required": True},
        "known_hosts_file": {"type": "path", "required": True},
        "ssh_common_args": {"type": "str", "default": ""},
        "ssh_extra_args": {"type": "str", "default": ""},
        "expected_state": {"type": "dict", "default": {}},
        "public_key": {"type": "str", "default": "", "no_log": True},
    }, supports_check_mode=False)
    try:
        binding = _ssh_binding(module)
        current = inspect_known_hosts(module.params["known_hosts_file"], binding["name"])
        if module.params["phase"] == "inspect":
            current["existing"] = current["existing"] or _global_pin(binding)
            current["state"] = {"file": current["state"], "ssh": binding}
            module.exit_json(**current)
        expected = module.params["expected_state"]
        if binding != expected.get("ssh"):
            raise ValueError("Native SSH destination/port/HostKeyAlias changed during enrollment")
        if _global_pin(binding):
            module.exit_json(changed=False, existing=True)
        module.exit_json(**append_known_host(module.params["known_hosts_file"], binding["name"],
                                            module.params["public_key"], expected.get("file")))
    except subprocess.TimeoutExpired:
        module.fail_json(msg="Native SSH trust inspection timed out; no key was changed")
    except (ValueError, OSError) as error:
        module.fail_json(msg=str(error))


if __name__ == "__main__":
    main()
