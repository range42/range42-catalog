# Guest firewall baseline

Configure UFW on Ubuntu or firewalld on Fedora from `firewall_rules`, a list of
`{ip, port, protocol}` objects. Use `ip: all` for any source. Include the guest's
management SSH port in the requested Ubuntu rules; the SSH baseline bundle uses
TCP port 22.

Ubuntu replaces the existing UFW rules: reset, install requested access rules,
set the incoming deny policy, then enable. Reapplying intentionally resets the
baseline again. Each activation therefore contains the supplied SSH allowance.

Fedora preserves the SSH service in the public zone before daemon activation or
a DROP policy. It adds the requested permanent rules, applies them immediately
when the daemon is running, and reloads only when the policy changed. It preserves
other existing permanent rules and uses the requested TCP/UDP protocol.

Run the management-access regression checks without changing any firewall:

```sh
python tests/test_firewall_safety.py
```

The checks require PyYAML and Jinja2. Ansible execution also requires the
`community.general` and `ansible.posix` collections. See the official
[UFW module](https://docs.ansible.com/projects/ansible/latest/collections/community/general/ufw_module.html)
and [firewalld module](https://docs.ansible.com/projects/ansible/latest/collections/ansible/posix/firewalld_module.html)
contracts for reset and offline permanent configuration semantics.
