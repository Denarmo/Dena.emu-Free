# Hardware rig

Drive real devices from the command line: deploy builds, inject input, capture
the screen and logs, and measure input-to-photon latency. Spec:
[`docs/specs/rig.md`](../../docs/specs/rig.md).

## Setup

```sh
cp tools/rig/devices.example.toml tools/rig/devices.toml   # then edit it
```

`devices.toml` is git-ignored (it holds local addresses). Android uses `adb`,
handhelds use `ssh`/`scp` with key-based auth only — no passwords are stored.

## Usage

```sh
python tools/rig/rig.py list
python tools/rig/rig.py deploy build/app.apk   --device pixel
python tools/rig/rig.py launch                 --device pixel --package app.dena.emu
python tools/rig/rig.py input tap 540 960      --device pixel
python tools/rig/rig.py input key a            --device pixel
python tools/rig/rig.py input replay run.txt   --device pixel
python tools/rig/rig.py capture shot.png       --device pixel
python tools/rig/rig.py logs --follow --tag Dena --device pixel
python tools/rig/rig.py latency --samples 50
```

Add `--dry-run` to any command to print the exact commands it would run
without touching a device. `--config PATH` points at a different
`devices.toml`; it defaults to the one next to `rig.py`.

Key names are the generic pad set: `up down left right a b x y l1 r1 l2 r2
start select` (mapped to Android keycodes in `keymap.py`; handhelds map them to
evdev on the device in Milestone 4).

### Replay files

Plain text, one event per line, `#` starts a comment:

```
# a short combo
0   a down
120 a up
300 start down
360 start up
```

`MS` is milliseconds since the start of the replay. On Android each key-down
becomes an `input keyevent` at its timestamp (adb cannot hold a key down, so
key-up lines only advance the clock). On handhelds the whole stream, timing
included, is piped to `rig-inject` on the device.

### Latency

The probe is a photodiode plus a button driver on a serial port. The host sends
`P`, the probe answers `L <microseconds>` or `T` on timeout, and the command
prints `{"samples", "timeouts", "min_ms", "median_ms", "p95_ms", "max_ms"}`.
`--samples` defaults to 50 and the exit code is 1 when `median_ms >= 50` (the
Milestone 1 gate), so CI-style scripts can gate on it. Requires `pyserial`
(`pip install pyserial`); the import is lazy, so nothing else needs it.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | success |
| 1 | latency gate failed (`median_ms >= 50`) |
| 2 | usage/config error, wrong device class, or a tool missing from `PATH` |
| 3 | device unreachable, or an on-device helper (`rig-inject`/`rig-capture`) is missing |

`rig-inject` and `rig-capture` are on-device helpers built in Milestone 4; until
then the handheld `input key`, `input replay` and `capture` commands report
"helper missing on device" and exit 3.

## Tests

```sh
python -m unittest discover -s tools/rig -v
```

No devices, `adb`, `ssh` or serial port needed: the tests drive the pure
command builders, `--dry-run`, and a fake serial stream.
