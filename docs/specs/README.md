# Specs

Every feature gets a spec here before code (CLAUDE.md §7). A spec covers
behaviour, inputs, edge cases and acceptance tests. Status is one of
`draft`, `accepted`, `implemented`.

| Spec | Milestone | Status |
| --- | --- | --- |
| [test-harness.md](test-harness.md) | 0 | implemented |
| [ui-test-harness.md](ui-test-harness.md) | 0 | implemented |
| [rig.md](rig.md) | 0 | implemented (handheld helpers in M4) |
| [ci.md](ci.md) | 0 | implemented |
| [latency-spike.md](latency-spike.md) | 1 | implemented on Android (gate on a phone and H700 waits for rig hardware) |
| [shaders.md](shaders.md) | 3 | implemented on Android (device check waits for rig hardware) |
| [pico8-cart-browser.md](pico8-cart-browser.md) | 3 | implemented behind a flag that stays off until Lexaloffle permits it |
| [theming.md](theming.md) | 2 | implemented |
| [single-card.md](single-card.md) | 4 | implemented for H700 (QEMU boot test; first boot on a device waits for rig hardware) |
| [link-cable.md](link-cable.md) | 3 | implemented (two-device check on real phones pending) |
| [romm.md](romm.md) | 3 | implemented |
| [desktop-shell.md](desktop-shell.md) | desktop | implemented in code (first run on DENA-PC in the combined desktop pass) |
| [desktop-library.md](desktop-library.md) | desktop | implemented in code (first run on DENA-PC in the combined desktop pass) |
| [run-ahead.md](run-ahead.md) | desktop | implemented in code (latency check on DENA-PC in the next desktop pass) |
| [deck-presets.md](deck-presets.md) | desktop | implemented in code (Steam Deck check in the next desktop pass) |
| [frame-generation.md](frame-generation.md) | desktop | experimental, implemented in code (tested on software GL only; GPU, latency and judder check on DENA-PC in the next desktop pass) |
| [dreamcast-saturn.md](dreamcast-saturn.md) | desktop | implemented in code (first boot on DENA-PC in the next desktop pass) |
| [gamecube-wii.md](gamecube-wii.md) | desktop | implemented in code (Dolphin first built and booted on DENA-PC in the next desktop pass) |
| [texture-packs.md](texture-packs.md) | desktop | implemented in code (PSP pack check on DENA-PC in the next desktop pass) |
| [ps2.md](ps2.md) | desktop | implemented in code (first MSVC build and boot on DENA-PC in the next desktop pass) |

Decisions: [docs/decisions](../decisions).
