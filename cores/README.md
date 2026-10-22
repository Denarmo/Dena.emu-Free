# cores/

Build scripts (and later submodules) for libretro cores. Only cores licensed for
commercial use are allowed; see CLAUDE.md §3 for the list and the banned cores.
Each core gets a row in `docs/licenses.md` with its exact upstream commit before
its build script lands. Empty until Milestone 1 (mGBA).

Desktop builds (Windows `win64`, SteamOS/Linux `linux-x86_64`): run
`cores/build-desktop.sh <target>`; see [docs/dev/desktop-cores.md](../docs/dev/desktop-cores.md).
