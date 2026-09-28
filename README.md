# MacNeutron

Proton for macOS: Windows games from your Steam library, launched by the native macOS Steam
client and translated by Wine and Apple's D3DMetal.

**Status:** sub-project 1 (the runtime) is in progress. Design: `docs/superpowers/specs/`.

**Requirements:** Apple Silicon, macOS 26 or later, Rosetta 2, Xcode 27 (Swift 6).

## Build and test

```sh
make build   # swift build -c release
make test    # unit tests
make smoke   # real Wine; needs `brew install mingw-w64`
```

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
```

MacNeutron never ships Apple's files; `import-gptk` copies D3DMetal from the GPTK you downloaded.

## Per-game options

Use the app's Games window, or Steam launch options:

Start launch options with `/usr/bin/env`. macOS Steam runs them without a shell, so the Linux-style
`VAR=value %command%` fails to launch.

| Launch options | Effect |
|---|---|
| `/usr/bin/env MACNEUTRON_GRAPHICS=d3dmetal\|dxmt\|dxvk %command%` | Pick the Direct3D backend (`dxvk` is unavailable while GPTK is imported and falls back to `d3dmetal`) |
| `/usr/bin/env MACNEUTRON_LOG=1 %command%` | Wine log in `~/Library/Logs/MacNeutron/steam-<appid>.log` |
| `/usr/bin/env MACNEUTRON_NO_AVX=1 %command%` | Don't advertise AVX through Rosetta |
| `/usr/bin/env MACNEUTRON_NO_MSYNC=1 %command%` | Turn off msync |
| `/usr/bin/env MACNEUTRON_NO_STEAM_BRIDGE=1 %command%` | Start the game without the Steam bridge (the game then can't reach Steam) |

## Steam API

Windows games talk to your running Mac Steam through the runtime's Steam client bridge (Proton's `lsteamclient`,
built for macOS by the runtime). MacNeutron's `steam.exe` tells each game that Steam is running. Anti-cheat
that needs a Windows kernel driver (Easy Anti-Cheat, BattlEye, Vanguard and others) still won't run.
