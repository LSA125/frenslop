from __future__ import annotations

import ctypes
import os
import shutil
import subprocess
from pathlib import Path

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[2]
WINDOWS_RUNNER = Path(__file__).with_name("run_godot_regression.ps1")
WRAPPER_TIMEOUT_SECONDS = 12.0

pytestmark = pytest.mark.regression


def _find_godot_binary() -> Path:
    configured = os.environ.get("GODOT_BIN")
    if configured:
        candidate = Path(configured).expanduser().resolve()
        if candidate.is_file():
            return candidate
        pytest.fail(f"GODOT_BIN does not point to a file: {candidate}", pytrace=False)

    for name in ("godot.windows.opt.tools.64.exe", "godot4", "godot"):
        discovered = shutil.which(name)
        if not discovered:
            continue
        candidate = Path(discovered).resolve()
        if os.name == "nt" and candidate.name.lower() == "godot.exe":
            tools_binary = candidate.with_name("godot.windows.opt.tools.64.exe")
            if tools_binary.is_file():
                return tools_binary
        return candidate

    pytest.fail(
        "Godot tools binary not found. Set GODOT_BIN to godot.windows.opt.tools.64.exe.",
        pytrace=False,
    )


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return ""


def _terminate_windows_pid(pid_path: Path) -> None:
    try:
        godot_pid = int(_read(pid_path).strip())
    except ValueError:
        return

    process_terminate = 0x0001
    synchronize = 0x00100000
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    kernel32.OpenProcess.restype = ctypes.c_void_p
    kernel32.TerminateProcess.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    kernel32.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel32.OpenProcess(process_terminate | synchronize, False, godot_pid)
    if handle:
        kernel32.TerminateProcess(handle, 1)
        kernel32.WaitForSingleObject(handle, 1000)
        kernel32.CloseHandle(handle)


def _run_windows_regression(
    godot_binary: Path,
    regression: str,
    output_path: Path,
    pid_path: Path,
) -> int:
    powershell = Path(os.environ.get("SystemRoot", r"C:\Windows")) / (
        "System32/WindowsPowerShell/v1.0/powershell.exe"
    )
    command = [
        str(powershell),
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(WINDOWS_RUNNER),
        "-GodotBinary",
        str(godot_binary),
        "-ProjectPath",
        str(PROJECT_ROOT),
        "-Regression",
        regression,
        "-OutputPath",
        str(output_path),
        "-PidPath",
        str(pid_path),
    ]
    process = subprocess.Popen(
        command,
        cwd=PROJECT_ROOT,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
        creationflags=subprocess.CREATE_NO_WINDOW,
    )
    try:
        return process.wait(timeout=WRAPPER_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        _terminate_windows_pid(pid_path)
        process.terminate()
        try:
            process.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=1.0)
        pytest.fail("Godot regression wrapper timed out", pytrace=False)


def _run_posix_regression(
    godot_binary: Path,
    regression: str,
    output_path: Path,
) -> int:
    scenes = {
        "riding": "res://tests/rollback_riding_regression.tscn",
        "rapier_manual": "res://tests/rapier_collision_regression.tscn",
        "carrier_velocity": "res://tests/carrier_velocity_regression.tscn",
        "equip_combat": "res://tests/equip_combat_regression.tscn",
    }
    scene = scenes[regression]
    command = [
        str(godot_binary),
        "--headless",
        "--disable-crash-handler",
        "--log-file",
        str(output_path),
        "--path",
        str(PROJECT_ROOT),
        scene,
    ]
    if regression == "rapier_manual":
        command.extend(["--", "--manual-driver"])
    process = subprocess.Popen(command, cwd=PROJECT_ROOT, stdin=subprocess.DEVNULL)
    try:
        return process.wait(timeout=10.0)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=1.0)
        pytest.fail("Godot regression process timed out", pytrace=False)


@pytest.mark.parametrize(
    ("regression", "success_marker"),
    [
        ("riding", "ROLLBACK_RIDING_REGRESSION: PASS"),
        ("rapier_manual", "RAPIER_COLLISION_REGRESSION: PASS (manual driver"),
        ("carrier_velocity", "CARRIER_VELOCITY_REGRESSION: PASS"),
        ("equip_combat", "EQUIP_COMBAT_REGRESSION: PASS"),
    ],
)
def test_godot_regression(
    regression: str,
    success_marker: str,
    tmp_path: Path,
) -> None:
    godot_binary = _find_godot_binary()
    output_path = tmp_path / f"{regression}.log"
    pid_path = tmp_path / f"{regression}.pid"

    if os.name == "nt":
        exit_code = _run_windows_regression(
            godot_binary, regression, output_path, pid_path
        )
    else:
        exit_code = _run_posix_regression(godot_binary, regression, output_path)

    output = _read(output_path)
    assert exit_code == 0, f"Godot exited with {exit_code}\n{output}"
    assert success_marker in output, (
        f"Godot exited successfully without the expected marker {success_marker!r}\n"
        f"{output}"
    )
