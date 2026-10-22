"""Optional native guest trust uses the PVE control plane and never rotates pins."""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
from ipaddress import ip_address
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import ssl
import subprocess
import sys
import threading
import time
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519
from cryptography.x509.oid import NameOID
import paramiko
import pytest
import yaml


ROLE = Path(__file__).resolve().parents[1] / "02_ansible_layer/admin/roles/ansible.utils"
HELPER = ROLE / "library/range42_guest_hostkey_pin.py"
INVALID_QGA_BUDGETS = {
    "qga_invalid_true": True, "qga_invalid_false": False, "qga_invalid_string": "1200",
    "qga_invalid_float": 1.5, "qga_invalid_null": None, "qga_invalid_list": [],
    "qga_invalid_mapping": {}, "qga_invalid_zero": 0, "qga_invalid_negative": -1,
    "qga_invalid_max": 3601,
}


def public_key():
    return ed25519.Ed25519PrivateKey.generate().public_key().public_bytes(
        serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH).decode()


def pin_helper():
    assert HELPER.is_file(), "The catalog needs an atomic add-only host-pin helper"
    spec = importlib.util.spec_from_file_location("guest_hostkey_pin", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def private_pins(tmp_path, content=""):
    tmp_path.chmod(0o700)
    path = tmp_path / "known_hosts"
    path.write_text(content)
    path.chmod(0o600)
    return path


def test_role_local_hostkey_module_has_discoverable_ansible_documentation():
    binary = Path(sys.executable).parent / "ansible-doc"
    result = subprocess.run([str(binary), "--json", "-M", str(HELPER.parent), "range42_guest_hostkey_pin"],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
    document = json.loads(result.stdout)["range42_guest_hostkey_pin"]
    assert document["doc"]["options"]["phase"]["choices"] == ["inspect", "append"]
    assert document["examples"] and document["return"]["existing"]["type"] == "bool"


@pytest.mark.parametrize("case", ["first", "existing", "changed", "off", "denied", "bad_tls", "hostname_tls",
    "wrong_name", "wrong_ip", "wrong_ssh_ip", "malformed", "truncated", "concurrent_pin", "port_lookup",
    "alias_none", "ssh_config_drift", "vm_config_drift", "template", "tls_disabled", "check", "truncated_invalid",
    "paths_with_spaces", "redirect", "become_play", "become_inventory", "become_all",
    "qga_delayed", "qga_deadline", "qga_exhausted", "qga_minimum", "qga_maximum", *INVALID_QGA_BUDGETS])
def test_optional_agent_trust_with_real_tls_and_strict_ssh(tmp_path, case):
    if case == "paths_with_spaces":
        tmp_path = tmp_path / "private 'workspace"
        tmp_path.mkdir(mode=0o700)
    binary = Path(sys.executable).parent / "ansible-playbook"
    assert binary.is_file(), "This integration test requires the existing Ansible runtime"
    private = ed25519.Ed25519PrivateKey.generate()
    pub = private.public_key().public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH).decode()
    pem = private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH,
                              serialization.NoEncryption())
    ssh_key = paramiko.Ed25519Key.from_private_key(io.StringIO(pem.decode()))
    pins = private_pins(tmp_path, "fixture-key " + (pub if case == "existing" else public_key()) + "\n"
                        if case in ("existing", "changed") else "")
    original = pins.read_bytes()
    ssh_command, stop = threading.Event(), threading.Event()

    class SshServer(paramiko.ServerInterface):
        def check_auth_none(self, name):
            return paramiko.AUTH_SUCCESSFUL

        def check_channel_request(self, kind, channel):
            return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

        def check_channel_exec_request(self, channel, value):
            ssh_command.set()
            return value == b"true"

    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    listener.settimeout(0.2)
    port = listener.getsockname()[1]

    def serve_ssh():
        while not stop.is_set():
            try:
                client, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            transport = paramiko.Transport(client)
            try:
                transport.add_server_key(ssh_key)
                transport.start_server(server=SshServer())
                channel = transport.accept(5)
                if channel is not None and ssh_command.wait(5):
                    channel.send_exit_status(0)
                    channel.close()
                    transport.join(timeout=5)
            except (EOFError, paramiko.SSHException):
                pass
            finally:
                transport.close()
            return

    ssh_thread = threading.Thread(target=serve_ssh, daemon=True)
    ssh_thread.start()
    request_log = []
    injected = []
    config_reads = []
    agent_reads = []

    class Pve(BaseHTTPRequestHandler):
        def do_GET(self):
            parsed = urlsplit(self.path)
            query = parse_qs(parsed.query)
            request_log.append((parsed.path, query))
            assert self.headers["Authorization"] == "PVEAPIToken=fixture@pve!guest=public-fixture-secret"
            if parsed.path == "/api2/json/nodes/test-node/qemu/3191/config":
                config_reads.append(True)
                data = {"name": "other" if case == "wrong_name" else "owned-fixture", "template": int(case == "template"),
                        "ipconfig0": "ip=" + ("127.0.0.2" if case == "wrong_ip" else "127.0.0.1") + "/24",
                        "digest": ("b" if case == "vm_config_drift" and len(config_reads) > 1 else "a") * 40}
                status = 200
            else:
                if parsed.path != "/unapproved-key":
                    assert parsed.path == "/api2/json/nodes/test-node/qemu/3191/agent/file-read"
                    assert query == {"file": ["/etc/ssh/ssh_host_ed25519_key.pub"], "count": ["4096"], "decode": ["1"], "offset": ["0"]}
                agent_reads.append(True)
                if case == "concurrent_pin":
                    injected.append("fixture-key " + public_key() + "\n")
                    pins.write_text(injected[-1])
                if case == "ssh_config_drift":
                    config.write_text(config.read_text().replace("HostKeyAlias fixture-key", "HostKeyAlias another-target"))
                data = {"content": "not a public key" if case == "malformed" else pub + " fixture\n"}
                if case == "truncated":
                    data["truncated"] = 1
                elif case == "truncated_invalid":
                    data["truncated"] = "not-a-boolean"
                status = 403 if case == "denied" else 200
                if case == "qga_delayed" and len(agent_reads) <= 2:
                    status = 500 if len(agent_reads) == 1 else 503
                if case in ("qga_deadline", "qga_exhausted"):
                    status = 503
                if case == "redirect" and parsed.path.endswith("agent/file-read"):
                    status = 302
            body = json.dumps({"data": data}).encode()
            self.send_response(status)
            if status == 302:
                self.send_header("Location", "/unapproved-key")
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    ca_key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "synthetic-pve")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(ca_key.public_key())
            .serial_number(x509.random_serial_number()).not_valid_before(now - timedelta(minutes=1))
            .not_valid_after(now + timedelta(days=1)).add_extension(
                x509.SubjectAlternativeName([x509.DNSName("other.invalid") if case == "hostname_tls"
                                             else x509.IPAddress(ip_address("127.0.0.1"))]), critical=False)
            .sign(ca_key, hashes.SHA256()))
    ca, tls_key = tmp_path / "pve.pem", tmp_path / "tls-key.pem"
    ca.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    untrusted = tmp_path / "untrusted-ca.pem"
    other_key = ec.generate_private_key(ec.SECP256R1())
    other_cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(other_key.public_key())
                  .serial_number(x509.random_serial_number()).not_valid_before(now - timedelta(minutes=1))
                  .not_valid_after(now + timedelta(days=1)).sign(other_key, hashes.SHA256()))
    untrusted.write_bytes(other_cert.public_bytes(serialization.Encoding.PEM))
    tls_key.write_bytes(ca_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                           serialization.NoEncryption()))
    tls_key.chmod(0o600)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Pve)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(ca, tls_key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    api_thread = threading.Thread(target=server.serve_forever, daemon=True)
    api_thread.start()

    roles = tmp_path / "roles"
    copied = roles / "ansible.utils"
    shutil.copytree(ROLE, copied)
    # Shorten only retry timers in the disposable role copy.
    def timers(value, *, keep_retries=False):
        if isinstance(value, dict):
            for key, item in value.items():
                if key == "delay" or (key == "retries" and not keep_retries):
                    value[key] = 0
                else:
                    timers(item, keep_retries=keep_retries)
        elif isinstance(value, list):
            for item in value:
                timers(item, keep_retries=keep_retries)
    for path in (copied / "tasks/wait/openssh_server").glob("*.yml"):
        value = yaml.safe_load(path.read_text())
        timers(value, keep_retries=case.startswith("qga_") and path.name == "pve_agent_hostkey.yml")
        path.write_text(yaml.safe_dump(value, sort_keys=False))
    config = tmp_path / "ssh-config"
    key_alias = "" if case == "port_lookup" else " HostKeyAlias none\n" if case == "alias_none" else " HostKeyAlias fixture-key\n"
    config.write_text("Host guest.invalid\n HostName " + ("127.0.0.2" if case == "wrong_ssh_ip" else "127.0.0.1")
                     + f"\n Port {port}\n User fixture\n" + key_alias + " GlobalKnownHostsFile /dev/null\n IdentityFile /dev/null\n")
    escalated = tmp_path / "unexpected-become"
    fake_become = tmp_path / "become"
    fake_become.write_text(f"#!{sys.executable}\nfrom pathlib import Path\n"
                          f"Path({str(escalated)!r}).touch()\nraise SystemExit(97)\n")
    fake_become.chmod(0o700)
    inventory = tmp_path / "hosts.yml"
    inventory.write_text(yaml.safe_dump({"all": {"hosts": {"guest.invalid": {
        "ansible_connection": "ssh", "ansible_ssh_common_args": "-F " + shlex.quote(str(config)),
        "ARG_vm_ssh_name": "guest.invalid", "deployer_cli_user_ssh_known_hosts": str(pins),
        "range42_guest_hostkey_from_pve_agent": case != "off", "global_vm_id": 3191,
        "global_vm_name": "owned-fixture", "global_vm_ci_ip": "127.0.0.1",
        "proxmox_api_host": f"127.0.0.1:{server.server_port}", "proxmox_node": "test-node",
        "proxmox_api_validate_certs": case != "tls_disabled", "proxmox_api_user": "fixture@pve",
        "proxmox_api_token_id": "guest", "proxmox_api_token_secret": "public-fixture-secret",
        **({"range42_cloud_init_timeout_seconds": INVALID_QGA_BUDGETS[case]} if case in INVALID_QGA_BUDGETS else {}),
        **({"range42_cloud_init_timeout_seconds": 1} if case in ("qga_exhausted", "qga_minimum") else {}),
        **({"range42_cloud_init_timeout_seconds": 3600} if case == "qga_maximum" else {}),
        **({"ansible_become": True, "ansible_become_exe": str(fake_become)} if case == "become_inventory" else {}),
    }}}}))
    if case == "become_all":
        value = yaml.safe_load(inventory.read_text())
        value["all"]["vars"] = {"ansible_become": True, "ansible_become_exe": str(fake_become)}
        inventory.write_text(yaml.safe_dump(value))
    marker = tmp_path / "next-stage"
    playbook = tmp_path / "main.yml"
    playbook.write_text(yaml.safe_dump([{"hosts": "guest.invalid", "gather_facts": False,
        "become": case == "become_play", "become_exe": str(fake_become),
        "vars": {"requested_tasks": ["wait/openssh_server/" +
                    ("pve_agent_hostkey.yml" if case.startswith("become_") else "is_reachable.yml")]}, "tasks": [
            {"ansible.builtin.include_role": {"name": "ansible.utils"}},
            {"ansible.builtin.copy": {"content": "next", "dest": str(marker), "mode": "0600"}, "delegate_to": "localhost",
             "become": False, "vars": {"ansible_become": False}},
        ]}], sort_keys=False))
    ansible_config = tmp_path / "ansible.cfg"
    ansible_config.write_text("[defaults]\nhost_key_checking=True\nretry_files_enabled=False\n")
    clock = tmp_path / "clock"
    clock.mkdir()
    ticks = clock / "ticks"
    ticks.write_text("1000")
    step = 235 if case == "qga_delayed" else 2 if case == "qga_exhausted" else 700
    date = clock / "date"
    date.write_text(f"#!{sys.executable}\nimport sys\nfrom pathlib import Path\n"
                    "assert sys.argv[1:] == ['+%s']\n"
                    f"p = Path({str(ticks)!r})\nv = int(p.read_text())\nprint(v)\np.write_text(str(v + {step}))\n")
    date.chmod(0o700)
    try:
        result = subprocess.run([str(binary), "-i", str(inventory), str(playbook)] + (["--check"] if case == "check" else []),
            env={**os.environ, "ANSIBLE_CONFIG": str(ansible_config), "ANSIBLE_ROLES_PATH": str(roles),
                 "ANSIBLE_HOST_KEY_CHECKING": "True" if case == "off" else "False",
                 "RANGE42_PROXMOX_CA_FILE": str(untrusted) if case == "bad_tls" else str(ca),
                 **({"PATH": str(clock) + os.pathsep + os.environ["PATH"]}
                    if case in ("qga_delayed", "qga_deadline", "qga_exhausted") else {})},
            capture_output=True, text=True, timeout=25)
        output = result.stdout + result.stderr
        success = case in ("first", "existing", "port_lookup", "alias_none", "check", "paths_with_spaces",
                           "become_play", "become_inventory", "become_all", "qga_delayed", "qga_minimum", "qga_maximum")
        executes = success and case != "check" and not case.startswith("become_")
        assert (result.returncode == 0) is success, output
        assert marker.exists() is (success and case != "check")
        assert ssh_command.is_set() is executes
        assert "public-fixture-secret" not in output
        if case == "qga_delayed":
            # Two unavailable QGA responses span 470 simulated seconds, longer
            # than the measured 466.65-second cold cloud-init run. The default
            # budget must retain enough attempts and admit the eventual key.
            assert len(agent_reads) == 3
            assert "240 retries left" in output, output
            assert int(ticks.read_text()) >= 1705
        elif case == "qga_deadline":
            # The controller deadline, not just the retry count, bounds slow
            # QGA responses. Keep the default 240-attempt cap in this test.
            assert len(agent_reads) == 2
            assert "240 retries left" in output, output
        elif case == "qga_exhausted":
            assert len(agent_reads) == 1
        if case.startswith("become_"):
            assert not escalated.exists()
            assert pins.stat().st_uid == os.getuid()
        if case == "redirect":
            assert not any(path == "/unapproved-key" for path, _ in request_log)
        if case in ("first", "port_lookup", "alias_none", "paths_with_spaces", "become_play", "become_inventory", "become_all", "qga_delayed", "qga_minimum", "qga_maximum"):
            target = f"[127.0.0.1]:{port}" if case == "port_lookup" else "none" if case == "alias_none" else "fixture-key"
            assert pins.read_text() == target + " " + pub + "\n"
            assert any(path.endswith("agent/file-read") for path, _ in request_log)
        elif case == "concurrent_pin":
            assert injected and pins.read_text() == injected[-1]
        else:
            assert pins.read_bytes() == original
        if case in ("existing", "changed", "off", "bad_tls", "hostname_tls", "wrong_ssh_ip", "tls_disabled", "check") or case in INVALID_QGA_BUDGETS:
            assert not request_log
        elif case in ("wrong_name", "wrong_ip", "template"):
            assert request_log and all(path.endswith("/config") for path, _ in request_log)
        else:
            assert any(path.endswith("agent/file-read") for path, _ in request_log)
    finally:
        stop.set()
        listener.close()
        server.shutdown()
        server.server_close()
        api_thread.join(timeout=2)
        ssh_thread.join(timeout=6)


def test_concurrent_pin_writes_do_not_replace_the_winner(tmp_path):
    helper = pin_helper()
    path = private_pins(tmp_path)
    state = helper.inspect_known_hosts(path, "guest")["state"]
    keys = [public_key(), public_key()]
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda key: helper.append_known_host(path, "guest", key, state), keys))
    assert sum(result["changed"] for result in results) == 1
    assert path.read_text() in ["guest " + key + "\n" for key in keys]


