"""Synthetic proc trees verify safe package observations without argv/env reads."""

import importlib.util
import json
from pathlib import Path
import threading
import time

import pytest

HELPER = Path(__file__).resolve().parents[1] / "files/cloudinit_boot_diagnostic.py"
SECRET = "private-userdata-package-token"
UNKNOWN = {
    "package_phase": "unknown",
    "package_state": "unknown",
    "package_cpu_activity": "unavailable",
    "package_sample_ms": None,
}


@pytest.fixture
def helper():
    spec = importlib.util.spec_from_file_location("boot_diagnostic", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def process(root, pid, name, ppid, *, state="S", cpu=0, start=100):
    directory = root / str(pid)
    directory.mkdir(exist_ok=True)
    fields = ["0"] * 50
    fields[0], fields[1], fields[11], fields[19] = (
        state,
        str(ppid),
        str(cpu),
        str(start),
    )
    # Linux /proc/<pid>/stat exposes comm with the 15-byte visible limit.
    (directory / "stat").write_text(f"{pid} ({name[:15]}) " + " ".join(fields))
    (directory / "cmdline").write_text(SECRET)
    (directory / "environ").write_text(SECRET)


def tree(root, phase="dpkg"):
    process(root, 1, "systemd", 0)
    process(root, 10, "cloud-init", 1)
    process(root, 20, "apt-get", 10)
    process(root, 30, "dpkg", 20)
    if phase != "dpkg":
        process(root, 40, phase, 30)
    # Unrelated work must not become the boot diagnostic's phase/activity.
    process(root, 90, "update-grub", 1, state="R", cpu=1000)
    process(root, 91, SECRET, 1)


def observe(helper, root, change=None):
    worker = None
    if change:
        worker = threading.Thread(target=lambda: (time.sleep(0.035), change()))
        worker.start()
    try:
        result = helper.package_progress(root, deadline=time.monotonic() + 1)
    finally:
        if worker:
            worker.join()
    assert SECRET not in json.dumps(result)
    return result


def test_real_failure_shape_reports_dpkg_configuration_without_claiming_stall(
    helper, tmp_path
):
    tree(tmp_path)
    result = observe(helper, tmp_path)
    assert result == {
        "package_phase": "dpkg",
        "package_state": "sleeping",
        "package_cpu_activity": "not_observed",
        "package_sample_ms": result["package_sample_ms"],
    }
    assert 80 <= result["package_sample_ms"] <= 1000


def test_observation_interval_includes_time_spent_collecting_first_snapshot(
    helper, tmp_path, monkeypatch
):
    tree(tmp_path)
    clock = [100.0]
    snapshot = helper.process_snapshot
    scans = 0

    def slow_first_snapshot(root, deadline):
        nonlocal scans
        rows = snapshot(root, deadline)
        if scans == 0:
            clock[0] += 0.25
        scans += 1
        return rows

    def advance(seconds):
        clock[0] += seconds

    monkeypatch.setattr(helper, "process_snapshot", slow_first_snapshot)
    monkeypatch.setattr(helper.time, "monotonic", lambda: clock[0])
    monkeypatch.setattr(helper.time, "sleep", advance)
    result = helper.package_progress(tmp_path, deadline=105)
    assert result["package_phase"] == "dpkg"
    assert result["package_sample_ms"] == pytest.approx(350, abs=1)


@pytest.mark.parametrize(
    "program,phase", [("update-initramfs", "initramfs"), ("grub-mkconfig", "grub")]
)
def test_known_phase_includes_cpu_movement_of_unlabelled_children(
    helper, tmp_path, program, phase
):
    tree(tmp_path, program)
    process(tmp_path, 50, "zstd", 40, state="R", cpu=5)
    result = observe(
        helper, tmp_path, lambda: process(tmp_path, 50, "zstd", 40, state="R", cpu=8)
    )
    assert result["package_phase"] == phase
    assert result["package_state"] == "running"
    assert result["package_cpu_activity"] == "observed"


def test_ambiguous_cloud_init_parents_cannot_select_one_package_tree(helper, tmp_path):
    tree(tmp_path)
    process(tmp_path, 60, "cloud-init", 1)
    process(tmp_path, 70, "apt-get", 60)
    assert observe(helper, tmp_path) == UNKNOWN


@pytest.mark.parametrize(
    "change", ["pid_reuse", "new_child", "removed_child", "cpu_reset"]
)
def test_changed_process_identity_or_membership_never_becomes_false_no_progress(
    helper, tmp_path, change
):
    tree(tmp_path)

    def mutate():
        if change == "pid_reuse":
            process(tmp_path, 30, "dpkg", 20, start=101)
        elif change == "new_child":
            process(tmp_path, 40, "sh", 30)
        elif change == "removed_child":
            (tmp_path / "30/stat").unlink()
        else:
            process(tmp_path, 30, "dpkg", 20, cpu=0)

    if change == "cpu_reset":
        process(tmp_path, 30, "dpkg", 20, cpu=10)
    assert observe(helper, tmp_path, mutate) == UNKNOWN


@pytest.mark.parametrize(
    "fault",
    [
        "malformed_stat",
        "oversized_stat",
        "cycle",
        "missing_parent",
        "invalid_state",
        "unreadable_stat",
    ],
)
def test_malformed_or_incomplete_process_evidence_is_unavailable(
    helper, tmp_path, fault
):
    tree(tmp_path)
    if fault == "malformed_stat":
        (tmp_path / "30/stat").write_text(SECRET)
    elif fault == "oversized_stat":
        (tmp_path / "30/stat").write_text("x" * 4097)
    elif fault == "cycle":
        process(tmp_path, 20, "apt-get", 30)
    elif fault == "missing_parent":
        process(tmp_path, 20, "apt-get", 999)
    elif fault == "invalid_state":
        process(tmp_path, 30, "dpkg", 20, state="Q")
    else:
        (tmp_path / "30/stat").unlink()
        (tmp_path / "30/stat").mkdir()
    assert observe(helper, tmp_path) == UNKNOWN


def test_exhausted_budget_does_not_read_proc_or_extend_status_deadline(
    helper, tmp_path
):
    assert (
        helper.package_progress(tmp_path / "missing", deadline=time.monotonic() - 1)
        == UNKNOWN
    )


def test_absent_cloud_init_package_tree_is_explicitly_none(helper, tmp_path):
    process(tmp_path, 1, "systemd", 0)
    process(tmp_path, 20, "apt-get", 1)
    result = observe(helper, tmp_path)
    assert result["package_phase"] == result["package_state"] == "none"
    assert result["package_cpu_activity"] == "unavailable"


def test_process_enumeration_bound_refuses_partial_evidence(helper, tmp_path):
    tree(tmp_path)
    for index in range(4097):
        (tmp_path / f"other-{index}").touch()
    assert observe(helper, tmp_path) == UNKNOWN


def test_existing_status_survives_when_its_call_consumes_the_sampling_budget(
    helper, monkeypatch, capsys
):
    monkeypatch.setattr(
        helper,
        "status_output",
        lambda **_: {"status": "running", "stage": "modules-final"},
    )
    clock = iter([0, 6])
    monkeypatch.setattr(helper.time, "monotonic", lambda: next(clock))
    helper.main()
    result = json.loads(capsys.readouterr().out)
    assert result["diagnostic"] == "available"
    assert result["stage"] == "modules-final"
    assert {key: result[key] for key in UNKNOWN} == UNKNOWN


def test_unreadable_process_evidence_does_not_discard_valid_cloud_init_status(
    helper, monkeypatch, capsys
):
    monkeypatch.setattr(
        helper,
        "status_output",
        lambda **_: {"status": "running", "stage": "modules-final"},
    )

    def unavailable(*_args):
        raise PermissionError("private process data")

    monkeypatch.setattr(helper, "process_snapshot", unavailable)
    helper.main()
    result = json.loads(capsys.readouterr().out)
    assert result["diagnostic"] == "available"
    assert {key: result[key] for key in UNKNOWN} == UNKNOWN
