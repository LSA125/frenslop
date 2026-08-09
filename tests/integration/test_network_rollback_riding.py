from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[2]
INTEGRATION_SCENE = "res://tests/production_e2e_bootstrap.tscn"
WINDOWS_PEER_RUNNER = Path(__file__).with_name("run_godot_peer.ps1")
PROCESS_TIMEOUT_SECONDS = 10.0
HOST_READY_TIMEOUT_SECONDS = 3.0

pytestmark = pytest.mark.integration


@dataclass
class GodotProcess:
    role: str
    process: subprocess.Popen[str]
    started_at: float
    output_path: Path
    trace_path: Path
    pid_path: Path
    output_stream: object | None = None


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


def _reserve_udp_port_pair() -> int:
    for _ in range(100):
        first = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        second = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            first.bind(("127.0.0.1", 0))
            port = first.getsockname()[1]
            if port >= 65535:
                continue
            second.bind(("127.0.0.1", port + 1))
            return port
        except OSError:
            continue
        finally:
            first.close()
            second.close()
    pytest.fail("Could not reserve adjacent loopback UDP ports", pytrace=False)


def _launch_peer(
    godot_binary: Path,
    role: str,
    bottom_role: str,
    latency_ms: int,
    scenario: str,
    port: int,
    output_path: Path,
    trace_path: Path,
) -> GodotProcess:
    godot_arguments = [
        str(godot_binary),
        "--headless",
        "--disable-crash-handler",
        "--max-fps",
        "60",
        "--path",
        str(PROJECT_ROOT),
        INTEGRATION_SCENE,
        "--",
        f"--integration-role={role}",
        f"--integration-bottom={bottom_role}",
        f"--integration-scenario={scenario}",
        f"--integration-port={port}",
        f"--integration-latency-ms={latency_ms}",
        f"--integration-result-file={trace_path}",
    ]
    environment = os.environ.copy()
    environment["NETFOX_NO_AUTOCONNECT"] = "1"
    pid_path = output_path.with_suffix(".pid")

    output_stream = None
    if os.name == "nt":
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
            str(WINDOWS_PEER_RUNNER),
            "-GodotBinary",
            str(godot_binary),
            "-ProjectPath",
            str(PROJECT_ROOT),
            "-ScenePath",
            INTEGRATION_SCENE,
            "-Role",
            role,
            "-BottomRole",
            bottom_role,
            "-Scenario",
            scenario,
            "-LatencyMs",
            str(latency_ms),
            "-Port",
            str(port),
            "-TracePath",
            str(trace_path),
            "-OutputPath",
            str(output_path),
            "-PidPath",
            str(pid_path),
        ]
        stdout_target = subprocess.DEVNULL
    else:
        command = godot_arguments
        output_stream = output_path.open("w", encoding="utf-8", errors="replace")
        stdout_target = output_stream

    process = subprocess.Popen(
        command,
        cwd=PROJECT_ROOT,
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=stdout_target,
        stderr=subprocess.STDOUT,
        text=True,
        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
    )
    return GodotProcess(
        role=role,
        process=process,
        started_at=time.monotonic(),
        output_path=output_path,
        trace_path=trace_path,
        pid_path=pid_path,
        output_stream=output_stream,
    )


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return ""


def _wait_for_host(peer: GodotProcess) -> bool:
    deadline = min(
        peer.started_at + PROCESS_TIMEOUT_SECONDS,
        time.monotonic() + HOST_READY_TIMEOUT_SECONDS,
    )
    while time.monotonic() < deadline:
        if "PEER_READY" in _read(peer.trace_path):
            return True
        if peer.process.poll() is not None:
            return False
        time.sleep(0.05)
    return False


def _wait_for_peers(peers: list[GodotProcess]) -> None:
    while True:
        running = [peer for peer in peers if peer.process.poll() is None]
        if not running:
            return
        now = time.monotonic()
        expired = [
            peer for peer in running
            if now - peer.started_at >= PROCESS_TIMEOUT_SECONDS
        ]
        if expired:
            roles = ", ".join(peer.role for peer in expired)
            raise TimeoutError(f"Godot peer timeout: {roles}")
        time.sleep(0.05)


