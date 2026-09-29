# MacNeutron — MetalFX Upscaler

- **Date:** 2026-09-28
- **Status:** Draft for review
- **Builds on:** `2026-09-27-macproton-runtime-design.md` (launcher, tool folder), `2026-09-27-macneutron-app-design.md` (per-game settings, Games window), `2026-09-28-macneutron-steam-bridge-design.md` (tool-file install at app start).
- **Replaces:** the temporal DLSS→MetalFX path in `2026-09-28-macneutron-metalfx-design.md`, which stopped at its feasibility gate.
- **Scope:**
  - **In:** a presenter library that upscales a game's frames with MetalFX's spatial scaler whenever the game renders below the size it occupies on screen (including Retina density); a linear-filter fallback; launcher injection; a per-game opt-out; tool install; a real-Wine check; acceptance.
  - **Out:** a MacNeutron-controlled render scale (making games render smaller; needs our own Wine display driver and its own spike); temporal upscaling; frame generation; HDR/EDR layers.

## 1. Goal

When a game's image is smaller than the pixels its window covers, because the player picked a lower resolution or because Wine renders at half density on a Retina screen, MacNeutron upscales it with Apple's MetalFX instead of macOS's nearest-neighbour stretch. It's on by default and can be turned off per game.

**Done when** the acceptance run in §6 passes.

### Decisions made during brainstorming

| Decision | Choice |
|---|---|
| Upscaling approach | Apple's MetalFX spatial scaler; no NVIDIA or AMD interfaces |
| Where it runs | **A:** a library injected into the game's Wine processes that hooks macOS's Metal presentation, with **C** (linear filter) as fallback (rejected: B, building it into our own Wine display driver) |
| First version | Upscaler only; the render scale is a later project |
| Default | On; per-game opt-out |
| Retina | Output at the screen's real pixel density |

## 2. Evidence (spike, 2026-09-28; throwaway code, runtime-v4.7.3, GPTK 4.0b2, M5 Pro, macOS 27)

1. The runtime's Wine binaries are unsigned, so `DYLD_INSERT_LIBRARIES` is honoured. `/bin/sh` (the `proton` stub) strips `DYLD_*` variables, so MacNeutron's Swift launcher must set it on the Wine process itself. The launcher is arm64 and aborts on an x86_64-only inserted library, so the library must be universal (`x86_64 arm64`).
2. Creating Metal objects in every Wine process (at library load) broke `wineboot` (exit 53). Class-level method swaps at load, with Metal objects created only on a process's first `nextDrawable`, work.
3. D3DMetal presents through the Wine display driver's `CAMetalLayer`: `-[CAMetalLayer nextDrawable]` → `-[MTLCommandBuffer presentDrawable:]` (class `AGXG17XFamilyCommandBuffer`) → `-[CAMetalDrawable present]`. The layer is `MTLPixelFormatBGRA8Unorm`, `framebufferOnly` YES, `magnificationFilter` nearest.
4. With a swap chain smaller than its window (640×360 in 1280×720), D3DMetal sets `drawableSize` to the swap-chain size while the layer's bounds are the window, and Core Animation stretches it with the nearest filter.
5. Enlarging `drawableSize` behind D3DMetal's back doesn't work: D3DMetal then stretches its back buffer into the larger drawable itself, so the unscaled image is gone.
6. A full-size sublayer over the game's layer, filled by MetalFX from the game's drawable in the game's own command buffer, works: a saved frame showed the whole 640×360 image correctly upscaled to 1280×720.
7. MetalFX's spatial scaler runs in D3DMetal's x86_64 (Rosetta) process. Added GPU time, including two copies: 0.38 ms for 640×360→1280×720 and 0.85 ms for 1280×720→2560×1440.
8. Presenting both the game's drawable and the overlay's every frame slowed pacing (9.9 ms per frame against 6.1 ms).
9. The Wine display driver gives its Metal host layer `contentsScale` 1 unless Wine's Retina mode is on, so on a Retina screen games render at point size and are stretched 2× with the nearest filter.

## 3. The presenter library

