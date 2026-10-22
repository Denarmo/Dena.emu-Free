#!/usr/bin/env python3
"""Dena.emu hardware rig CLI (Milestone 0).

Deploy builds to real devices, inject input, capture the screen and logs, and
read input-to-photon latency -- without physical interaction.  See
``docs/specs/rig.md`` for the behaviour this implements.

Design
------
Command builders are *pure functions*: they take a :class:`Device` (and plain
data) and return a list of :class:`Step` objects, each holding an argument
list.  They never touch the filesystem or the network, which is what makes
``--dry-run`` and the unit tests possible.

:func:`main` is the small runner: with ``--dry-run`` it prints the steps with
``shlex.join``; otherwise it executes them with :mod:`subprocess`.

Exit codes
----------
0  success
1  latency gate failed (``median_ms >= 50``)
2  usage / configuration / missing tool on PATH / wrong device class
3  device unreachable or an on-device helper is missing
"""

from __future__ import annotations

import argparse
import json
import os
import random
import shlex
import shutil
import subprocess
import sys
import time
import tomllib
from dataclasses import dataclass, field
from math import ceil, floor
from pathlib import Path

# Allow ``python tools/rig/rig.py`` and ``import rig`` from the test file.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import keymap  # noqa: E402  (local module living next to this file)

EXIT_OK = 0
EXIT_GATE = 1
EXIT_USAGE = 2
EXIT_DEVICE = 3

RIG_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = RIG_DIR / "devices.toml"
DEFAULT_PACKAGE = "app.dena.emu"
DEFAULT_TAG = "Dena"
DEFAULT_DEPLOY_DIR = "/mnt/SDCARD/Dena"
DEFAULT_SSH_PORT = 22

#: Milestone 1 gate: a median above this fails the latency command.
LATENCY_GATE_MS = 50.0
#: How long a single probe sample may take before it counts as a timeout.
LATENCY_TIMEOUT_MS = 500
#: Remote path used to pull a handheld screenshot back over scp.
REMOTE_CAPTURE_TMP = "/tmp/rig-capture.png"
#: Delay range between latency samples, in milliseconds.
LATENCY_SAMPLE_WAIT_MS = (100, 300)

HELPER_INJECT = "rig-inject"
HELPER_CAPTURE = "rig-capture"


class RigError(Exception):
    """An error that maps directly to one of the documented exit codes."""

    def __init__(self, message: str, code: int = EXIT_USAGE) -> None:
        super().__init__(message)
        self.message = message
        self.code = code


# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class Device:
    """One entry from ``[devices.<name>]``."""

    name: str
    cls: str  # "android" | "handheld"
    serial: str | None = None
    host: str | None = None
    user: str | None = None
    port: int = DEFAULT_SSH_PORT
    input_device: str | None = None
    platform: str | None = None
    deploy_dir: str = DEFAULT_DEPLOY_DIR

    @property
    def is_android(self) -> bool:
        return self.cls == "android"

    @property
    def is_handheld(self) -> bool:
        return self.cls == "handheld"

    @property
    def ssh_target(self) -> str:
        if not self.host:
            raise RigError(f"device {self.name!r} has no host", EXIT_USAGE)
        return f"{self.user}@{self.host}" if self.user else self.host

    @property
    def helper_dir(self) -> str:
        return self.deploy_dir.rstrip("/") or "/"


@dataclass
class Config:
    """Parsed ``devices.toml``."""

    devices: dict[str, Device] = field(default_factory=dict)
    latency_port: str | None = None
    latency_baud: int = 115200

    def get_device(self, name: str | None) -> Device:
        if not name:
            raise RigError("--device is required for this command", EXIT_USAGE)
        try:
            return self.devices[name]
        except KeyError:
            known = ", ".join(sorted(self.devices)) or "(none configured)"
            raise RigError(
                f"unknown device {name!r} (configured: {known})", EXIT_USAGE
            ) from None