def test_effective_ssh_config_query_has_a_time_bound(tmp_path):
    helper = pin_helper()
    executable = tmp_path / "ssh"
    executable.write_text(f"#!{sys.executable}\nimport time\ntime.sleep(6)\n"
                          "print('hostname 127.0.0.1\\nport 22\\nglobalknownhostsfile /dev/null')\n")
    executable.chmod(0o700)
    module = SimpleNamespace(params={"expected_ip": "127.0.0.1", "ssh_host": "guest",
        "known_hosts_file": str(tmp_path / "known_hosts"), "ssh_common_args": "", "ssh_extra_args": ""},
        get_bin_path=lambda *_args, **_kwargs: str(executable),
        run_command=lambda argv: (lambda result: (result.returncode, result.stdout, result.stderr))(
            subprocess.run(argv, capture_output=True, text=True)))
    started = time.monotonic()
    with pytest.raises(subprocess.TimeoutExpired):
        helper._ssh_binding(module)
    assert time.monotonic() - started < 5.75


@pytest.mark.parametrize("marker", ["", "@revoked ", "@cert-authority "])
def test_existing_hashed_or_marked_target_is_preserved(tmp_path, marker):
    helper = pin_helper()
    path = private_pins(tmp_path, marker + "guest " + public_key() + "\n")
    if not marker:
        subprocess.run(["ssh-keygen", "-H", "-f", str(path)], capture_output=True, check=True)
    original = path.read_bytes()
    inspected = helper.inspect_known_hosts(path, "guest")
    assert inspected["existing"]
    result = helper.append_known_host(path, "guest", public_key(), inspected["state"])
    assert not result["changed"] and path.read_bytes() == original


