"""Generic pad key names -> Android ``KEYCODE_*`` names.

The generic names are the cross-platform pad set used on the rig CLI
(``up down left right a b x y l1 r1 l2 r2 start select``).  This module maps
them to Android key names.  The evdev mapping is per platform and belongs to
the on-device helpers (Milestone 4); it does not live here.

``KEYMAP`` holds the bare Android key names exactly as written in
``docs/specs/rig.md`` (for example ``"up" -> "DPAD_UP"``).  ``adb shell input
keyevent`` accepts both the bare and the ``KEYCODE_``-prefixed form.
"""

from __future__ import annotations

KEYCODE_PREFIX = "KEYCODE_"

#: Generic pad key name -> Android key name (without the ``KEYCODE_`` prefix).
KEYMAP: dict[str, str] = {
    "up": "DPAD_UP",
    "down": "DPAD_DOWN",
    "left": "DPAD_LEFT",
    "right": "DPAD_RIGHT",
    "a": "BUTTON_A",
    "b": "BUTTON_B",
    "x": "BUTTON_X",
    "y": "BUTTON_Y",
    "l1": "BUTTON_L1",
    "r1": "BUTTON_R1",
    "l2": "BUTTON_L2",
    "r2": "BUTTON_R2",
    "start": "BUTTON_START",
    "select": "BUTTON_SELECT",
}

#: The generic key names, in a stable order (useful for CLI help and tests).
KEY_NAMES: tuple[str, ...] = tuple(KEYMAP)


class UnknownKeyError(KeyError):
    """Raised when a key name is not part of the generic pad set."""

    def __init__(self, name: str) -> None:
        super().__init__(name)
        self.name = name

    def __str__(self) -> str:  # pragma: no cover - trivial
        return f"unknown key {self.name!r} (known: {', '.join(KEY_NAMES)})"


def android_keycode(name: str) -> str:
    """Return the bare Android key name for a generic pad key.

    >>> android_keycode("a")
    'BUTTON_A'
    """
    try:
        return KEYMAP[name.strip().lower()]
    except KeyError:
        raise UnknownKeyError(name) from None


def android_keycode_full(name: str) -> str:
    """Return the fully qualified Android keycode, e.g. ``KEYCODE_DPAD_UP``."""
    return KEYCODE_PREFIX + android_keycode(name)