def parse_device(name: str, raw: dict) -> Device:
    """Build a :class:`Device` from one TOML table, validating required keys."""
    cls = raw.get("class")
    if cls not in ("android", "handheld"):
        raise RigError(
            f"device {name!r}: class must be 'android' or 'handheld', got {cls!r}",
            EXIT_USAGE,
        )
    if cls == "android" and not raw.get("serial"):
        raise RigError(f"device {name!r}: android devices need a 'serial'", EXIT_USAGE)
    if cls == "handheld" and not raw.get("host"):
        raise RigError(f"device {name!r}: handheld devices need a 'host'", EXIT_USAGE)
    try:
        port = int(raw.get("port", DEFAULT_SSH_PORT))
    except (TypeError, ValueError):
        raise RigError(f"device {name!r}: 'port' must be an integer", EXIT_USAGE) from None
    return Device(
        name=name,
        cls=cls,
        serial=raw.get("serial"),
        host=raw.get("host"),
        user=raw.get("user"),
        port=port,
        input_device=raw.get("input_device"),
        platform=raw.get("platform"),
        deploy_dir=str(raw.get("deploy_dir", DEFAULT_DEPLOY_DIR)),
    )


def parse_config(data: dict) -> Config:
    """Turn a decoded TOML document into a :class:`Config` (pure)."""
    raw_devices = data.get("devices") or {}
    if not isinstance(raw_devices, dict):
        raise RigError("'devices' must be a table", EXIT_USAGE)
    devices = {name: parse_device(name, raw) for name, raw in raw_devices.items()}

    latency = data.get("latency") or {}
    latency_port = latency.get("port")
    try:
        latency_baud = int(latency.get("baud", 115200))
    except (TypeError, ValueError):
        raise RigError("latency.baud must be an integer", EXIT_USAGE) from None
    return Config(devices=devices, latency_port=latency_port, latency_baud=latency_baud)


def load_config(path: str | os.PathLike[str]) -> Config:
    """Read and parse a ``devices.toml`` file."""
    config_path = Path(path)
    if not config_path.is_file():
        raise RigError(
            f"config not found: {config_path} (copy devices.example.toml next to it)",
            EXIT_USAGE,
        )
    try:
        with config_path.open("rb") as handle:
            data = tomllib.load(handle)
    except tomllib.TOMLDecodeError as exc:
        raise RigError(f"invalid TOML in {config_path}: {exc}", EXIT_USAGE) from None
    return parse_config(data)


# --------------------------------------------------------------------------- #
# Command plans (pure builders)
# --------------------------------------------------------------------------- #


@dataclass
class Step:
    """One command to run, plus optional stdin/stdout wiring.

    ``args`` is an argument list, never a shell string, so the runner never
    needs ``shell=True``.  ``helper`` names the on-device helper a step uses;
    steps flagged ``preflight`` verify that helper exists and turn a non-zero
    exit into the documented "helper missing on device" error (exit 3).
    """

    args: list[str]
    stdin: str | None = None
    stdout_path: str | None = None
    helper: str | None = None
    preflight: bool = False
    sleep_ms: int = 0
    note: str | None = None


def adb_prefix(device: Device) -> list[str]:
    """``adb -s <serial>`` for an android device."""
    if not device.is_android or not device.serial:
        raise RigError(f"device {device.name!r} is not an android device", EXIT_USAGE)
    return ["adb", "-s", device.serial]


def ssh_prefix(device: Device) -> list[str]:
    """``ssh -p <port> <user>@<host>`` for a handheld device."""
    if not device.is_handheld:
        raise RigError(f"device {device.name!r} is not a handheld device", EXIT_USAGE)
    return ["ssh", "-p", str(device.port), device.ssh_target]


def scp_prefix(device: Device) -> list[str]:
    """``scp -P <port>`` for a handheld device (scp spells the port flag ``-P``)."""
    if not device.is_handheld:
        raise RigError(f"device {device.name!r} is not a handheld device", EXIT_USAGE)
    return ["scp", "-P", str(device.port)]


def helper_check(device: Device, helper: str) -> Step:
    """Preflight step: verify ``<deploy_dir>/<helper>`` exists and is executable."""
    path = f"{device.helper_dir}/{helper}"
    return Step(
        args=ssh_prefix(device) + ["test", "-x", path],
        helper=helper,
        preflight=True,
    )


def build_reachability(device: Device) -> list[Step]:
    """Steps that report whether a device is reachable."""
    if device.is_android:
        return [Step(args=adb_prefix(device) + ["get-state"], note=device.name)]
    return [Step(args=ssh_prefix(device) + ["true"], note=device.name)]


