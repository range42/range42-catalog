"""The native SSH wait must retain private routing and verified host trust."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

import pytest
import yaml


TASK = Path(__file__).resolve().parents[1] / "02_ansible_layer/admin/roles/ansible.utils/tasks/wait/openssh_server/is_reachable.yml"


def run_wait(tmp_path, *, common="", extra="", alias="guest.invalid", failure=False, wrapper=False):
    binary = Path(sys.executable).parent / "ansible-playbook"
    if not binary.is_file():
        pytest.skip("ansible-playbook is not installed")
    capture = tmp_path / "ssh-argv.json"
    known_hosts = tmp_path / "private known hosts"
    known_hosts.write_text("")
    executable = tmp_path / "capture-ssh"
    executable.write_text(
        f"#!{sys.executable}\nimport json,sys\nfrom pathlib import Path\n"
        f"Path({str(capture)!r}).write_text(json.dumps(sys.argv[1:]))\n"
        f"sys.exit({255 if failure else 0})\n"
    )
    executable.chmod(0o700)
    bindir = tmp_path / "bin"
    bindir.mkdir()
    ssh = bindir / "ssh"
    if wrapper:
        ssh.write_text(f"#!/bin/sh\nexec {shlex.quote(str(executable))} -F /private/wrapper-config \"$@\"\n")
        ssh.chmod(0o700)
    else:
        ssh.symlink_to(executable)
    inventory = tmp_path / "hosts.yml"
    inventory.write_text(yaml.safe_dump({"all": {"hosts": {"guest.invalid": {
        "ansible_connection": "ssh", "ansible_ssh_common_args": common,
        "ansible_ssh_extra_args": extra, "ARG_vm_ssh_name": alias,
        "deployer_cli_user_ssh_known_hosts": str(known_hosts),
    }}}}))
    tasks = yaml.safe_load(TASK.read_text())
    for task in tasks:
        if task.get("name") == "WAIT FOR SSH - VIA ProxyJump":
            # Keep the production command/error policy; shorten only the timer.
            task["retries"], task["delay"] = 0, 0
    marker = tmp_path / "next-stage"
    tasks.append({"name": "Continue only after successful SSH readiness", "ansible.builtin.copy": {
        "content": "next stage", "dest": str(marker), "mode": "0600",
    }, "delegate_to": "localhost"})
    playbook = tmp_path / "main.yml"
    playbook.write_text(yaml.safe_dump([{"hosts": "guest.invalid", "gather_facts": False, "tasks": tasks}]))
    config = tmp_path / "ansible.cfg"
    config.write_text("[defaults]\nhost_key_checking=True\nretry_files_enabled=False\n")
    result = subprocess.run([str(binary), "-i", str(inventory), str(playbook)],
        env={**os.environ, "ANSIBLE_CONFIG": str(config), "PATH": str(bindir) + ":" + os.environ["PATH"]},
        capture_output=True, text=True, timeout=15)
    return result, json.loads(capture.read_text()), known_hosts, marker


def test_remote_readiness_retains_quoted_common_and_extra_ssh_arguments(tmp_path):
    config = tmp_path / "private 'ssh config"
    config.write_text("Host guest.invalid\n  HostName 127.0.0.1\n  ProxyJump jump.invalid\n")
    result, args, known_hosts, marker = run_wait(tmp_path,
        common=f"-F {shlex.quote(str(config))}", extra="-p 2222 -o LogLevel=ERROR")
    assert result.returncode == 0, result.stdout + result.stderr
    effective = subprocess.run(["ssh", "-G", *args], capture_output=True, text=True, check=True)
    options = dict(line.split(" ", 1) for line in effective.stdout.splitlines())
    assert options["hostname"] == "127.0.0.1"
    assert options["proxyjump"] == "jump.invalid"
    assert options["port"] == "2222"
    assert options["userknownhostsfile"] == str(known_hosts)
    assert marker.exists()


def test_remote_readiness_cannot_weaken_batch_or_verified_host_policy(tmp_path):
    result, args, _, _ = run_wait(tmp_path,
        extra="-o BatchMode=no -o StrictHostKeyChecking=no")
    assert result.returncode == 0, result.stdout + result.stderr
    effective = subprocess.run(["ssh", "-G", "-F", "/dev/null", *args], capture_output=True, text=True, check=True)
    options = dict(line.split(" ", 1) for line in effective.stdout.splitlines())
    assert options["batchmode"] == "yes"
    assert options["stricthostkeychecking"] == "true"


def test_remote_readiness_does_not_interpret_the_target_as_shell_code(tmp_path):
    injected = tmp_path / "injected"
    alias = f"guest.invalid; printf injected > {shlex.quote(str(injected))}"
    result, args, _, _ = run_wait(tmp_path, alias=alias)
    assert result.returncode == 0, result.stdout + result.stderr
    assert args[-2:] == [alias, "true"]
    assert not injected.exists()


def test_remote_readiness_stops_after_exhausted_ssh_retries(tmp_path):
    result, _, _, marker = run_wait(tmp_path, failure=True)
    assert result.returncode != 0, "A failed SSH wait must fail the play:\n" + result.stdout
    assert not marker.exists()


def test_remote_readiness_retains_the_native_adapter_ssh_wrapper(tmp_path):
    result, args, _, _ = run_wait(tmp_path, wrapper=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert args[:2] == ["-F", "/private/wrapper-config"]
    effective = subprocess.run(["ssh", "-G", "-F", "/dev/null", *args[2:]],
        capture_output=True, text=True, check=True)
    options = dict(line.split(" ", 1) for line in effective.stdout.splitlines())
    assert options["stricthostkeychecking"] == "true"
