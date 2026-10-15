"""Execute the real UFW tasks with a private command recorder, never host policy."""

import json
import os
from pathlib import Path
import subprocess
import sys

import pytest
import yaml

ROLE = (
    Path(__file__).resolve().parents[1]
    / "02_ansible_layer/admin/roles/software.configure.firewalls"
)


@pytest.mark.parametrize("ports", [[22, 3000], [2222], []])
def test_ufw_installs_all_caller_rules_before_enabling(tmp_path, ports):
    """The module is real; only its ufw executable uses disposable state.

    The already-provided fixture command replaces the package prerequisite.
    All firewall tasks, module arguments and their order remain unchanged.
    """
    binary = Path(sys.executable).with_name("ansible-playbook")
    assert binary.is_file(), "Install Ansible and community.general for behavior tests"
    commands = tmp_path / "bin"
    commands.mkdir()
    recorder = commands / "ufw"
    recorder.write_text(
        "#!"
        + sys.executable
        + "\n"
        + """import json, os, sys
from pathlib import Path
root = Path(os.environ['UFW_FIXTURE_ROOT'])
state_file = root / 'state.json'
state = json.loads(state_file.read_text()) if state_file.exists() else {
    'enabled': True, 'ports': [8443], 'incoming': 'deny'}
args = [a for a in sys.argv[1:] if a not in ('-f', '--force')]
operation = args[0]
if operation == '--version':
    print('ufw 0.36.2')
    sys.exit(0)
if operation == 'reset':
    state = {'enabled': False, 'ports': [], 'incoming': 'deny'}
elif operation == 'enable':
    state['enabled'] = True
elif operation == 'default':
    state['incoming'] = args[1]
elif operation == 'allow':
    port = int(args[args.index('port') + 1])
    if port not in state['ports']:
        state['ports'].append(port)
elif operation not in ('status', 'reload'):
    raise SystemExit('Unexpected fixture command: ' + repr(args))
state_file.write_text(json.dumps(state))
with (root / 'commands.jsonl').open('a') as stream:
    stream.write(json.dumps({'args': args, 'state': state}) + '\\n')
print('Status: ' + ('active' if state['enabled'] else 'inactive'))
print('Default: ' + state['incoming'] + ' (incoming), allow (outgoing), deny (routed)')
for port in state['ports']:
    print(str(port) + '/tcp ALLOW IN Anywhere')
"""
    )
    recorder.chmod(0o700)
    tasks = yaml.safe_load((ROLE / "tasks/ubuntu/ufw.yml").read_text())
    assert tasks[0]["ansible.builtin.package"]["name"] == "ufw"
    play = tmp_path / "play.yml"
    play.write_text(
        yaml.safe_dump(
            [
                {
                    "hosts": "localhost",
                    "gather_facts": False,
                    "vars": {
                        "firewall_rules": [
                            {"ip": "all", "port": p, "protocol": "tcp"} for p in ports
                        ]
                    },
                    "tasks": tasks[1:],
                }
            ],
            sort_keys=False,
        )
    )
    inventory = tmp_path / "inventory.yml"
    inventory.write_text(
        yaml.safe_dump(
            {
                "all": {
                    "hosts": {
                        "localhost": {
                            "ansible_connection": "local",
                            "ansible_python_interpreter": sys.executable,
                        }
                    }
                }
            }
        )
    )
    env = {k: v for k, v in os.environ.items() if not k.startswith("ANSIBLE_")}
    env.update(
        PATH=str(commands) + os.pathsep + os.environ["PATH"],
        UFW_FIXTURE_ROOT=str(tmp_path),
        ANSIBLE_LOCAL_TEMP=str(tmp_path / "ansible-temp"),
        ANSIBLE_RETRY_FILES_ENABLED="false",
    )
    # Retain an explicitly provided collection path in isolated controller venvs.
    collections = os.environ.get("ANSIBLE_COLLECTIONS_PATH")
    if collections:
        env["ANSIBLE_COLLECTIONS_PATH"] = collections
    result = subprocess.run(
        [str(binary), "-i", str(inventory), str(play)],
        capture_output=True,
        text=True,
        env=env,
        timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    events = [
        json.loads(line)
        for line in (tmp_path / "commands.jsonl").read_text().splitlines()
    ]
    enables = [event for event in events if event["args"][0] == "enable"]
    assert enables
    assert all(set(event["state"]["ports"]) == set(ports) for event in enables), (
        "UFW enabled before the caller's rules were installed",
        enables,
    )
    final = json.loads((tmp_path / "state.json").read_text())
    assert final == {"enabled": True, "incoming": "deny", "ports": ports}