def build_deploy(device: Device, artifact: str, is_dir: bool = False) -> list[Step]:
    """``deploy <artifact>``.

    Android: ``adb install -r <apk>``.
    Handheld: ``scp`` the file/dir into ``deploy_dir``, then ``sync``.
    """
    if device.is_android:
        return [Step(args=adb_prefix(device) + ["install", "-r", artifact])]
    target = f"{device.ssh_target}:{device.helper_dir}/"
    copy = scp_prefix(device)
    if is_dir:
        copy.append("-r")
    copy += [artifact, target]
    return [
        Step(args=copy),
        Step(args=ssh_prefix(device) + ["sync"]),
    ]


def build_launch(device: Device, package: str = DEFAULT_PACKAGE) -> list[Step]:
    """``launch [--package PKG]``."""
    if device.is_android:
        return [Step(args=adb_prefix(device) + ["shell", "monkey", "-p", package, "1"])]
    return [Step(args=ssh_prefix(device) + [f"{device.helper_dir}/launch.sh"])]


def build_tap(device: Device, x: int, y: int) -> list[Step]:
    """``input tap X Y`` -- not supported on handhelds (exit 2)."""
    if device.is_android:
        return [
            Step(args=adb_prefix(device) + ["shell", "input", "tap", str(x), str(y)])
        ]
    raise RigError(
        f"input tap is not supported on handheld device {device.name!r}", EXIT_USAGE
    )


def _android_keycode(name: str) -> str:
    try:
        return keymap.android_keycode(name)
    except keymap.UnknownKeyError as exc:
        raise RigError(str(exc), EXIT_USAGE) from None


def build_key(device: Device, name: str) -> list[Step]:
    """``input key NAME``."""
    if device.is_android:
        code = _android_keycode(name)
        return [Step(args=adb_prefix(device) + ["shell", "input", "keyevent", code])]
    # Handheld: the generic name is mapped to evdev on the device.
    return [
        helper_check(device, HELPER_INJECT),
        Step(
            args=ssh_prefix(device)
            + [f"{device.helper_dir}/{HELPER_INJECT}", "key", name],
            helper=HELPER_INJECT,
        ),
    ]


def build_replay(device: Device, events: list[Event]) -> list[Step]:
    """``input replay FILE``.

    Android has no way to hold a key down through ``input keyevent``, so only
    ``down`` events are sent (each at its own timestamp); ``up`` events still
    advance the clock so the following events keep their timing.  Handhelds
    get the whole stream, timing included, on the helper's stdin.
    """
    if device.is_android:
        steps: list[Step] = []
        previous_ms = 0
        for event in events:
            delay = max(0, event.at_ms - previous_ms)
            previous_ms = event.at_ms
            if event.action != "down":
                continue
            steps.append(
                Step(
                    args=adb_prefix(device)
                    + ["shell", "input", "keyevent", _android_keycode(event.key)],
                    sleep_ms=delay,
                    note=f"t={event.at_ms}ms {event.key} {event.action}",
                )
            )
        return steps
    return [
        helper_check(device, HELPER_INJECT),
        Step(
            args=ssh_prefix(device)
            + [f"{device.helper_dir}/{HELPER_INJECT}", "replay"],
            stdin=serialize_replay(events),
            helper=HELPER_INJECT,
        ),
    ]


def build_capture(device: Device, out: str) -> list[Step]:
    """``capture OUT.png``."""
    if device.is_android:
        return [
            Step(
                args=adb_prefix(device) + ["exec-out", "screencap", "-p"],
                stdout_path=out,
            )
        ]
    return [
        helper_check(device, HELPER_CAPTURE),
        Step(
            args=ssh_prefix(device)
            + [f"{device.helper_dir}/{HELPER_CAPTURE}", REMOTE_CAPTURE_TMP],
            helper=HELPER_CAPTURE,
        ),
        Step(
            args=scp_prefix(device)
            + [f"{device.ssh_target}:{REMOTE_CAPTURE_TMP}", out]
        ),
    ]