def _stop_exact_process(peer: GodotProcess) -> None:
    if os.name == "nt" and peer.pid_path.is_file():
        try:
            godot_pid = int(_read(peer.pid_path).strip())
        except ValueError:
            godot_pid = 0
        if godot_pid > 0:
            import ctypes

            process_terminate = 0x0001
            synchronize = 0x00100000
            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
            kernel32.OpenProcess.restype = ctypes.c_void_p
            kernel32.TerminateProcess.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
            kernel32.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
            kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
            handle = kernel32.OpenProcess(
                process_terminate | synchronize, False, godot_pid
            )
            if handle:
                kernel32.TerminateProcess(handle, 1)
                kernel32.WaitForSingleObject(handle, 1000)
                kernel32.CloseHandle(handle)
    if peer.process.poll() is not None:
        return
    peer.process.terminate()
    try:
        peer.process.wait(timeout=1.0)
    except subprocess.TimeoutExpired:
        peer.process.kill()
        peer.process.wait(timeout=1.0)


def _diagnostics(peers: list[GodotProcess]) -> str:
    sections: list[str] = []
    for peer in peers:
        sections.append(
            f"--- {peer.role} trace ---\n{_read(peer.trace_path)}\n"
            f"--- {peer.role} output ---\n{_read(peer.output_path)}"
        )
    return "\n".join(sections)


def _parse_metrics(host_trace: str) -> dict[str, object]:
    prefix = "RESULT_JSON "
    for line in host_trace.splitlines():
        if line.startswith(prefix):
            return json.loads(line.removeprefix(prefix))
    return {}


def _run_network_case(
    bottom_role: str,
    latency_ms: int,
    scenario: str,
    tmp_path: Path,
) -> dict[str, object]:
    godot_binary = _find_godot_binary()
    port = _reserve_udp_port_pair()
    peers: list[GodotProcess] = []
    try:
        host = _launch_peer(
            godot_binary,
            "host",
            bottom_role,
            latency_ms,
            scenario,
            port,
            tmp_path / "host.log",
            tmp_path / "host.trace",
        )
        peers.append(host)
        if not _wait_for_host(host):
            pytest.fail(
                "Host did not bind its loopback peer.\n" + _diagnostics(peers),
                pytrace=False,
            )

        client = _launch_peer(
            godot_binary,
            "client",
            bottom_role,
            latency_ms,
            scenario,
            port,
            tmp_path / "client.log",
            tmp_path / "client.trace",
        )
        peers.append(client)
        try:
            _wait_for_peers(peers)
        except TimeoutError as error:
            pytest.fail(f"{error}\n{_diagnostics(peers)}", pytrace=False)

        failures = [
            f"{peer.role} exited with {peer.process.returncode}"
            for peer in peers
            if peer.process.returncode != 0
        ]
        host_trace = _read(host.trace_path)
        client_trace = _read(client.trace_path)
        metrics = _parse_metrics(host_trace)
        if not metrics:
            failures.append("host did not report integration metrics")
        if "RESULT_ACK" not in client_trace:
            failures.append("client did not acknowledge the integration result")
        if failures:
            pytest.fail("; ".join(failures) + "\n" + _diagnostics(peers), pytrace=False)
        return metrics
    finally:
        for peer in peers:
            _stop_exact_process(peer)
            if peer.output_stream is not None:
                peer.output_stream.close()


def test_zero_latency_stationary_control_has_no_sag(tmp_path: Path) -> None:
    metrics = _run_network_case("client", 0, "stationary", tmp_path)

    assert metrics["sample_count"] > 0
    assert metrics["stack_geometry_frames"] > 0, metrics
    assert metrics["max_horizontal_error"] <= 2.0, metrics
    assert metrics["max_sag"] <= 2.0, metrics
    assert metrics["falling_frames"] == 0, metrics
    assert metrics["unsupported_frames"] == 0, metrics
    assert metrics["render_sample_count"] > metrics["sample_count"], metrics
    assert metrics["max_bottom_render_step"] <= 1.0, metrics
    assert metrics["max_top_render_step"] <= 1.0, metrics
    assert metrics["max_render_stack_gap_change"] <= 1.0, metrics
    assert metrics["max_render_backtrack"] <= 0.5, metrics


def test_high_latency_stationary_stack_has_no_sag(tmp_path: Path) -> None:
    metrics = _run_network_case("client", 50, "stationary", tmp_path)

    assert metrics["sample_count"] > 0
    assert metrics["stack_geometry_frames"] > 0, metrics
    assert metrics["max_horizontal_error"] <= 2.0, metrics
    assert metrics["max_sag"] <= 2.0, metrics
    assert metrics["falling_frames"] == 0, metrics
    assert metrics["unsupported_frames"] == 0, metrics
    assert metrics["render_sample_count"] > metrics["sample_count"], metrics
    assert metrics["max_bottom_render_step"] <= 1.0, metrics
    assert metrics["max_top_render_step"] <= 1.0, metrics
    assert metrics["max_render_stack_gap_change"] <= 1.0, metrics
    assert metrics["max_render_backtrack"] <= 0.5, metrics


