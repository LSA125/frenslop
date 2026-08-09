Test suite
==========

pytest owns the complete suite. It first launches the deterministic Godot scene
regressions as isolated processes, then launches the paired host/client network
integration tests.

Install the Python dependency:

    python -m pip install -r requirements-dev.txt

Run both layers from the project root with the concrete Godot tools executable:

    $env:GODOT_BIN = 'C:\path\to\godot.windows.opt.tools.64.exe'
    .\tests\run_tests.ps1

Running `python -m pytest` also collects every test, while `run_tests.ps1`
explicitly stops before the network layer if a deterministic regression fails.

The deterministic layer currently includes:

- a legacy riding scene intended to cover stacked riding, diagonal carrier
  motion, replay, and jumping; and
- a carrier-velocity scene covering the two-pixel blocked-carrier emission
  rule and player push speed while the carrier is also touching the floor; and
- Rapier floor contact and cache restoration under manual rollback stepping.

The riding scene still calls the removed positional/dependency riding API and
must be ported before it represents the current velocity-based architecture.
Consequently, `run_tests.ps1` stops before the network layer when that legacy
scene fails. Run the network test file directly to validate current riding.

The network layer launches the real MainMenu scene and drives the production
MultiplayerManager host/join/start calls, Game scene transition, ENet transport,
netfox clock/rollback, and MultiplayerSpawner. The persistent E2E controller
only injects owned input and records rendered-state metrics after interpolation.
The upper player walks and jumps onto the lower player through normal gameplay;
the controller does not instantiate players or seed rollback history. The
network scenarios cover:

- `stationary`: a stack remains supported without sag or falling animation;
- `bottom_jump`: the rider inherits the bottom player's complete vertical jump;
- `platform_ride_up`: a rider remains grounded, horizontally aligned, and
  connected to a diagonally moving platform while simulated round-trip latency
  repeatedly changes between 20 and 100 ms;
- `platform_crush`: descending platform/player contacts do not leave illegal
  penetration.

Each scenario runs at zero and 50 ms simulated one-way latency. The current
velocity-based architecture has a known high-latency horizontal-alignment
defect in `bottom_jump`; the vertical jump and moving-platform checks are
separate assertions.

The bottom-jump suite additionally runs at 200 ms one-way latency and records
carrier/rider displacement on every replayed upward tick. The deterministic
carrier regression also covers the first upward-platform contact from the edge
of floor-snap range, verifies that the larger ride detector alone cannot cancel
downward velocity, and characterizes whether `force_update_transform()` changes
the physics-server transform after direct assignment versus `move_and_collide`.

Run only the network cases even if a deterministic test is red:

    python -m pytest tests/integration/test_network_rollback_riding.py -vv

To watch the same two-peer test in visible Godot windows, run one of:

    powershell -ExecutionPolicy Bypass -File .\tests\inspect_network_riding.ps1 `
        -Scenario stationary -BottomRole client -LatencyMs 50

    powershell -ExecutionPolicy Bypass -File .\tests\inspect_network_riding.ps1 `
        -Scenario bottom_jump -BottomRole client -LatencyMs 0

    powershell -ExecutionPolicy Bypass -File .\tests\inspect_network_riding.ps1 `
        -Scenario platform_ride_up -BottomRole client -LatencyMs 50

The visible run is bounded and closes both exact Godot processes automatically.
Its host trace prints a RESULT_JSON line containing maximum sag, separation,
horizontal error, falling frames, support/riding frames, and jump-injection state.
Both peer traces are JSONL and include per-tick node/physics positions, velocity,
animation, support, and each player's latest input/state ticks for diagnosis.

On Windows, every Godot process is launched through Start-Process with a hidden
window. The wrappers bind network tests to loopback, choose fresh UDP ports,
record one log per process, suppress native child crash dialogs, wait no longer
than ten seconds, and terminate only the exact PID they launched.