def build_logs(device: Device, follow: bool = False, tag: str = DEFAULT_TAG) -> list[Step]:
    """``logs [--follow] [--tag TAG]``."""
    if device.is_android:
        args = adb_prefix(device) + ["logcat", "-v", "time", "-s", tag]
        if not follow:
            args.append("-d")  # dump and exit
        return [Step(args=args)]
    log_path = f"{device.helper_dir}/logs/dena.log"
    if follow:
        return [Step(args=ssh_prefix(device) + ["tail", "-f", log_path])]
    return [Step(args=ssh_prefix(device) + ["tail", "-n", "200", log_path])]


# --------------------------------------------------------------------------- #
# Input replay format
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class Event:
    """One line of a replay file: milliseconds since start, key, down/up."""

    at_ms: int
    key: str
    action: str


def parse_replay(text: str) -> list[Event]:
    """Parse replay text: ``MS KEY down|up`` per line, ``#`` starts a comment."""
    events: list[Event] = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 3:
            raise RigError(
                f"replay line {lineno}: expected 'MS KEY down|up', got {raw.strip()!r}",
                EXIT_USAGE,
            )
        ms_text, key, action = parts
        try:
            at_ms = int(ms_text)
        except ValueError:
            raise RigError(
                f"replay line {lineno}: {ms_text!r} is not a whole number of milliseconds",
                EXIT_USAGE,
            ) from None
        if at_ms < 0:
            raise RigError(f"replay line {lineno}: timestamp must not be negative", EXIT_USAGE)
        key = key.lower()
        if key not in keymap.KEYMAP:
            raise RigError(
                f"replay line {lineno}: unknown key {key!r} "
                f"(known: {', '.join(keymap.KEY_NAMES)})",
                EXIT_USAGE,
            )
        if action not in ("down", "up"):
            raise RigError(
                f"replay line {lineno}: action must be 'down' or 'up', got {action!r}",
                EXIT_USAGE,
            )
        events.append(Event(at_ms=at_ms, key=key, action=action))
    return events


def serialize_replay(events: list[Event]) -> str:
    """Render events back to the replay format (comments stripped)."""
    body = "\n".join(f"{e.at_ms} {e.key} {e.action}" for e in events)
    return body + "\n" if body else ""


def read_replay_file(path: str) -> list[Event]:
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as exc:
        raise RigError(f"cannot read replay file {path!r}: {exc}", EXIT_USAGE) from None
    return parse_replay(text)


# --------------------------------------------------------------------------- #
# Latency statistics (pure) and the serial probe
# --------------------------------------------------------------------------- #


def percentile(sorted_values: list[float], pct: float) -> float:
    """Linear-interpolated percentile over an already-sorted list."""
    count = len(sorted_values)
    if count == 0:
        raise ValueError("percentile of empty sequence")
    if count == 1:
        return float(sorted_values[0])
    position = (count - 1) * pct / 100.0
    low, high = floor(position), ceil(position)
    if low == high:
        return float(sorted_values[int(position)])
    span = sorted_values[high] - sorted_values[low]
    return float(sorted_values[low] + span * (position - low))


def parse_latency_line(line: str | bytes) -> float | None:
    """Parse one probe reply.

    Returns the latency in milliseconds for ``L <microseconds>``, ``None`` for
    a ``T`` timeout, and raises :class:`ValueError` for anything else.
    """
    if isinstance(line, (bytes, bytearray)):
        line = bytes(line).decode("ascii", "replace")
    text = line.strip()
    if not text:
        raise ValueError("empty reply line")
    kind, _, rest = text.partition(" ")
    kind = kind.upper()
    if kind == "T":
        return None
    if kind == "L":
        try:
            return int(rest.strip()) / 1000.0
        except ValueError:
            raise ValueError(f"bad microsecond count in {text!r}") from None
    raise ValueError(f"unexpected reply {text!r}")


def latency_stats(reply_lines: list[str] | list[bytes]) -> dict:
    """Compute the JSON summary from a list of probe replies.

    Pure: any iterable of reply lines works, which is how the tests drive it
    with a fake stream.  Unparseable lines are ignored; they are not evidence
    either way.
    """
    samples: list[float] = []
    timeouts = 0
    for line in reply_lines:
        try:
            value = parse_latency_line(line)
        except ValueError:
            continue
        if value is None:
            timeouts += 1
        else:
            samples.append(value)

    stats: dict = {
        "samples": len(samples),
        "timeouts": timeouts,
        "min_ms": None,
        "median_ms": None,
        "p95_ms": None,
        "max_ms": None,
    }
    if samples:
        ordered = sorted(samples)
        stats["min_ms"] = round(ordered[0], 3)
        stats["median_ms"] = round(percentile(ordered, 50), 3)
        stats["p95_ms"] = round(percentile(ordered, 95), 3)
        stats["max_ms"] = round(ordered[-1], 3)
    return stats


