# MacProton

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

## Install the runtime

```sh
.build/release/macproton install-runtime                  # downloads the pinned Wine runtime (461 MB)
.build/release/macproton import-gptk "/Volumes/<GPTK>"    # optional: Apple's GPTK from developer.apple.com
```

MacProton never ships Apple's files; `import-gptk` copies D3DMetal from the GPTK you downloaded.

## Per-game options (Steam launch options)

| Option | Effect |
|---|---|
| `MACPROTON_GRAPHICS=d3dmetal\|dxmt\|dxvk %command%` | Pick the Direct3D backend |
| `MACPROTON_LOG=1 %command%` | Wine log in `~/Library/Logs/MacProton/steam-<appid>.log` |
| `MACPROTON_NO_AVX=1 %command%` | Don't advertise AVX through Rosetta |
| `MACPROTON_NO_MSYNC=1 %command%` | Turn off msync |