def test_replacement_between_read_and_open_cannot_receive_a_pin(tmp_path, monkeypatch):
    helper = pin_helper()
    path = private_pins(tmp_path)
    state = helper.inspect_known_hosts(path, "guest")["state"]
    real_open = helper.os.open
    replacement = "unrelated " + public_key() + "\n"

    def changing_open(name, flags, *args, **kwargs):
        if name == path.name and flags & os.O_APPEND:
            other = tmp_path / "replacement"
            other.write_text(replacement)
            other.chmod(0o600)
            other.replace(path)
        return real_open(name, flags, *args, **kwargs)

    monkeypatch.setattr(helper.os, "open", changing_open)
    with pytest.raises(ValueError):
        helper.append_known_host(path, "guest", public_key(), state)
    assert path.read_text() == replacement


def test_content_change_between_read_and_open_cannot_receive_a_pin(tmp_path, monkeypatch):
    helper = pin_helper()
    path = private_pins(tmp_path)
    state = helper.inspect_known_hosts(path, "guest")["state"]
    real_open = helper.os.open
    replacement = "unrelated " + public_key() + "\n"

    def changing_open(name, flags, *args, **kwargs):
        if name == path.name and flags & os.O_APPEND:
            path.write_text(replacement)
        return real_open(name, flags, *args, **kwargs)

    monkeypatch.setattr(helper.os, "open", changing_open)
    with pytest.raises(ValueError):
        helper.append_known_host(path, "guest", public_key(), state)
    assert path.read_text() == replacement