def latency_gate(stats: dict, threshold_ms: float = LATENCY_GATE_MS) -> int:
    """Exit code for a latency summary: 1 when the median misses the gate."""
    median = stats.get("median_ms")
    if median is None:
        # Nothing measured: no evidence the gate is met.
        return EXIT_GATE
    return EXIT_GATE if median >= threshold_ms else EXIT_OK


def collect_latency_lines(
    write,
    readline,
    samples: int,
    rng=random,
    sleep=time.sleep,
    wait_ms: tuple[int, int] = LATENCY_SAMPLE_WAIT_MS,
) -> list[str]:
    """Drive the probe protocol, returning the raw reply lines.

    ``write`` is called with ``b"P\\n"`` and ``readline`` must return one reply
    line (str or bytes) per call.  Both are injected so tests can use a fake
    stream and no hardware.
    """
    replies: list[str] = []
    for index in range(samples):
        if index > 0:
            sleep(rng.uniform(wait_ms[0], wait_ms[1]) / 1000.0)
        write(b"P\n")
        reply = readline()
        if isinstance(reply, (bytes, bytearray)):
            reply = bytes(reply).decode("ascii", "replace")
        replies.append(reply)
    return replies


def latency_probe(config: Config, samples: int) -> dict:
    """Open the serial port and measure ``samples`` input-to-photon latencies."""
    try:
        import serial  # optional dependency, imported lazily
    except ImportError:
        raise RigError(
            "pyserial is required for the latency command: pip install pyserial",
            EXIT_USAGE,
        ) from None
    if not config.latency_port:
        raise RigError("no [latency] port configured in devices.toml", EXIT_USAGE)

    timeout_s = LATENCY_TIMEOUT_MS / 1000.0 + 0.5
    try:
        port = serial.Serial(config.latency_port, config.latency_baud, timeout=timeout_s)
    except Exception as exc:  # serial.SerialException and friends
        raise RigError(
            f"cannot open {config.latency_port!r}: {exc}", EXIT_DEVICE
        ) from None

    def read_line() -> str:
        raw = port.readline()
        return raw.decode("ascii", "replace") if raw else "T"

    try:
        port.reset_input_buffer()
        replies = collect_latency_lines(port.write, read_line, samples)
    finally:
        port.close()
    return latency_stats(replies)


# --------------------------------------------------------------------------- #
# Printing and running
# --------------------------------------------------------------------------- #


def format_step(step: Step) -> str:
    """Render one step the way ``--dry-run`` prints it."""
    line = shlex.join(step.args)
    if step.stdout_path:
        line += " > " + shlex.quote(step.stdout_path)
    return line


def print_plan(steps: list[Step], out=None) -> int:
    """``--dry-run``: print the exact commands instead of running them."""
    stream = out if out is not None else sys.stdout
    for step in steps:
        if step.note:
            print(f"# {step.note}", file=stream)
        print(format_step(step), file=stream)
        if step.stdin is not None:
            for line in step.stdin.splitlines():
                print(f"  | {line}", file=stream)
    return EXIT_OK


def run_step(step: Step, err=None) -> int:
    """Execute one step, mapping failures onto the documented exit codes."""
    stream = err if err is not None else sys.stderr
    if step.sleep_ms > 0:
        time.sleep(step.sleep_ms / 1000.0)

    tool = step.args[0]
    if shutil.which(tool) is None:
        print(f"rig: required tool {tool!r} not found on PATH", file=stream)
        return EXIT_USAGE

    try:
        completed = subprocess.run(
            step.args,
            input=step.stdin.encode("utf-8") if step.stdin is not None else None,
            stdout=subprocess.PIPE if step.stdout_path else None,
        )
    except OSError as exc:
        print(f"rig: cannot run {tool!r}: {exc}", file=stream)
        return EXIT_USAGE

    if step.stdout_path and completed.stdout is not None:
        try:
            Path(step.stdout_path).write_bytes(completed.stdout)
        except OSError as exc:
            print(f"rig: cannot write {step.stdout_path!r}: {exc}", file=stream)
            return EXIT_USAGE

    if completed.returncode != 0:
        if step.preflight:
            print(
                f"rig: helper missing on device: {step.helper} "
                f"(built in Milestone 4; see docs/specs/rig.md)",
                file=stream,
            )
            return EXIT_DEVICE
        return completed.returncode if completed.returncode > 0 else EXIT_DEVICE
    return EXIT_OK


