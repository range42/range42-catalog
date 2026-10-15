"""Exercise the native Compose sync without packages, Docker or live hosts."""
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import sys
import threading

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519
import paramiko
import pytest
import yaml


ROLE = Path(__file__).resolve().parents[1] / "02_ansible_layer/admin/roles/software.configure.docker-compose"


def sync_task(send_poc):
    tasks = yaml.safe_load((ROLE / "tasks/ubuntu/deploy.yml").read_text())
    suffix = "NO_POC" if send_poc == "NO" else "WITH_POC"
    return next(task for task in tasks[0]["block"] if task.get("name", "").endswith(suffix))


def run_sync(tmp_path, send_poc, *, preserve=None, remote=False, environment=None):
    binary = Path(sys.executable).parent / "ansible-playbook"
    if not binary.is_file() or not shutil.which("rsync"):
        pytest.skip("The behavior tests require Ansible, ansible.posix and rsync")
    source, destination = tmp_path / "source", tmp_path / "destination"
    source.mkdir(exist_ok=True)
    destination.mkdir(exist_ok=True)
    variables = yaml.safe_load((ROLE / "defaults/main.yml").read_text()) or {}
    variables.update({"LOCAL__PROJECT_DIR": str(source), "REMOTE_PROJECT_DIR": str(destination),
                      "LABEL_PROJECT_TYPE": "fixture", "LABEL_PROJET_NAME": "fixture", "SEND_POC_DIR": send_poc})
    if preserve is not None:
        variables["DOCKER_COMPOSE_PRESERVE_REMOTE_ENV"] = preserve
    name = "fixture.invalid" if remote else "localhost"
    inventory = {"all": {"hosts": {name: {"ansible_connection": "ssh" if remote else "local"},
        "localhost": {"ansible_connection": "local", "ansible_python_interpreter": sys.executable}}}}
    if remote:
        inventory["all"]["hosts"][name].update({
            "ansible_ssh_common_args": "-F " + shlex.quote(str(tmp_path / "private 'ssh config")),
            "ansible_ssh_extra_args": "-o LogLevel=ERROR",
        })
    hosts = tmp_path / "hosts.yml"
    hosts.write_text(yaml.safe_dump(inventory))
    playbook = tmp_path / "play.yml"
    playbook.write_text(yaml.safe_dump([{"hosts": name, "gather_facts": False,
        "vars": variables, "tasks": [sync_task(send_poc)]}], sort_keys=False))
    config = tmp_path / "ansible.cfg"
    config.write_text("[defaults]\nhost_key_checking=True\nretry_files_enabled=False\n")
    return subprocess.run([str(binary), "-i", str(hosts), str(playbook)],
        env={**os.environ, "ANSIBLE_CONFIG": str(config), "ANSIBLE_HOST_KEY_CHECKING": "True",
             "PYTHONDONTWRITEBYTECODE": "1", **(environment or {})},
        capture_output=True, text=True, timeout=20)


@pytest.mark.parametrize("send_poc", ["NO", "YES"])
@pytest.mark.parametrize("preserve", [None, False, True])
def test_native_sync_preserves_env_only_when_requested(tmp_path, send_poc, preserve):
    source, destination = tmp_path / "source", tmp_path / "destination"
    source.mkdir()
    destination.mkdir()
    (source / ".env").write_text("PUBLIC_FIXTURE=catalog-default\n")
    (source / ".env.example").write_text("PUBLIC_FIXTURE=example\n")
    (source / "compose.yml").write_text("services: {}\n")
    (source / "poc").mkdir()
    (source / "poc/proof.txt").write_text("fixture\n")
    (source / "nested").mkdir()
    (source / "nested/.env").write_text("PUBLIC_FIXTURE=nested\n")
    env = destination / ".env"
    env.write_text("PUBLIC_FIXTURE=retained-private-settings\n")
    env.chmod(0o600)
    original, inode = env.read_bytes(), env.stat().st_ino
    result = run_sync(tmp_path, send_poc, preserve=preserve)
    assert result.returncode == 0, result.stdout + result.stderr
    assert env.read_bytes() == (original if preserve else (source / ".env").read_bytes())
    if preserve:
        assert env.stat().st_ino == inode and env.stat().st_mode & 0o777 == 0o600
    assert (destination / ".env.example").read_bytes() == (source / ".env.example").read_bytes()
    assert (destination / "compose.yml").read_bytes() == (source / "compose.yml").read_bytes()
    assert (destination / "nested/.env").read_bytes() == (source / "nested/.env").read_bytes()
    assert (destination / "poc/proof.txt").exists() is (send_poc == "YES")


@pytest.mark.parametrize("send_poc", ["NO", "YES"])
def test_preserving_env_does_not_deliver_a_source_env_to_a_fresh_destination(tmp_path, send_poc):
    (tmp_path / "source").mkdir()
    (tmp_path / "source/.env").write_text("PUBLIC_FIXTURE=source\n")
    result = run_sync(tmp_path, send_poc, preserve=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not (tmp_path / "destination/.env").exists()


def host_key():
    private = ed25519.Ed25519PrivateKey.generate()
    pem = private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH,
                               serialization.NoEncryption())
    return paramiko.Ed25519Key.from_private_key(io.StringIO(pem.decode()))


