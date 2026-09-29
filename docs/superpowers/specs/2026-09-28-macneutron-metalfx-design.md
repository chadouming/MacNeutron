# MacNeutron — MetalFX Upscaling (A: Apple's temporal bridge) and Metal 4

- **Date:** 2026-09-28
- **Status:** Approved 2026-09-28; stopped at the feasibility gate (§9) the same day — see `docs/testing/acceptance-metalfx.md`. Not implemented.
- **Builds on:** `2026-09-27-macproton-runtime-design.md` (GPTK import, graphics backends, launcher) and `2026-09-27-macneutron-app-design.md` (per-game settings, Games window).
- **Scope:**
  - **In:** making Apple's DLSS→MetalFX bridge reachable in the runtime; per-game "MetalFX upscaling" and "Metal 4" settings with launch-option opt-outs; the prefix stubs they need; the Games window toggles; acceptance on SMITE 2.
  - **Out:** sub-project B, MacNeutron's own spatial MetalFX upscaler for every game (its own spike and spec); DLSS frame generation; changing a game's DLSS ratio from MacNeutron (the game's own DLSS setting chooses it); DXMT or DXVK vendor spoofing.

## 1. Goal

A Windows game running on D3DMetal can use Apple's MetalFX temporal upscaler through its own DLSS option, and MacNeutron controls per game whether that path and D3DMetal's Metal 4 backend are on, with no setup in the game beyond choosing DLSS.

**Done when** the acceptance run in §8 passes on SMITE 2.

### Decisions made during brainstorming

| Decision | Choice |
|---|---|
| Upscaling scope | Both a temporal path (this spec, A) and a spatial every-game upscaler (sub-project B, later); temporal first |
| Temporal mechanism | Apple's own `nvngx-on-metalfx` bridge: the only way a game hands motion vectors and depth to MetalFX |
| MetalFX default | On, opt out per game (games see Apple's NVAPI and can offer DLSS) |
| Metal 4 default | On, opt out per game (D3DMetal ignores it on D3D11 titles and older macOS) |
| Frame generation | Never enabled |
| Where it's controlled | MacNeutron's Games window, and `MACNEUTRON_NO_METALFX=1` / `MACNEUTRON_NO_METAL4=1` launch options |

## 2. Evidence (verified 2026-09-28)

1. The imported GPTK 4.0b2 payload (`<tool>/gptk/lib`) contains `wine/x86_64-windows/nvngx-on-metalfx.dll` (PE export name `nvngx.dll`) and `wine/x86_64-windows/nvapi64.dll` (export name `nvapi.dll`), with `wine/x86_64-unix/nvngx-on-metalfx.so` and `nvapi64.so` as symlinks to `../../external/libd3dshared.dylib`.
2. `GPTKImporter.applyOverlay` already copies all four into the runtime. So Apple's `nvapi64.dll` has replaced Wine's placeholder for every game today, while the MetalFX bridge sits under Apple's file name, which Wine's builtin loader doesn't match to `nvngx.dll`. No game can reach MetalFX now.
3. SMITE 2 ships Unreal Engine's DLSS plugin, NVIDIA Streamline (`sl.interposer.dll`, `sl.dlss_g.dll`, `sl.reflex.dll`, `nvngx_dlssg.dll`) and Intel XeSS.
4. Prior art: frankea/Whisky (GPL-3.0; facts only, no code taken) runs the same runtime. It found that:
   - the bridge must be installed under its export name `nvngx.dll` with an `nvngx.so` unix half beside it;
   - each prefix needs a `system32\nvngx.dll` entry, or `LoadLibrary("nvngx.dll")` fails with `ERROR_MOD_NOT_FOUND`;
   - `D3DM_ENABLE_METALFX=1` enables the path, and Streamline offers DLSS only when NVAPI reports an NVIDIA GPU;
   - `D3DM_MTL4=1` selects D3DMetal's Metal 4 backend, which applies only to D3D12 and only on macOS versions with Metal 4;
   - DLSS frame generation, enabled through `CX_ACTIVE_GRAPHICS_BACKEND`, failed MetalFX command buffers and hung WindowServer on macOS 27 with D3DMetal 4.0b2;
   - Whisky defaults both MetalFX and Metal 4 to on after measuring.
5. SMITE 2 kept the GPU 91–100% busy even at its login screen (2026-09-28 measurement), which is why rendering fewer pixels should help.

## 3. Runtime: making the bridge reachable

`GPTKImporter.installMetalFXBridge(layout:)`:
- copies `wine/x86_64-windows/nvngx-on-metalfx.dll` to `wine/x86_64-windows/nvngx.dll`;
- makes `wine/x86_64-unix/nvngx.so` a symlink to `../../external/libd3dshared.dylib`, like the other bridges.

It does nothing when the payload has no `nvngx-on-metalfx.dll`, and it's idempotent. It runs at the end of `applyOverlay` (GPTK import and every runtime install) and at every app start when GPTK is imported, so existing installs pick it up. `ToolLayout.metalFXBridgeInstalled` is true when both files exist.

Apple's `nvapi64` needs no install step (§2.2).

## 4. Per-game settings and the launch environment

`GameSettings` gains `metalFX: Bool?` and `metal4: Bool?` (nil = on). `environment` maps `metalFX == false` to `MACNEUTRON_NO_METALFX=1` and `metal4 == false` to `MACNEUTRON_NO_METAL4=1`. As today, settings sit underneath launch options, and launch options win.

`LaunchEnvironment.build`:

| Backend | MetalFX on | MetalFX off | Metal 4 on | Metal 4 off |
|---|---|---|---|---|
| D3DMetal | `D3DM_ENABLE_METALFX=1` | overrides add `nvapi64,nvngx=d` | `D3DM_MTL4=1` | not set |
| DXMT, DXVK | overrides add `nvapi64,nvngx=d` | same | not set | not set |

- Overrides go through `mergeOverrides`, so a user's own `WINEDLLOVERRIDES` entry for `nvapi64` or `nvngx` still wins.
- A variable the user already set (`D3DM_ENABLE_METALFX`, `D3DM_MTL4`) is never overwritten.
- `CX_ACTIVE_GRAPHICS_BACKEND` is never set, so DLSS frame generation stays unreachable.

## 5. Prefix stubs

When the launch environment has `D3DM_ENABLE_METALFX=1`, `PrefixManager.prepare` copies the runtime's `x86_64-windows/nvngx.dll` and `nvapi64.dll` into `drive_c/windows/system32/` if either is missing there. They're copied only when missing because `wineboot` writes its own for prefixes made later. When MetalFX is off, nothing is deleted: the `=d` override keeps both from loading.

## 6. Launcher and app

- **Launcher note:** with D3DMetal and MetalFX on but `metalFXBridgeInstalled` false, the launcher log says `note: this GPTK has no MetalFX bridge`, and the game runs as today.
- **Games window:** the settings row for a Windows game gains two toggles, "MetalFX upscaling" and "Metal 4". They are disabled, with the help text "Needs D3DMetal (import the Game Porting Toolkit)", when GPTK isn't imported or the game's graphics setting is DXMT or DXVK.
- **README:** the launch-option table gains the two `MACNEUTRON_NO_*` variables, and a short "Upscaling" section explains picking DLSS in the game.

## 7. Errors

| Condition | Behavior |
|---|---|
| No GPTK imported | No D3DMetal; toggles disabled; nothing installed |
| GPTK without `nvngx-on-metalfx.dll` | Bridge not installed; launcher note (§6); game runs as today |
| MetalFX off (setting or launch option) | `nvapi64,nvngx=d`; the game sees a plain Apple GPU |
| DXMT or DXVK backend | `nvapi64,nvngx=d` regardless of the setting |
| Copying a prefix stub fails | Launch fails with `could not install the MetalFX bridge: <file>: <reason>`, like other prefix-preparation errors |
| A game misbehaves with MetalFX or Metal 4 | The user turns that toggle off for the game |

## 8. Testing

- **Swift unit tests** (test-first):
  - `GameSettings.environment` for both new fields;
  - `LaunchEnvironment` per the §4 table: D3DMetal defaults, each opt-out, DXMT and DXVK, a user override winning, a user-set `D3DM_*` kept, `CX_ACTIVE_GRAPHICS_BACKEND` never set;
  - `installMetalFXBridge` installs both files, is idempotent, and is a no-op without `nvngx-on-metalfx.dll`;
  - `applyOverlay` includes it;
  - `PrefixManager` copies the two stubs only when MetalFX is on and only when they're missing;
  - the launcher note;
  - `metalFXBridgeInstalled`.
- **Acceptance on the maintainer's Mac,** recorded in `docs/testing/acceptance-metalfx.md`:
  1. SMITE 2 offers DLSS in its graphics settings, and DLSS Quality looks sharper than the current output.
  2. Metal display figures (FPS, GPU time, frame-interval steadiness) at the same in-game spot for: MetalFX off; MetalFX on with DLSS Quality; and each of those with Metal 4 off, to see what Metal 4 changes.
  3. With MetalFX off for SMITE 2, DLSS is gone from its settings.
  4. The Steam bridge still works, and Timberborn (native) is unaffected.

## 9. First plan task: feasibility gate

Before any Swift change, the bridge is wired by hand:
- `nvngx.dll` and `nvngx.so` go into the installed runtime as in §3;
- the stubs go into SMITE 2's prefix as in §5;
- SMITE 2's launch options become `/usr/bin/env MTL_HUD_ENABLED=1 D3DM_ENABLE_METALFX=1 D3DM_MTL4=1 %command%`, a Steam config change made only after the user says yes, with Steam closed and a backup.

The user then checks SMITE 2's graphics settings.

| Result | Decision |
|---|---|
| DLSS is offered and works | Continue |
| DLSS is offered but fails or crashes | Record the `+loaddll,+err` log, stop and report |
| DLSS isn't offered | Check with a game log whether `nvngx.dll` and `nvapi64.dll` load and whether the adapter reports NVIDIA; if Unreal's DLSS plugin wants NVIDIA's vendor ID and nothing in D3DMetal provides it, stop and report. The toggles aren't built on a guess |

## 10. Risks

- **Apple's NVAPI in every D3DMetal game (the default).** A game may take NVIDIA-only paths such as Reflex that D3DMetal answers poorly. Mitigation: the per-game opt-out; this is already the state today (§2.2).
- **Beta software.** D3DMetal 4.0b2 and macOS 27 are betas, so behaviour may change with a GPTK update. Acceptance item 2 is re-run after a GPTK update.
- **Frame generation.** Some games may still try to turn it on. Leaving `CX_ACTIVE_GRAPHICS_BACKEND` unset is what blocks it (Whisky's finding); if a game gets through anyway, MetalFX off is the fallback.
- **Sub-project B** remains the answer for games without DLSS, and for choosing the render scale in MacNeutron.