def run_plan(steps: list[Step], err=None) -> int:
    """Run steps in order, stopping at the first failure."""
    for step in steps:
        code = run_step(step, err)
        if code != EXIT_OK:
            return code
    return EXIT_OK


def device_reachable(device: Device) -> bool:
    """Probe one device; missing tools and failures both mean "no"."""
    step = build_reachability(device)[0]
    if shutil.which(step.args[0]) is None:
        return False
    try:
        completed = subprocess.run(step.args, capture_output=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return False
    if completed.returncode != 0:
        return False
    if device.is_android:
        return completed.stdout.decode("utf-8", "replace").strip() == "device"
    return True


def require_reachable(device: Device, err=None) -> int:
    """Return 0 when reachable, 2 when the tool is missing, 3 when unreachable."""
    stream = err if err is not None else sys.stderr
    tool = "adb" if device.is_android else "ssh"
    if shutil.which(tool) is None:
        print(f"rig: required tool {tool!r} not found on PATH", file=stream)
        return EXIT_USAGE
    if not device_reachable(device):
        print(f"rig: device {device.name!r} unreachable", file=stream)
        return EXIT_DEVICE
    return EXIT_OK


# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #


def cmd_list(args, config: Config, out=None) -> int:
    """``list``: configured devices and whether each is reachable."""
    stream = out if out is not None else sys.stdout
    steps: list[Step] = []
    for device in config.devices.values():
        steps.extend(build_reachability(device))
    if args.dry_run:
        return print_plan(steps, stream)

    for device in config.devices.values():
        tool = "adb" if device.is_android else "ssh"
        if shutil.which(tool) is None:
            print(f"rig: required tool {tool!r} not found on PATH", file=sys.stderr)
            return EXIT_USAGE

    for device in config.devices.values():
        state = "reachable" if device_reachable(device) else "unreachable"
        target = device.serial if device.is_android else device.ssh_target
        print(f"{device.name}\t{device.cls}\t{target}\t{state}", file=stream)
    return EXIT_OK


def cmd_latency(args, config: Config, out=None) -> int:
    """``latency [--samples N]``: JSON summary, exit 1 when the gate fails."""
    stream = out if out is not None else sys.stdout
    samples = args.samples
    if samples < 1:
        print("rig: --samples must be at least 1", file=sys.stderr)
        return EXIT_USAGE

    if args.dry_run:
        print(
            f"# latency probe {config.latency_port} @ {config.latency_baud} "
            f"({samples} samples)",
            file=stream,
        )
        print("P", file=stream)
        return EXIT_OK

    try:
        stats = latency_probe(config, samples)
    except RigError as exc:
        print(f"rig: {exc.message}", file=sys.stderr)
        return exc.code
    print(json.dumps(stats), file=stream)
    return latency_gate(stats)


def build_steps(args, device: Device) -> list[Step]:
    """Dispatch a parsed CLI invocation to the matching pure builder."""
    if args.command == "deploy":
        return build_deploy(device, args.artifact, is_dir=os.path.isdir(args.artifact))
    if args.command == "launch":
        return build_launch(device, args.package)
    if args.command == "input":
        if args.input_command == "tap":
            return build_tap(device, args.x, args.y)
        if args.input_command == "key":
            return build_key(device, args.name)
        if args.input_command == "replay":
            return build_replay(device, read_replay_file(args.file))
        raise RigError(f"unknown input command {args.input_command!r}", EXIT_USAGE)
    if args.command == "capture":
        return build_capture(device, args.out)
    if args.command == "logs":
        return build_logs(device, follow=args.follow, tag=args.tag)
    raise RigError(f"unknown command {args.command!r}", EXIT_USAGE)


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #


def _common_options() -> argparse.ArgumentParser:
    # default=SUPPRESS keeps values given before the subcommand from being
    # clobbered by the subparser's own defaults: for these options the parser
    # must never invent a value, so the code normalises missing attributes.
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--device", default=argparse.SUPPRESS, help="device name from devices.toml"
    )
    common.add_argument(
        "--dry-run",
        action="store_true",
        default=argparse.SUPPRESS,
        help="print the exact commands instead of running them",
    )
    common.add_argument(
        "--config",
        default=argparse.SUPPRESS,
        help=f"path to devices.toml (default: {DEFAULT_CONFIG})",
    )
    return common


