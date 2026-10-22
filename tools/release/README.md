# tools/release

Scripts that turn a checked-out commit into the files of a GitHub release.
They run on DENA-PC (never in GitHub Actions); the thread that drafts the
release uploads their output and the owner clicks Publish.

| Platform | Entry point | Output | Docs |
| --- | --- | --- | --- |
| Windows x64 | `build-windows.ps1` (PowerShell, from a Windows checkout) | `dena-emu-X.Y.Z-windows-x64-portable.zip`, `dena-emu-X.Y.Z-windows-x64-setup.exe`, `release-notes-windows.md` | [docs/dev/release-windows.md](../../docs/dev/release-windows.md) |
| SteamOS / Linux x86_64 | see [README-linux.md](README-linux.md) | Flatpak bundle and portable tar.gz | written by the SteamOS packaging thread |

`X.Y.Z` is always the `version:` line of `app/pubspec.yaml` without the build
number. Everything lands in `build/release/` (git-ignored).

`test_build_windows.py` checks the Windows packaging with a dry run
(`tools/ci/local.sh rig`).
