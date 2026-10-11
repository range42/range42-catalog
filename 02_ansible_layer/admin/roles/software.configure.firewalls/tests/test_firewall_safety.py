"""Check management-access invariants without changing a machine's firewall."""
from pathlib import Path
import unittest

from jinja2.nativetypes import NativeEnvironment
import yaml


TASKS = Path(__file__).resolve().parents[1] / 'tasks'
RULES = [{'ip': 'all', 'port': 22, 'protocol': 'tcp'},
         {'ip': '192.0.2.1', 'port': 53, 'protocol': 'udp'}]


def tasks(distro):
    return yaml.safe_load((TASKS / distro).read_text())


def action(task):
    for name, parameters in task.items():
        if name.startswith(('ansible.', 'community.')):
            return name.rsplit('.', 1)[-1], parameters
    return '', {}


def expanded(parameters, item=None):
    environment = NativeEnvironment()
    return {key: environment.from_string(value).render(item=item)
            if isinstance(value, str) else value for key, value in parameters.items()}


class FirewallSafetyTests(unittest.TestCase):
    def test_ubuntu_installs_ssh_before_restricting_or_enabling(self):
        ssh_allowed = False
        enabled = False
        for task in tasks('ubuntu/ufw.yml'):
            module, parameters = action(task)
            if module != 'ufw':
                continue
            for item in RULES if 'loop' in task else [None]:
                values = expanded(parameters, item)
                if values.get('state') == 'reset':
                    ssh_allowed = enabled = False
                if values.get('rule') == 'allow' and str(values.get('port')) == '22':
                    ssh_allowed = True
                if values.get('default') in ('deny', 'reject') or values.get('state') == 'enabled':
                    self.assertTrue(ssh_allowed, task['name'])
                if values.get('state') == 'enabled':
                    enabled = True
        self.assertTrue(enabled)

    def test_fedora_stages_ssh_before_activation_or_drop(self):
        ssh_staged = False
        for task in tasks('fedora/firewalld.yml'):
            module, values = action(task)
            if module == 'firewalld' and values.get('service') == 'ssh':
                self.assertTrue(values.get('permanent'))
                self.assertTrue(values.get('offline'), 'SSH must be configurable before the daemon starts')
                self.assertTrue(values.get('immediate'), 'An already running daemon must also retain SSH')
                ssh_staged = True
            if (module == 'service' and values.get('state') == 'started') or values.get('target') == 'DROP':
                self.assertTrue(ssh_staged, task['name'])
            if module == 'command' and 'reload' in str(values):
                self.assertTrue(ssh_staged, task['name'])
                self.assertNotIn('--complete-reload', str(values))
        self.assertTrue(ssh_staged)

    def test_fedora_uses_a_valid_permanent_zone_target(self):
        policy = [values for task in tasks('fedora/firewalld.yml')
                  for module, values in [action(task)] if values.get('target') == 'DROP']
        self.assertEqual(len(policy), 1)
        self.assertEqual(policy[0]['state'], 'present')
        self.assertTrue(policy[0]['permanent'])

    def test_fedora_preserves_the_requested_rule_protocol(self):
        rule = next(values['rich_rule'] for task in tasks('fedora/firewalld.yml')
                    for module, values in [action(task)] if 'rich_rule' in values)
        result = NativeEnvironment().from_string(rule).render(item=RULES[1])
        self.assertIn('protocol=udp', result)
        self.assertIn('port=53', result)
        self.assertIn('source address=192.0.2.1', result)

    def test_fedora_reload_only_runs_after_a_policy_change(self):
        reloads = [task for task in tasks('fedora/firewalld.yml')
                   if action(task)[0] == 'command' and '--reload' in str(action(task)[1])]
        self.assertEqual(len(reloads), 1)
        self.assertIn('when', reloads[0])


if __name__ == '__main__':
    unittest.main()
