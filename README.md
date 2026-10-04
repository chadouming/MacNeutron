# MacNeutron

Proton for macOS: Windows games from your Steam library, launched by the native macOS Steam
client and translated by Wine and DXMT (Apple's D3DMetal optional, per game).

**Status:** sub-project 1 (the runtime) is in progress. Design: `docs/superpowers/specs/`.

**Requirements:** Apple Silicon, macOS 26 or later, Rosetta 2, Xcode 27 (Swift 6).

## Build and test

```sh
make build   # swift build -c release
make test    # unit tests
make smoke   # real Wine
make dxmt         # our DXMT fork with Direct3D 12 into build/dxmt; first run ~500 MB of downloads and a 30-60 min LLVM build
make dxmt-check   # our DXMT under real Wine (needs GPTK imported)
make wine-arm64        # native arm64 Wine + FEX in a signed wine.app (needs the Developer ID setup in wine-arm64/README.md)
make wine-arm64-check  # its gates under real Wine
```

The arm64 runtime now runs Direct3D 10/11/12 through our DXMT built for arm64, ARM64EC programs natively and x64
ones under FEX (`docs/testing/acceptance-arm64-dxmt.md`).

`make dxmt` and `make app` need `brew install cmake ninja meson` and Xcode's Metal Toolchain
(`xcodebuild -downloadComponent MetalToolchain`). Windows-side binaries are built with Clang from the pinned llvm-mingw,
which the build fetches once (118 MB).

## The app

```sh
make app                    # build/MacNeutron.app, ad-hoc signed, with the CLI and steam.exe inside (needs brew install mingw-w64)
open build/MacNeutron.app
```

The first launch opens a setup window: install the runtime, optionally import Apple's Game
Porting Toolkit (drop its `.dmg`), then turn on Steam Play mode. After that, MacNeutron lives
in the menu bar. It keeps Steam's mappings current so your Mac games stay native, and its
Games window sets the graphics backend and options per game.

## Install the runtime from the command line

```sh
.build/release/macneutron install-runtime                  # downloads the pinned Wine runtime (461 MB)
.build/release/macneutron import-gptk "/Volumes/<GPTK>"    # optional: Apple's GPTK from developer.apple.com
.build/release/macneutron install-dxmt build/dxmt          # after make dxmt: our DXMT instead of the runtime's 0.80
```

MacNeutron never ships Apple's files; `import-gptk` copies D3DMetal from the GPTK you downloaded.

## Per-game options

Use the app's Games window, or Steam launch options:

Start launch options with `/usr/bin/env`. macOS Steam runs them without a shell, so the Linux-style
`VAR=value %command%` fails to launch.

| Launch options | Effect |
|---|---|
| `/usr/bin/env MACNEUTRON_GRAPHICS=d3dmetal\|dxmt\|dxvk %command%` | Pick the Direct3D backend (default `dxmt`; `dxvk` is unavailable while GPTK is imported and falls back to `d3dmetal`) |
| `/usr/bin/env MACNEUTRON_LOG=1 %command%` | Wine log in `~/Library/Logs/MacNeutron/steam-<appid>.log` |
| `/usr/bin/env MACNEUTRON_NO_AVX=1 %command%` | Don't advertise AVX through Rosetta |
| `/usr/bin/env MACNEUTRON_NO_MSYNC=1 %command%` | Turn off msync |
| `/usr/bin/env MACNEUTRON_NO_STEAM_BRIDGE=1 %command%` | Start the game without the Steam bridge (the game then can't reach Steam) |
| `/usr/bin/env MACNEUTRON_NO_METALFX=1 %command%` | Don't upscale with MetalFX (macOS then stretches smaller images with its nearest-neighbour filter) |
| `/usr/bin/env DXMT_D3D12_SM6=1 %command%` | On DXMT, report the Direct3D 12 features Shader Model 6 games check for (Unreal Engine 5 games need it) |
| `/usr/bin/env DXMT_D3D12_OVERLAP=1 %command%` | On DXMT, let a Direct3D 12 game's GPU passes overlap between barriers (experimental: not faster on Apple GPUs so far) |
| `/usr/bin/env MACNEUTRON_PRECACHE=0 %command%` | Don't record the game's pipelines or rebuild them after updates (shader pre-caching) |

## Graphics

Games use DXMT by default, an open-source Direct3D → Metal translator. MacNeutron builds it from its own fork,
[chadouming/dxmt](https://github.com/chadouming/dxmt), with Direct3D 12 enabled. DXMT is LGPL-2.1+: the licences ship
in `MacNeutron.app/Contents/Resources/DXMT`, and the fork commit is in the tool folder's `dxmt-version`. The fork's
changes are AI-assisted and never go to DXMT upstream, per its contribution policy.

DXMT's Direct3D 12 is early, but it translates Shader Model 6 (DXIL) shaders: SMITE 2 (Unreal Engine 5) plays on it.
Unreal Engine 5 games check for Shader Model 6 features before they start; launch them with
`/usr/bin/env DXMT_D3D12_SM6=1 %command%`. For a game that doesn't run on DXMT yet, import GPTK and set
**Graphics: D3DMetal** for it in the Games window (or use `/usr/bin/env MACNEUTRON_GRAPHICS=d3dmetal %command%`).

**Shader pre-caching**, as Steam does for Vulkan games. DXMT keeps every shader it translates in a cache, so a
Direct3D 12 game translates each shader once. MacNeutron also records every pipeline the game creates, in
`dxmt-pipelines` in the game's Steam compat folder (`~/Library/Application Support/Steam/steamapps/compatdata/<appid>`).
After an update of MacNeutron's DXMT or of macOS, the launcher rebuilds them before the game starts, and a
notification says so. Troubleshooting:

- `DXMT_SHADER_CACHE=0` turns the translation cache off, and `MACNEUTRON_PRECACHE=0` turns recording and rebuilding
  off.
- Deleting `$(getconf DARWIN_USER_CACHE_DIR)dxmt/<game exe>/shaders_*.db` clears the cache.
- Deleting the `dxmt-pipelines` folder clears the recordings.

**GPU work overlap** (experimental). By default DXMT runs a Direct3D 12 game's GPU passes in strict order. With
`/usr/bin/env DXMT_D3D12_OVERLAP=1 %command%` a pass waits only on the passes the game's barriers order before it.
In SMITE 2 on Apple GPUs this added more idle time between passes than it saved
(`docs/testing/acceptance-dxmt-gpu-overlap.md`). If a game flickers or shows corrupted surfaces with it, drop it: the
cause is DXMT's ordering, so please report it. `DXMT_D3D12_MERGE=0` likewise turns off DXMT's merging of render passes that Direct3D 12 command lists
split, and of a clear into the render pass after it. `DXMT_D3D12_COMPRESSION=0` turns off DXMT's lossless compression
of Direct3D 12 textures, if a game shows corrupted textures with it. `DXMT_D3D12_INDIRECT=icb` makes DXMT write every
indirect draw into a Metal indirect command buffer again, instead of reading the simple ones straight from the game's
argument buffer, if indirect geometry (grass, particles) goes missing or flickers.

For DXMT development, `/usr/bin/env DXMT_DXIL_DUMP=/Users/<you>/dxil %command%` saves each DXIL shader a game creates
into that folder. Give an absolute path: Steam runs launch options without a shell, so `~` and `$HOME` aren't expanded.
While it's set, DXMT also reports the Shader Model 6 features, as `DXMT_D3D12_SM6=1` does.

## Steam API

Windows games talk to your running Mac Steam through the runtime's Steam client bridge (Proton's `lsteamclient`,
built for macOS by the runtime). MacNeutron's `steam.exe` tells each game that Steam is running. Anti-cheat
that needs a Windows kernel driver (Easy Anti-Cheat, BattlEye, Vanguard and others) still won't run.

Game logs (`MACNEUTRON_LOG=1`) hide your Steam account ID, but Wine's `+steamclient` lines in them can
still contain your SteamID or persona name: check before posting a log publicly.

## Upscaling

When a game renders below the size of its window, or below your display's pixel density (Retina screens),
MacNeutron upscales each frame with Apple's MetalFX instead of the blocky stretch macOS would apply. To trade
sharpness for frame rate, pick a lower resolution in the game's windowed or borderless mode. It costs about 1 ms of
GPU time per frame while active and nothing when the game renders at full size; switch "MetalFX upscaling" off for a
game in the Games window if it misbehaves.