@pytest.mark.parametrize("latency_ms", [0, 50, 200])
def test_rider_follows_bottom_jump_without_delay(
    latency_ms: int,
    tmp_path: Path,
) -> None:
    metrics = _run_network_case("client", latency_ms, "bottom_jump", tmp_path)

    assert metrics["jump_injected"] is True, metrics
    assert (
        abs(metrics["jump_start_position_y"] - metrics["jump_peak_position_y"])
        > 50.0
    ), metrics
    if latency_ms == 200:
        assert metrics["rollback_carrier_jump_frames"] > 0, metrics
        assert metrics["rollback_rider_motion_mismatch_frames"] == 0, metrics
        assert metrics["max_rollback_rider_motion_error"] <= 0.1, metrics
    assert metrics["stack_geometry_frames"] > 0, metrics
    assert metrics["max_horizontal_error"] <= 2.0, metrics
    assert metrics["max_sag"] <= 2.0, metrics
    assert metrics["falling_frames"] == 0, metrics
    assert metrics["render_sample_count"] > metrics["sample_count"], metrics
    assert metrics["max_bottom_render_step"] <= 10.0, metrics
    assert metrics["max_top_render_step"] <= 10.0, metrics
    assert metrics["max_render_stack_gap_change"] <= 2.0, metrics
    assert metrics["max_render_backtrack"] <= 1.5, metrics


def test_200ms_rollback_replays_carrier_velocity_for_rider(tmp_path: Path) -> None:
    # The bottom player is host-owned so the client-side rider must replay the
    # carrier's late jump input rather than observing its own authoritative input.
    metrics = _run_network_case("host", 200, "bottom_jump", tmp_path)

    assert metrics["jump_injected"] is False, metrics
    assert metrics["rollback_carrier_jump_frames"] > 0, metrics
    assert metrics["rollback_rider_motion_mismatch_frames"] == 0, metrics
    assert metrics["max_rollback_rider_motion_error"] <= 0.1, metrics
    assert metrics["max_sag"] <= 2.0, metrics
    assert metrics["falling_frames"] == 0, metrics


@pytest.mark.parametrize("latency_ms", [0, 50])
def test_player_rides_diagonal_platform_without_losing_velocity_or_contact(
    latency_ms: int,
    tmp_path: Path,
) -> None:
    metrics = _run_network_case("client", latency_ms, "platform_ride_up", tmp_path)

    assert metrics["sample_count"] > 0, metrics
    assert metrics["ride_detector_sample_count"] > 0, metrics
    assert (
        metrics["ride_platform_start_position_y"]
        - metrics["ride_platform_peak_position_y"]
        > 50.0
    ), metrics
    assert (
        metrics["ride_detector_connected_frames"]
        == metrics["ride_detector_sample_count"]
    ), metrics
    assert metrics["ride_detector_disconnected_frames"] == 0, metrics
    assert metrics["max_horizontal_error"] <= 2.0, metrics
    assert metrics["max_separation"] <= 0.5, metrics
    assert metrics["jump_animation_frames"] == 0, metrics
    assert metrics["falling_frames"] == 0, metrics


@pytest.mark.parametrize("latency_ms", [0, 50])
def test_descending_platform_does_not_leave_stacked_players_penetrating(
    latency_ms: int,
    tmp_path: Path,
) -> None:
    metrics = _run_network_case("client", latency_ms, "platform_crush", tmp_path)

    assert metrics["sample_count"] > 0, metrics
    assert metrics["render_sample_count"] > metrics["sample_count"], metrics
    assert metrics["platform_end_error"] <= 1.0, metrics
    assert metrics["collision_exception_frames"] == 0, metrics
    assert metrics["final_player_penetration"] <= 0.5, metrics
    assert metrics["final_platform_penetration"] <= 0.5, metrics
    assert metrics["max_player_penetration"] <= 2.0, metrics
    assert metrics["max_platform_penetration"] <= 2.0, metrics
    assert metrics["max_bottom_render_step"] <= 12.0, metrics
    assert metrics["max_top_render_step"] <= 12.0, metrics
    assert metrics["max_platform_render_step"] <= 3.0, metrics
    assert metrics["max_render_backtrack"] <= 2.0, metrics
