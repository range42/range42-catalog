"""Exercise the catalog's real cloud-init wait with local temporary markers."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import threading
import time

import pytest
import yaml


TASK = Path(__file__).resolve().parents[1] / "02_ansible_layer/admin/roles/ansible.utils/tasks/wait/cloudinit/is_boot_finished.yml"
UNSET = object()


def run_wait(tmp_path, value=UNSET, *, marker="present", syntax=False):
    binary = shutil.which("ansible-playbook")
    if binary is None:
        pytest.skip("ansible-playbook is not installed")
    tasks = yaml.safe_load(TASK.read_text())
    finished = tmp_path / "boot-finished"
    continued = tmp_path / "continued"
    for task in tasks:
        wait = task.get("ansible.builtin.wait_for", task.get("wait_for"))
        if wait is not None:
            # Exercise production validation and timeout unchanged. Only isolate
            # its fixed guest marker and remove the initial ten-second delay.
            assert wait["path"] == "/var/lib/cloud/instance/boot-finished"
            wait.update(path=str(finished), delay=0)
    tasks.append({"name": "Continue after cloud-init only", "ansible.builtin.file": {
        "path": str(continued), "state": "touch", "mode": "0600"}})
    variables = {} if value is UNSET else {"range42_cloud_init_timeout_seconds": value}
    playbook = tmp_path / "main.yml"
    playbook.write_text(yaml.safe_dump([{"hosts": "localhost", "connection": "local",
        "gather_facts": False, "vars": variables, "tasks": tasks}]))
    config = tmp_path / "ansible.cfg"
    config.write_text("[defaults]\nretry_files_enabled=False\n")
    if marker == "present":
        finished.touch()
    arguments = [binary, "-i", "localhost,", str(playbook), "-vvv"]
    if syntax:
        arguments.append("--syntax-check")
    process = subprocess.Popen(arguments, env={**os.environ, "ANSIBLE_CONFIG": str(config),
        "ANSIBLE_NOCOLOR": "1"}, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output = []
    timer = None

    def collect():
        nonlocal timer
        for line in process.stdout:
            output.append(line)
            if marker == "delayed" and "TASK [CLOUD INIT - WAIT END OF SETUP]" in line:
                timer = threading.Timer(2, finished.touch)
                timer.start()

    reader = threading.Thread(target=collect)
    reader.start()
    started = time.monotonic()
    try:
        process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        pytest.fail("Cloud-init wait did not honor its bounded timeout")
    finally:
        reader.join(timeout=2)
        if timer is not None:
            timer.cancel()
            timer.join()
    return process.returncode, "".join(output), continued, time.monotonic() - started


def test_default_wait_allows_twenty_minutes_for_cold_cloud_init(tmp_path):
    code, output, continued, _ = run_wait(tmp_path)
    assert code == 0, output
    assert continued.exists()
    assert re.search(r'"timeout":\s*1200\b', output), output


def test_custom_wait_really_waits_for_a_delayed_cloud_init_marker(tmp_path):
    code, output, continued, _ = run_wait(tmp_path, 8, marker="delayed")
    assert code == 0, output
    assert continued.exists()
    assert re.search(r'"elapsed":\s*[1-8]\b', output), output
    assert re.search(r'"timeout":\s*8\b', output), output


def test_exhausted_custom_wait_stops_before_next_stage(tmp_path):
    code, output, continued, elapsed = run_wait(tmp_path, 1, marker="absent")
    assert code != 0
    assert not continued.exists()
    assert "Timeout when waiting for file" in output, output
    assert elapsed < 10


@pytest.mark.parametrize("value", [True, False, "1200", 1.5, None, [], {}, 0, -1, 3601])
def test_invalid_timeout_fails_before_wait_even_when_marker_exists(tmp_path, value):
    code, output, continued, _ = run_wait(tmp_path, value)
    assert code != 0, output
    assert not continued.exists()
    assert "CLOUD INIT - WAIT END OF SETUP" not in output, output
    assert "integer from 1 to 3600 seconds" in output, output


@pytest.mark.parametrize("value", [1, 3600])
def test_timeout_integer_bounds_are_accepted(tmp_path, value):
    code, output, continued, _ = run_wait(tmp_path, value)
    assert code == 0, output
    assert continued.exists()
    assert re.search(r'"timeout":\s*' + str(value) + r'\b', output), output


def test_cloud_init_wait_tasks_pass_actual_ansible_syntax_check(tmp_path):
    code, output, _, _ = run_wait(tmp_path, syntax=True)
    assert code == 0, output
