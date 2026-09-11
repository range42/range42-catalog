"""Run the real rescue in local Ansible; replace only wait/SSH transports."""

from copy import deepcopy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest
import yaml

ROLE = Path(__file__).resolve().parents[1]
SECRET = "private-userdata-token-do-not-export"


def run_wait(tmp_path, *, failure=True, lost_ssh=False, malformed=False, stale=False):
    role = tmp_path / "roles/ansible.utils"
    shutil.copytree(ROLE, role)
    taskfile = role / "tasks/wait/cloudinit/is_boot_finished.yml"
    original = yaml.safe_load(taskfile.read_text())

    def adapt(item):
        if isinstance(item, list):
            return [adapt(value) for value in item]
        if not isinstance(item, dict):
            return item
        item = deepcopy(item)
        for key in ("wait_for", "ansible.builtin.wait_for"):
            if key in item:
                options = item.pop(key)
                assert options["timeout"] == 500 and options["delay"] == 10
                item["ansible.builtin.fail" if failure else "ansible.builtin.debug"] = {
                    "msg": "boot wait fixture"
                }
        if "ansible.builtin.command" in item:
            if lost_ssh:
                item.pop("ansible.builtin.command")
                item["fixture_unreachable"] = {}
            else:
                item["environment"] = {
                    "PATH": str(tmp_path) + os.pathsep + os.environ["PATH"]
                }
        return {key: adapt(value) for key, value in item.items()}

    taskfile.write_text(yaml.safe_dump(adapt(original), sort_keys=False))
    cli = tmp_path / "cloud-init"
    document = {
        "status": "running",
        "stage": "modules-final",
        "errors": [SECRET],
        "recoverable_errors": {},
    }
    cli.write_text(
        f"#!{sys.executable}\nimport pathlib\npathlib.Path({str(tmp_path / 'diagnosed')!r}).touch()\nprint({('invalid-' + SECRET) if malformed else json.dumps(document)!r})\n"
    )
    cli.chmod(0o700)
    library = tmp_path / "library"
    library.mkdir()
    (library / "fixture_unreachable.py").write_text(
        "from ansible.module_utils.basic import AnsibleModule\n"
        f"AnsibleModule(argument_spec={{}}).exit_json(unreachable=True,msg={SECRET!r})\n"
    )
    playbook = tmp_path / "play.yml"
    playbook.write_text(
        yaml.safe_dump(
            [
                {
                    "hosts": "localhost",
                    "gather_facts": False,
                    "vars": {
                        "ansible_connection": "local",
                        "ansible_python_interpreter": sys.executable,
                        "requested_tasks": ["wait/cloudinit/is_boot_finished.yml"],
                        **(
                            {
                                "_r42_ci_candidate": {
                                    "diagnostic": "available",
                                    "status": "done",
                                    "stage": "none",
                                    "errors": 0,
                                    "recoverable_errors": 0,
                                }
                            }
                            if stale
                            else {}
                        ),
                    },
                    "roles": ["ansible.utils"],
                    "post_tasks": [
                        {"ansible.builtin.debug": {"msg": "MUST_NOT_CONTINUE"}}
                    ],
                }
            ],
            sort_keys=False,
        )
    )
    result = subprocess.run(
        [shutil.which("ansible-playbook"), "-i", "localhost,", str(playbook)],
        env={
            **os.environ,
            "ANSIBLE_ROLES_PATH": str(tmp_path / "roles"),
            "ANSIBLE_LIBRARY": str(library),
            "ANSIBLE_NOCOLOR": "1",
        },
        capture_output=True,
        text=True,
        timeout=25,
    )
    assert SECRET not in result.stdout + result.stderr
    return result


def test_failed_wait_reports_safe_stage_and_remains_failed(tmp_path):
    result = run_wait(tmp_path)
    assert result.returncode != 0
    assert "CLOUD_INIT_BOOT_WAIT_FAILED" in result.stdout
    assert "running / modules-final" in result.stdout
    assert "MUST_NOT_CONTINUE" not in result.stdout


@pytest.mark.parametrize("arguments", [{"lost_ssh": True}, {"malformed": True}])
def test_unavailable_diagnostic_preserves_the_original_failure(tmp_path, arguments):
    result = run_wait(tmp_path, **arguments)
    assert result.returncode != 0
    assert "CLOUD_INIT_BOOT_WAIT_FAILED" in result.stdout
    assert "diagnostic=unavailable" in result.stdout
    assert "MUST_NOT_CONTINUE" not in result.stdout


def test_successful_boot_does_not_run_diagnostics(tmp_path):
    result = run_wait(tmp_path, failure=False)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not (tmp_path / "diagnosed").exists()


def test_lost_connection_never_reuses_a_previous_status_candidate(tmp_path):
    result = run_wait(tmp_path, lost_ssh=True, stale=True)
    assert result.returncode != 0
    assert "diagnostic=unavailable" in result.stdout
    assert "unknown / unknown" in result.stdout
