# Spec: Hardware rig scripts

Status: draft (Milestone 0)

## Purpose

Let Claude (or a human) deploy builds to real devices, inject input, capture the screen and
logs, and read input-to-photon latency, without physical interaction. Physical work (flashing,
recovery, cabling, judging feel) stays a human checkpoint.

## Devices and transports

Devices are listed in `tools/rig/devices.toml` (copy from `devices.example.toml`; the real file
is git-ignored because it holds local addresses).

```toml
[devices.pixel]
class = "android"          # android | handheld
serial = "emulator-5554"   # adb serial (android only)

[devices.rg35xx]
class = "handheld"
host = "192.168.1.50"      # SSH host (handheld only)
user = "root"
port = 22
input_device = "/dev/input/event1"   # evdev node used for injection
platform = "h700"          # h700 | a133p | rk3566
deploy_dir = "/mnt/SDCARD/Dena"

[latency]
port = "COM5"              # serial port of the photodiode probe
baud = 115200
```

Android uses `adb`. Handhelds use `ssh`/`scp` (OpenSSH client). No passwords are stored;
key-based auth only.

## CLI

One entry point, Python 3.11+ (for `tomllib`), standard library only: `python tools/rig/rig.py <command> --device <name> ...`

| Command | Android | Handheld | Output |
| --- | --- | --- | --- |
| `list` | — | — | configured devices and whether each is reachable |
| `deploy <artifact>` | `adb install -r <apk>` | `scp` file/dir to `deploy_dir`, then `sync` | exit code |
| `launch` | `adb shell monkey -p <package> 1` (package from `--package`, default `app.dena.emu`) | `ssh` runs `<deploy_dir>/launch.sh` | exit code |
| `input tap X Y` | `adb shell input tap` | not supported (exit 2) | |
| `input key NAME` | `adb shell input keyevent` (mapped name) | evdev event via `rig-inject` helper on device | |
| `input replay FILE` | sequential key events with timing | streamed to `rig-inject` | |
| `capture OUT.png` | `adb exec-out screencap -p` | `ssh` runs `rig-capture` on device, file copied back | PNG file |
| `logs [--follow]` | `adb logcat -v time` filtered by `--tag` (default `Dena`) | `ssh` `tail` of `<deploy_dir>/logs/dena.log` | stdout |
| `latency [--samples N]` | see below | see below | JSON summary |

Key names are the generic pad set: `up down left right a b x y l1 r1 l2 r2 start select`.
The mapping to Android keycodes lives in `tools/rig/keymap.py`; mapping to evdev codes is per
platform and belongs to the device helpers (Milestone 4).

`rig-inject` and `rig-capture` are small on-device helpers built in Milestone 4. Until they
exist the handheld commands print a clear "helper missing on device" error and exit 3.

## Latency measurement

The probe is a photodiode on the screen plus a GPIO line that presses a button (or a
solenoid/relay on a physical button), driven by a microcontroller on a serial port. Protocol,
line-based ASCII at the configured baud:

- Host sends `P\n` → probe presses the button and starts a microsecond timer.
- Probe replies `L <microseconds>\n` when the photodiode crosses its threshold, or `T\n` on
  a 500 ms timeout.

The test scene on screen must flip from black to white on the button press. `rig.py latency`
takes `--samples` (default 50), waits a random 100–300 ms between samples, and prints JSON:
`{"samples": N, "timeouts": T, "min_ms", "median_ms", "p95_ms", "max_ms"}`. Exit code 1 if
`median_ms >= 50` (the Milestone 1 gate), so CI-style scripts can use it. Serial access uses
`pyserial` if installed; without it the command exits 2 with an install hint.

## Edge cases

- Unknown device name, or wrong class for a command → exit 2 with a message.
- `adb`/`ssh` missing from PATH → exit 2 naming the tool.
- Device unreachable → exit 3.
- All commands support `--dry-run`, which prints the exact commands instead of running them.
  Tests use this.

## Acceptance tests

`tools/rig/test_rig.py` (unittest, no devices needed):
- config parsing of `devices.example.toml`; unknown device fails with exit 2;
- `--dry-run` output for every command on an android and a handheld device;
- latency statistics from a fake serial stream (median, p95, timeouts, gate exit code).
