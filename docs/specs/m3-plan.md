# Milestone 3 plan: Android parity

Status: packages 1-10 on main (2026-10-16). Open: on-device checks (no rig
yet) and the Play release checkpoint. PICO-8 runs on fake-08 (MIT, license-checked).
Goal (CLAUDE.md §6): N64, DS, PSX, PSP and the PICO-8 runtime on Android, plus rewind,
home-screen shortcuts, external display and foldable layouts.
Checkpoint: Play release (the upload, signing and store listing need the user's account).

## Work packages (one spec each, in this order)

| # | Package | Spec | Depends on |
| --- | --- | --- | --- |
| 1 | Rewind: ring buffer of compressed states in the host, hold-to-rewind in the pause menu and on a skin button | rewind.md | — |
| 2 | DS: melonDS core, dual-screen layout, touch to the bottom screen, right-stick pointer with a gamepad | ds.md | — |
| 3 | PSX: PCSX ReARMed core (HLE BIOS, optional real BIOS), `.cue`/`.chd`/`.m3u` import, multi-disc swap | psx.md | — |
| 4 | Hardware rendering: libretro `RETRO_HW_CONTEXT_OPENGLES3` in the Android runner (shared EGL context, FBO into the SurfaceView) | hw-render.md | — |
| 5 | N64: Mupen64Plus-Next (GLES3 renderer), analog stick on skins and gamepads | n64.md | 4 |
| 6 | PSP: PPSSPP libretro core (GLES3), `.iso`/`.cso` import | psp.md | 4 |
| 7 | Shortcuts and deep links: pinned game shortcuts, `dena://play/<sha1>`, App Search hooks | shortcuts.md | — |
| 8 | External display: `Presentation` on HDMI/USB-C with the controller skin on the phone | external-display.md | — |
| 9 | Adaptive layouts: NavigationRail on tablets/foldables, posture-aware game screen | adaptive.md | — |
| 10 | PICO-8: clean-room runtime (Lua subset, 128×128 PPU, SFX/music), `.p8`/`.p8.png` import; browser stays behind its flag | pico8.md | — |

Packages 1, 7, 8 and 9 are small and independent. 2 and 3 use software rendering and
need no runner changes beyond multi-screen and disc handling. 5 and 6 wait for 4.

## Defaults chosen (tell the user; easy to change)

- **Order:** software-rendered systems (DS, PSX) before the GPU ones (N64, PSP), so
  most of the milestone works before the riskiest runner change lands.
- **PSX core:** PCSX ReARMed only for now. Its HLE BIOS means no BIOS file is needed;
  a user-supplied BIOS improves compatibility. Beetle PSX HW (strong phones) comes later.
- **DS BIOS:** melonDS's built-in open replacement BIOS/firmware, so no files needed.
- **Test content:** only ROMs/executables we generate ourselves or clearly
  public-domain homebrew, with golden-frame and round-trip tests as in M2.
- **PICO-8 browser:** stays behind its feature flag until Lexaloffle gives permission.
- **Verification:** `tools/ci/local.sh` on this PC before every push; GitHub Actions
  only on the user's request.