@pytest.mark.parametrize("case", ["symlink", "ownership", "mode", "drift"])
def test_pin_storage_changes_fail_without_writing(tmp_path, monkeypatch, case):
    helper = pin_helper()
    path = private_pins(tmp_path)
    state = helper.inspect_known_hosts(path, "guest")["state"]
    if case == "symlink":
        other = tmp_path / "other"
        path.rename(other)
        path.symlink_to(other)
    elif case == "ownership":
        monkeypatch.setattr(helper.os, "geteuid", lambda: os.getuid() + 1)
    elif case == "mode":
        path.chmod(0o644)
    else:
        path.write_text("unrelated " + public_key() + "\n")
    original = path.read_bytes()
    with pytest.raises(ValueError):
        helper.append_known_host(path, "guest", public_key(), state)
    assert path.read_bytes() == original


@pytest.mark.parametrize("value", ["not a key", "-----BEGIN OPENSSH PRIVATE KEY-----", public_key() + "\nother " + public_key()])
def test_only_one_valid_ed25519_public_key_can_be_appended(tmp_path, value):
    helper = pin_helper()
    path = private_pins(tmp_path)
    state = helper.inspect_known_hosts(path, "guest")["state"]
    with pytest.raises(ValueError):
        helper.append_known_host(path, "guest", value, state)
    assert path.read_bytes() == b""
