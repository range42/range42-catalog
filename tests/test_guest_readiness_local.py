"""Readiness must not open SSH for an explicitly local Ansible target."""
import os
from pathlib import Path
import signal
import subprocess
import sys

import pytest
import yaml


TASK = Path(__file__).resolve().parents[1] / "02_ansible_layer/admin/roles/ansible.utils/tasks/wait/openssh_server/is_reachable.yml"


def test_local_guest_readiness_uses_the_selected_inventory_transport(tmp_path):
    inventory = tmp_path / "hosts.yml"
    inventory.write_text(yaml.safe_dump({"all": {"hosts": {"guest.invalid": {
        "ansible_connection": "local", "ansible_python_interpreter": sys.executable,
        "ARG_vm_ssh_name": "guest.invalid", "deployer_cli_user_ssh_known_hosts": str(tmp_path / "known_hosts"),
    }}}}))
    playbook = tmp_path / "main.yml"
    playbook.write_text(yaml.safe_dump([{"hosts": "guest.invalid", "gather_facts": False,
        "tasks": [{"ansible.builtin.include_tasks": str(TASK)}]}]))
    config = tmp_path / "ansible.cfg"
    config.write_text("[defaults]\nretry_files_enabled = False\n")
    process = subprocess.Popen([str(Path(sys.executable).parent / "ansible-playbook"),
        "-i", str(inventory), str(playbook)], env={**os.environ, "ANSIBLE_CONFIG": str(config)},
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        output, _ = process.communicate()
        pytest.fail("Local readiness attempted remote SSH: " + output)
    assert process.returncode == 0, output
    assert "WAIT FOR LOCAL INVENTORY CONNECTION" in output