def build_parser() -> argparse.ArgumentParser:
    common = _common_options()
    parser = argparse.ArgumentParser(
        prog="rig.py",
        parents=[common],
        description="Dena.emu hardware rig (see docs/specs/rig.md)",
    )
    sub = parser.add_subparsers(dest="command", metavar="<command>")

    sub.add_parser("list", parents=[common], help="list configured devices")

    p_deploy = sub.add_parser("deploy", parents=[common], help="install/scp an artifact")
    p_deploy.add_argument("artifact", help="APK (android) or file/dir (handheld)")

    p_launch = sub.add_parser("launch", parents=[common], help="start the app")
    p_launch.add_argument("--package", default=DEFAULT_PACKAGE, help="Android package")

    p_input = sub.add_parser("input", parents=[common], help="inject input")
    input_sub = p_input.add_subparsers(dest="input_command", metavar="tap|key|replay")
    p_tap = input_sub.add_parser("tap", parents=[common], help="tap a screen position")
    p_tap.add_argument("x", type=int)
    p_tap.add_argument("y", type=int)
    p_key = input_sub.add_parser("key", parents=[common], help="press a pad key")
    p_key.add_argument("name", help=f"one of: {', '.join(keymap.KEY_NAMES)}")
    p_replay = input_sub.add_parser("replay", parents=[common], help="replay an event file")
    p_replay.add_argument("file", help="replay file: 'MS KEY down|up' per line")

    p_capture = sub.add_parser("capture", parents=[common], help="grab a screenshot")
    p_capture.add_argument("out", help="output PNG path")

    p_logs = sub.add_parser("logs", parents=[common], help="stream device logs")
    p_logs.add_argument("--follow", action="store_true", help="keep streaming")
    p_logs.add_argument("--tag", default=DEFAULT_TAG, help="Android logcat tag")

    p_latency = sub.add_parser("latency", parents=[common], help="measure input latency")
    p_latency.add_argument("--samples", type=int, default=50, help="samples to take")

    return parser


def main(argv: list[str] | None = None) -> int:
    """Entry point; returns the process exit code."""
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:  # argparse errors are already printed
        return int(exc.code) if isinstance(exc.code, int) else EXIT_USAGE

    # Subparsers parse into a fresh namespace (Python 3.12), so options that
    # were not supplied anywhere are simply absent.  Normalise them here.
    if not hasattr(args, "command"):
        args.command = None
    if not hasattr(args, "device"):
        args.device = None
    if not hasattr(args, "dry_run"):
        args.dry_run = False
    if not hasattr(args, "config"):
        args.config = str(DEFAULT_CONFIG)

    if not args.command:
        parser.print_usage(sys.stderr)
        print("rig: a command is required", file=sys.stderr)
        return EXIT_USAGE

    try:
        config = load_config(args.config)

        if args.command == "list":
            return cmd_list(args, config)
        if args.command == "latency":
            return cmd_latency(args, config)

        device = config.get_device(args.device)
        if args.command == "input" and not getattr(args, "input_command", None):
            print("rig: input needs a subcommand (tap, key, replay)", file=sys.stderr)
            return EXIT_USAGE

        if not args.dry_run:
            code = require_reachable(device)
            if code != EXIT_OK:
                return code

        steps = build_steps(args, device)
        if args.dry_run:
            return print_plan(steps)
        return run_plan(steps)
    except RigError as exc:
        print(f"rig: {exc.message}", file=sys.stderr)
        return exc.code


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
