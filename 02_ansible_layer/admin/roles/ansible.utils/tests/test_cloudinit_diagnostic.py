"""Private CLI fixtures exercise the diagnostic without reading host cloud-init."""

import json
import os
from pathlib import Path
import subprocess
import sys
import time

import pytest


ROLE = Path(__file__).resolve().parents[1]
HELPER = ROLE / "files/cloudinit_boot_diagnostic.py"
UNAVAILABLE = {
    "diagnostic": "unavailable",
    "status": "unknown",
    "stage": "unknown",
    "errors": None,
    "recoverable_errors": None,
}
SECRET = "private-userdata-token-do-not-export"


def invoke(tmp_path, document=None, *, rc=0, raw=None, sleep=False, missing=False):
    assert HELPER.is_file(), "The bounded cloud-init diagnostic helper is missing"
    fixture = tmp_path / "cloud-init"
    fixture.write_text(
        f"#!{sys.executable}\nimport os,sys,time\n"
        "assert sys.argv[1:]==['status','--format=json']\n"
        "time.sleep(60) if os.environ['FIXTURE_SLEEP']=='1' else None\n"
        "print(os.environ['FIXTURE_OUTPUT'])\n"
        "sys.exit(int(os.environ['FIXTURE_RC']))\n"
    )
    fixture.chmod(0o700)
    before = time.monotonic()
    result = subprocess.run(
        [sys.executable, str(HELPER)],
        env={
            **os.environ,
            "PATH": str(tmp_path / "missing") if missing else str(tmp_path),
            "FIXTURE_OUTPUT": raw if raw is not None else json.dumps(document),
            "FIXTURE_RC": str(rc),
            "FIXTURE_SLEEP": "1" if sleep else "0",
        },
        capture_output=True,
        text=True,
        timeout=8,
    )
    assert result.returncode == 0 and result.stderr == ""
    assert SECRET not in result.stdout
    document = json.loads(result.stdout)
    assert document.pop("package_phase") in {
        "unknown",
        "none",
        "apt",
        "dpkg",
        "initramfs",
        "grub",
    }
    assert document.pop("package_state") in {
        "unknown",
        "none",
        "running",
        "sleeping",
        "blocked",
        "stopped",
        "zombie",
        "mixed",
    }
    assert document.pop("package_cpu_activity") in {
        "unavailable",
        "observed",
        "not_observed",
    }
    interval = document.pop("package_sample_ms")
    assert interval is None or type(interval) is int and 0 <= interval <= 5000
    return document, time.monotonic() - before


@pytest.mark.parametrize(
    "rc,status", [(0, "running"), (1, "error - done"), (2, "degraded done")]
)
def test_emits_only_allowed_status_stage_and_error_counts(tmp_path, rc, status):
    document = {
        "status": "running",
        "extended_status": status,
        "stage": "modules-final",
        "errors": [SECRET],
        "recoverable_errors": {"WARNING": [SECRET, SECRET]},
        "detail": SECRET,
        "datasource": SECRET,
        "modules-final": {"errors": [SECRET]},
    }
    result, _ = invoke(tmp_path, document, rc=rc)
    assert result == {
        "diagnostic": "available",
        "status": status,
        "stage": "modules-final",
        "errors": 1,
        "recoverable_errors": 2,
    }


def test_missing_active_stage_is_unknown_not_inferred_from_completed_stages(tmp_path):
    result, _ = invoke(
        tmp_path, {"status": "running", "errors": [], "modules-final": {"start": 123}}
    )
    assert result == {
        "diagnostic": "available",
        "status": "running",
        "stage": "unknown",
        "errors": 0,
        "recoverable_errors": None,
    }


@pytest.mark.parametrize(
    "document",
    [
        {"status": SECRET},
        {"status": "running", "stage": SECRET},
        {"status": "running", "errors": SECRET},
        {"status": "running", "recoverable_errors": {"WARNING": SECRET}},
        {"status": "running", "extended_status": SECRET},
        [SECRET],
        None,
    ],
)
def test_untrusted_or_malformed_status_never_becomes_a_public_message(
    tmp_path, document
):
    assert invoke(tmp_path, document)[0] == UNAVAILABLE


@pytest.mark.parametrize(
    "arguments", [{"raw": "not-json"}, {"raw": "x" * 65537}, {"missing": True}]
)
def test_absent_invalid_or_oversized_cli_output_is_unavailable(tmp_path, arguments):
    assert invoke(tmp_path, **arguments)[0] == UNAVAILABLE


def test_cli_hang_is_bounded_without_increasing_the_boot_wait(tmp_path):
    result, elapsed = invoke(tmp_path, sleep=True)
    assert result == UNAVAILABLE
    assert 4.5 <= elapsed < 7
