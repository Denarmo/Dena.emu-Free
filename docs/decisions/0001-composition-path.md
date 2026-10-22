# 0001: Android composition path for the game screen

Status: accepted (provisional until measured on a phone with the probe)
Date: 2026-10-16
Spec: [latency-spike.md](../specs/latency-spike.md)

## Decision

The game screen uses the **SurfaceView** path (a hybrid-composition platform view whose
surface the native runner draws into). The **Texture** path (`SurfaceProducer`) stays in
the code as a fallback for cases that need Flutter to transform or overlay the image
itself.

## Evidence

CI, Android emulator (API 30, x86_64, software GPU), our latency test ROM, about 3–7 s
per path:

| Metric | SurfaceView | Texture |
| --- | --- | --- |
| Input → post, p50 / p95 | 10.6 / 18.1 ms | 14.5 / 18.6 ms |
| Frame interval p50 / p99 | 16.9 / 35.9 ms | 16.7 / 35.9 ms |
| Audio xruns | 0 | 0 |

Both paths are well inside the 50 ms budget up to the point where the frame is posted.
The emulator's software GPU makes frame pacing (p99) noisy for both, so it does not
separate them.

## Why SurfaceView

- After the post, a SurfaceView buffer goes straight to SurfaceFlinger. A texture
  frame has to wait for Flutter's next raster pass, which adds up to one vsync
  (≈16.7 ms) that the software metric cannot see. With a 50 ms budget, one vsync
  matters.
- The skin, pause menu and other UI are drawn by Flutter around or over the game
  view, which hybrid composition supports.

## Revisit when

- The photodiode probe gives real input-to-photon numbers on a phone (rig, Milestone 1
  gate): if Texture is within 5 ms of SurfaceView, prefer Texture for simpler
  composition.
- Shaders move to a GPU renderer (GLES/Vulkan with Swappy); the same surface choice
  applies, but it needs measuring again.
