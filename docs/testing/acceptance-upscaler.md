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

## Review fixes (after the final review), 2026-09-28

- Vsync-on games weren't upscaled, and switching vsync on mid-game froze the picture: D3DMetal presents with `presentDrawable:afterMinimumDuration:` when vsync is on. All three present selectors are now hooked.
- A game switching pixel formats got an overlay of the old format; the overlay is now rebuilt.
- `make presenter-check`: 12/12 ok (three checks added for these).

## Acceptance on the maintainer's Mac

Not run yet: merged at the maintainer's request before the SMITE 2, Retina-display and regression runs of plan task 4. To be recorded here when done.