`presenter/present.m` → `libmacneutron-present.dylib` (universal, Objective-C, ARC; frameworks Foundation, AppKit, QuartzCore, Metal, MetalFX), built by `make presenter` into `build/presenter/`.

**At load:** it swaps `-[CAMetalLayer nextDrawable]` at class level and does nothing else. It is a no-op in any process that never draws. (`setDrawableSize:` needs no hook: each decision reads `drawableSize` when a drawable is requested.)

**On a process's first `nextDrawable`:** it swaps `presentDrawable:` on that device's command-buffer class, once per process.

**Per layer, on each `nextDrawable`:**
- **Target size:** layer bounds × the backing scale of the layer's window. The layer's delegate is the display driver's `NSView`, so the view's `window.backingScaleFactor` is used; if that isn't available, `NSScreen.mainScreen.backingScaleFactor`.
- **Upscaling:** when the drawable is smaller than the target in both dimensions, the layer is marked for upscaling and gets `framebufferOnly = NO`, so MetalFX can read it.
- **Left alone:** HDR/EDR layers (`wantsExtendedDynamicRangeContent`, or a float or extended-range pixel format), with one log line.

**On `presentDrawable:` for a marked layer:**
1. **Overlay layer:** if the layer has none, create one on the main thread: an opaque `CAMetalLayer` with the same device and pixel format, `framebufferOnly = NO`, `frame = bounds`, `contentsScale = backing scale`, `drawableSize = target`, added as a sublayer with animations disabled. Present the game's drawable normally until it's attached.
2. **Keep it matched:** if the bounds or backing scale changed, update the overlay's frame and drawable size on the main thread.
3. **Upscale:** encode MetalFX's spatial scaler (perceptual colour processing) from the game's drawable into a private output texture, cached per size and format, then blit that into the overlay's `nextDrawable`, in the game's command buffer.
4. **Present:** present the overlay drawable. Whether the game's own drawable is also presented is settled by plan task 1 (§9).

**When upscaling stops:** if the drawable reaches the target size, or the layer is released, the overlay is removed and frames pass through.

**Fallback:** if `MTLFXSpatialScalerDescriptor supportsDevice:` is false, or creating the scaler for that format fails, the layer's `magnificationFilter` becomes linear and the layer is never upscaled again.

**Any other failure** (no overlay drawable, attaching fails) passes that frame through untouched and logs once per layer. The presenter never blanks a game.

**Log:** a line to stderr for each state change of a layer, which reaches the game log with `MACNEUTRON_LOG=1`, for example `macneutron-present: MetalFX 1280x720 -> 2560x1440` or `macneutron-present: linear filter (MetalFX can't scale pixel format 115)`.

**Test-only switches,** read only by the library and documented as such:
- `MACNEUTRON_PRESENT_DUMP=<path>` writes the 120th upscaled frame as a PPM;
- `MACNEUTRON_PRESENT_SCALE=<n>` overrides the backing scale, to simulate Retina.

## 4. MacNeutron integration

- **Tool folder:** `ToolLayout.presenterLibrary` = `<tool>/lib/libmacneutron-present.dylib`, and `presenterInstalled` says whether it exists.
- **Tool install:** `RuntimeInstaller.writeToolFiles` installs it with the same atomic, skip-if-identical rule as `steam.exe`, taking it from next to the launcher it was given or, for the app's `Contents/Helpers/macneutron`, from `Contents/Frameworks/`.
- **App bundle:** `make app` depends on `make presenter`, copies the library into `MacNeutron.app/Contents/Frameworks/`, and signs it.
- **Per-game setting:** `GameSettings.metalFX: Bool?` (nil = on); `false` maps to `MACNEUTRON_NO_METALFX=1`.
- **Launcher:** for `run` and `waitforexitandrun`, when `MACNEUTRON_NO_METALFX` isn't `1` and the library is installed, it adds the library to `DYLD_INSERT_LIBRARIES`, after any value the user set (colon-separated). When the library is missing it logs `note: MetalFX presenter not installed`.
- **Games window:** a "MetalFX upscaling" toggle (default on) with the help text "Upscales with Apple's MetalFX when the game renders below its window or the display's pixel density."
- **README:** a launch-option row for `MACNEUTRON_NO_METALFX=1` and an "Upscaling" section explaining that you lower the in-game resolution in windowed or borderless mode.