@pytest.mark.parametrize("send_poc", ["NO", "YES"])
@pytest.mark.parametrize("trust", ["known", "unknown", "changed"])
@pytest.mark.parametrize("wrapper", [False, True])
def test_native_rsync_retains_private_proxy_route_and_host_pins(tmp_path, send_poc, trust, wrapper):
    real_ssh = shutil.which("ssh")
    assert real_ssh
    key = host_key()
    saved = host_key() if trust == "changed" else key
    pins = tmp_path / "private known hosts"
    pins.write_text("" if trust == "unknown" else "fixture-pin " + saved.get_name() + " " + saved.get_base64() + "\n")
    pins.chmod(0o600)
    original = pins.read_bytes()
    command_received, stop = threading.Event(), threading.Event()
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(2)
    listener.settimeout(0.1)

    class Server(paramiko.ServerInterface):
        def check_auth_none(self, username):
            return paramiko.AUTH_SUCCESSFUL

        def check_channel_request(self, kind, channel_id):
            return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

        def check_channel_exec_request(self, channel, command):
            if command.startswith(b"rsync --server "):
                command_received.set()
                return True
            return False

    def serve():
        transport = None
        try:
            while not stop.is_set():
                try:
                    client, _ = listener.accept()
                    break
                except socket.timeout:
                    continue
            else:
                return
            transport = paramiko.Transport(client)
            transport.add_server_key(key)
            transport.start_server(server=Server())
            channel = transport.accept(4)
            if channel is not None and command_received.wait(2):
                # Local transfer tests cover the rsync protocol. This endpoint
                # stops after the real SSH handshake/exec, without remote files.
                channel.send_stderr(b"fixture: authenticated rsync reached\n")
                channel.send_exit_status(23)
                channel.close()
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            if transport is not None:
                transport.close()

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    proxy = tmp_path / "proxy.py"
    proxy_marker = tmp_path / "proxy-used"
    proxy.write_text(
        "import os,select,socket,sys\nfrom pathlib import Path\n"
        f"Path({str(proxy_marker)!r}).touch()\n"
        f"s=socket.create_connection(('127.0.0.1',{listener.getsockname()[1]}))\n"
        "while True:\n"
        "    ready,_,_=select.select([s,sys.stdin.buffer],[],[],5)\n"
        "    if not ready: break\n"
        "    for item in ready:\n"
        "        data=os.read(0,65536) if item is sys.stdin.buffer else s.recv(65536)\n"
        "        if not data: sys.exit(0)\n"
        "        s.sendall(data) if item is sys.stdin.buffer else os.write(1,data)\n"
    )
    config = tmp_path / "private 'ssh config"
    config.write_text(
        "Host fixture.invalid\n  HostName 192.0.2.123\n  User fixture\n"
        "  HostKeyAlias fixture-pin\n  StrictHostKeyChecking yes\n  BatchMode yes\n"
        f"  UserKnownHostsFile {json.dumps(str(pins))}\n  GlobalKnownHostsFile /dev/null\n"
        "  IdentityFile none\n  IdentityAgent none\n  PreferredAuthentications none\n"
        f"  ProxyCommand {shlex.quote(sys.executable)} {shlex.quote(str(proxy))}\n"
    )
    capture = tmp_path / "ssh-argv.json"
    bindir = tmp_path / "bin"
    bindir.mkdir()
    ssh = bindir / "ssh"
    # Refuse missing fixture routing before exec, so even the broken role can
    # never contact a real host or read the operator's SSH configuration.
    prefix = ["-o", "ServerAliveInterval=2"] if wrapper else []
    ssh.write_text(
        f"#!{sys.executable}\nimport json,os,sys\nfrom pathlib import Path\n"
        f"Path({str(capture)!r}).write_text(json.dumps(sys.argv[1:]))\n"
        f"if {str(config)!r} not in sys.argv: raise SystemExit(93)\n"
        f"os.execv({real_ssh!r},[{real_ssh!r}]+{prefix!r}+sys.argv[1:])\n"
    )
    ssh.chmod(0o700)
    try:
        result = run_sync(tmp_path, send_poc, remote=True,
                          environment={"PATH": str(bindir) + ":" + os.environ["PATH"]})
        assert capture.is_file(), result.stdout + result.stderr
        args = json.loads(capture.read_text())
        assert str(config) in args, "rsync dropped the configured private SSH route: " + repr(args)
        assert "StrictHostKeyChecking=no" not in args and "UserKnownHostsFile=/dev/null" not in args
        assert "LogLevel=ERROR" in args
        effective = subprocess.run([real_ssh, "-G", *prefix, *args],
                                   capture_output=True, text=True, check=True)
        options = dict(line.split(" ", 1) for line in effective.stdout.splitlines())
        assert options["stricthostkeychecking"] == "true"
        assert options["userknownhostsfile"] == str(pins)
        assert str(proxy) in options["proxycommand"]
        if wrapper:
            assert options["serveraliveinterval"] == "2"
        assert proxy_marker.exists(), result.stdout + result.stderr
        assert command_received.is_set() is (trust == "known"), result.stdout + result.stderr
        assert result.returncode != 0  # The fixture ends before any remote transfer.
        if trust != "known":
            assert "Host key verification failed" in result.stdout + result.stderr
        assert pins.read_bytes() == original
    finally:
        stop.set()
        listener.close()
        thread.join(timeout=6)
