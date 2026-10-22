# os/

SD-card image builder and per-device boot hooks for Linux handhelds. Milestone 4.
Never redistribute vendor firmware; never copy MinUI or SpruceOS code.

- `build_sd.py`, `payload.py`, `scripts/`: the card layout, the app payload and
  the boot hook (two-card setup, docs/specs/sd-card.md).
- `image/`: the single-card image for the H700 handhelds, with its own U-Boot,
  kernel and system, so no stock firmware card is needed
  (docs/specs/single-card.md). `image/build.sh --test` on Linux or in Docker.
