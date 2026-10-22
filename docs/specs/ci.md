# Spec: Continuous integration

Status: implemented (Milestone 0)

**Checks run locally** (user, 2026-10-16): `tools/ci/local.sh` runs the license
gate, rig tests, Flutter format/analyze/tests and the host harness, plus the
Android APK and Kotlin tests when an Android SDK is installed. It must pass
before any push. GitHub is used to push commits only.

`.github/workflows/ci.yml` is kept for the cross-platform jobs this PC can't
run (arm64/armhf host, macOS host, iOS, Android emulator) but only runs on
manual dispatch (`gh workflow run CI`), and only when the user asks for it:
the repository is private and Actions minutes are limited (macOS bills 10×).

| Job | Runner | What it proves |
| --- | --- | --- |
| License gate | ubuntu-24.04 | every dependency documented and allowed; no banned project referenced (`tools/licenses/check_licenses.py`) |
| Host harness | ubuntu x86_64, ubuntu **arm64**, macOS arm64 | host builds; CTest passes (unit, golden, round trip, replay) |
| Host harness armhf | ubuntu + `gcc-arm-linux-gnueabihf` + qemu-user | host builds and passes for 32-bit ARM handheld firmwares |
| Rig scripts | ubuntu, Python 3.12 | `tools/rig` unit tests (dry-run, config, latency stats) |
| Flutter | ubuntu | format, analyze, widget + golden tests |
| Android build | ubuntu | debug APK builds (uploaded as an artifact) |
| Linux desktop build | ubuntu | GTK build of the app compiles (the handheld embedder replaces it in M1/M4) |
| iOS build | macOS | `flutter build ios --no-codesign` compiles |

Flutter is pinned (`FLUTTER_VERSION`) and bumped deliberately in its own PR.

## Not covered yet

- arm64 Flutter builds: the Linux handheld app is built with our own embedder
  (Milestone 1/4); its CI job is added with it.
- On-device tests: these run on the hardware rig, not CI (docs/specs/rig.md).
- Signing and store uploads: never in CI without the user's approval.
