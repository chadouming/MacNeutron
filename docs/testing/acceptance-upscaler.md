# MetalFX upscaler acceptance

Spec: `docs/superpowers/specs/2026-09-28-macneutron-metalfx-upscaler-design.md`.

## Pacing decision (plan task 1), 2026-09-28

`present_loop` 900 frames, vsync off, D3DMetal (GPTK 4.0b2), runtime-v4.7.3, M5 Pro, macOS 27.

| Case | No library | Overlay only | Both presented |
|---|---|---|---|
| 640x360 → 1280x720 (scale 1) | 5.136 ms | 4.830 ms | 4.874 ms |
| 1280x720 → 2560x1440 (scale 2) | 9.305 ms | 4.929 ms | 5.288 ms |

Decision: overlay only. It never stalled and stayed within 1 ms of no library (spec §9); the switch that also presented the game's own drawable was removed.

Found on the way: the overlay must copy the game layer's `displaySyncEnabled`. Without that, a game presenting without vsync (display sync off on its layer) was paced by the overlay's default display sync: 9.8 ms against 5.6 ms.

`make presenter-check`: 9/9 ok.