## 5. Errors

| Condition | Behavior |
|---|---|
| Library missing | Games start without it; launcher log `note: MetalFX presenter not installed` |
| Opt-out (setting or launch option) | Library not injected; behaviour as today |
| MetalFX unsupported, or a pixel format it can't scale | Linear filter instead of nearest; one game-log line |
| HDR/EDR layer | Left untouched; one game-log line |
| No window backing scale | Main screen's scale |
| Overlay can't be attached or has no drawable | That frame passes through; one game-log line per layer |

## 6. Testing

- **Swift unit tests** (test-first):
  - the launcher's `DYLD_INSERT_LIBRARIES`: set when installed and not opted out, appended to a user value, absent when opted out by setting or launch option, absent with a note when missing, and only for the two run verbs;
  - `GameSettings.metalFX` mapping;
  - `writeToolFiles` installing the library from next to the launcher and from `../Frameworks`, and working without it;
  - `presenterInstalled`.
- **`presenter/check.sh`** (`make presenter-check`, real Wine and D3DMetal, no Steam). The test program `presenter/tests/present_loop.c` draws a checkerboard, can resize its window mid-run, and prints its average frame time. Checks:
  1. **Pass-through:** a full-size swap chain gets no overlay and no MetalFX log line.
  2. **Upscale:** a 640×360 swap chain in a 1280×720 window logs `MetalFX 640x360 -> 1280x720`, and the dumped frame has the checkerboard's colours at eight sampled pixels.
  3. **Retina:** with `MACNEUTRON_PRESENT_SCALE=2` and a full-size swap chain, the log shows `MetalFX 1280x720 -> 2560x1440`.
  4. **Prefix setup:** creating a fresh prefix with the library injected succeeds.
  5. **Resize:** after a mid-run window resize the log shows the overlay at the new size.
  6. **Pacing:** the average frame time with upscaling is at most 1 ms above the same run without the library.
- **Acceptance on the maintainer's Mac,** recorded in `docs/testing/acceptance-upscaler.md`:
  1. **SMITE 2 at a lower resolution** in borderless or windowed mode: sharper than before; Metal display FPS and GPU time with MetalFX on and off.
  2. **A game on the built-in Retina display:** sharper with MetalFX on.
  3. **The per-game toggle off** restores today's look.
  4. **Regressions:** the Steam bridge still works, and Timberborn (native) is unaffected.

## 7. Build order

1. The presenter library and `check.sh`, including the §9 pacing decision.
2. Launcher injection, the setting and tool install.
3. App bundle, Games window toggle, README.
4. Acceptance.

## 8. Risks

- **D3DMetal internals:** a GPTK update could present differently (not through `presentDrawable:`). `check.sh` is re-run after any GPTK update, and pass-through keeps games working if the hooks never fire.
- **Anti-cheat:** injected libraries may be refused by anti-cheat that inspects the process. Mitigation: the per-game opt-out.
- **Extra GPU time:** about 0.4–0.9 ms per frame while upscaling. Mitigation: nothing when the game renders full size; opt-out.
- **The render scale** remains the way to get lower render resolution in games that offer no windowed resolution setting; that's a separate project.

## 9. First plan task: pacing decision

Plan task 1 builds the library with both present strategies, selected by a test-only switch, and measures them with `present_loop` at 640×360→1280×720 and 1280×720→2560×1440:

| Result | Decision |
|---|---|
| Presenting only the overlay finishes every run with no stall, and pacing is within 1 ms of no library | Ship "overlay only"; remove the switch |
| Overlay only stalls (runs don't finish, or frame time grows), and presenting both is within 1 ms | Ship "both"; remove the switch |
| Neither is within 1 ms, or overlay only stalls and both is too slow | Stop and report with the numbers |
