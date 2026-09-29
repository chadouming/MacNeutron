# MacNeutron — DXMT Fork: roadmap and sub-project 1 (fork, build, capture)

- **Date:** 2026-09-28
- **Status:** Draft for review
- **Builds on:** `2026-09-27-macproton-runtime-design.md` (graphics backends, tool folder), `2026-09-28-macneutron-steam-bridge-design.md` (install at app start).
- **Scope:**
  - **In:** the roadmap to a Metal-native "DXVK for Metal", and the full design of sub-project 1:
    - our public DXMT fork;
    - MacNeutron building and shipping it with Direct3D 12 enabled;
    - D3D12 test programs;
    - DXIL shader capture;
    - a probe of whether LLVM 15 can read DXIL.
  - **Out:** sub-projects 2–7 (listed in §2; each gets its own spec). Upstream contributions of any kind other than issue reports.

## 1. Goal

One open-source, Metal-native translation library for Direct3D 9–12, with no Game Porting Toolkit, performing on par with D3DMetal. MacNeutron would use one graphics backend instead of juggling DXMT and D3DMetal.

**Sub-project 1 is done when** §8's acceptance passes: MacNeutron builds, ships and installs our DXMT with D3D12 enabled; D3D11 behaves as with DXMT 0.80; a D3D12 program presents through it; SMITE 2's DXIL shaders are captured; and the LLVM 15 probe's results are recorded.

### Decisions made during brainstorming

| Decision | Choice |
|---|---|
| Direction | Route 2: grow DXMT into one Metal-native library for D3D9–12 (rejected: DXVK + vkd3d-proton on KosmicKrisp; D3DMetal only) |
| D3D12 shaders | Our own DXIL front end for DXMT's compiler (open; no Metal Shader Converter, no GPTK) |
| Goal for D3D12 | Parity with D3DMetal on speed |
| First sub-project | Fork, build and capture (with the LLVM 15 DXIL probe) |
| Fork home | `chadouming/dxmt`, a public GitHub fork, branch `macneutron`; MacNeutron builds a pinned commit locally |
| Upstream | Never sent upstream: DXMT refuses AI-authored contributions (`CONTRIBUTING.md`, `AGENTS.md`). Issue reports only |

## 2. Roadmap

1. **Fork, build, capture:** this spec.
2. **DXIL shader translator:** a DXIL front end for DXMT's `airconv` (DXBC→AIR today), starting with SM6.0 vertex, pixel and compute; the approach depends on §6's probe.
3. **D3D12 runtime for modern games:** real resource barriers, bundles, full ExecuteIndirect, resource binding tier 3 and SM6.6 dynamic resources, wave operations, then mesh shaders and ray tracing for titles that need them.
4. **Performance parity with D3DMetal:** measured with Metal System Trace on the same scenes (SMITE 2 first).
5. **MacNeutron integration:** DXMT becomes the default backend and the Game Porting Toolkit becomes optional.
6. **Direct3D 9 front end:** on DXMT's shared Metal core.
7. **Direct3D 8:** a shim onto the D3D9 front end.

## 3. Evidence (verified 2026-09-28)

1. **DXMT layout:** `src/{d3d10,d3d11,d3d12,dxgi,dxmt,airconv,winemetal,...}`.
   - **Shaders:** `airconv` compiles DXBC to AIR (Apple's LLVM IR dialect) with LLVM 15.0.7.
   - **Wine bridge:** a PE `winemetal.dll` plus a Mach-O unixlib.
   - **License:** LGPL-2.1+ since 2026-04-25 (MIT before).
   - **Activity:** about 400 commits in 2026; latest release v0.80.
2. **Upstream D3D12:** `src/d3d12` is about 10.4K lines, behind `-Denable_d3d12=true` (off by default), from PRs #180–#212 marked "DO NOT USE".
   - **Shaders:** DXBC SM5.1 only. DXIL returns `E_NOTIMPL` (`d3d12_pipeline_graphics.cpp:244`), and the device reports `D3D_SHADER_MODEL_5_1`.
   - **Missing:** `ResourceBarrier` is ignored and `ExecuteBundle` is unimplemented; there's no DXR, mesh shaders or enhanced barriers.
3. **DXMT's CI build:**
   - **Wine:** builds against a prebuilt Wine 8.16 tree (`github.com/3Shain/wine/releases/download/v8.16-3shain/wine.tar.gz`), not the runtime's Wine.
   - **LLVM 15:** Intel (x86_64), built from `llvmorg-15.0.7` with `LLVM_TARGETS_TO_BUILD=""`.
   - **Compiler:** the cross files use `x86_64-w64-mingw32-gcc` (and `i686` for 32-bit), which Homebrew's `mingw-w64` provides.
   - **Proof it works:** the runtime's DXMT 0.80 is that CI's release tarball, and it runs on our Wine 11.
4. **The runtime's DXMT 0.80:**
   - `winemetal.dll` and the unixlib go into `Libraries/Wine/lib/wine/{x86_64-windows,x86_64-unix}`.
   - The D3D frontends (`d3d11`, `d3d10core`, `dxgi`) go into `Libraries/DXMT/{x64,x32}`, which MacNeutron copies into prefixes for the `dxmt` backend.
   - There is no `d3d12.dll`.

## 4. The fork

- **Creation:** `gh repo fork 3Shain/dxmt --clone=false`, giving `github.com/chadouming/dxmt`.
- **Branch:** `macneutron`, cut from upstream `main` at fork time; upstream is merged in regularly.
- **License:** files unchanged.
- **Our changes on `macneutron`** (sub-project 1):
  1. **README note:** MacNeutron's fork, not affiliated with DXMT, changes AI-assisted and never proposed upstream per its policy.
  2. **DXIL capture:** with `DXMT_DXIL_DUMP=<folder>` set, D3D12 graphics and compute pipeline creation writes every DXIL shader it receives to `<folder>/<stage>-<16 hex of FNV-1a 64 of the blob>.dxil` before returning `E_NOTIMPL`. It skips files that already exist, and ignores write errors.

## 5. Building and shipping in MacNeutron

**Pins** (`dxmt/pins`):
- the fork's repo URL and commit;
- `llvmorg-15.0.7`;
- the Wine 8.16 tree's URL and SHA-256 (recorded at first download);
- a DXC release (Microsoft's DirectXShaderCompiler, Windows zip) with its SHA-256, a development tool only.

**`make dxmt`** (`dxmt/build.sh`):
1. **Tools.** Checks for `cmake`, `ninja`, `meson` and `x86_64-w64-mingw32-gcc`/`i686-w64-mingw32-gcc`, and names any that are missing, with the Homebrew formula. It never installs anything itself.
2. **Fetch.** Pulls each input once into `build/dxmt-src/`: a shallow clone of the fork at the pinned commit, a shallow `llvm-project` at the tag, the Wine tree (checksum-verified) and DXC (checksum-verified).
3. **LLVM.** Builds an x86_64 static LLVM 15 into `build/dxmt-src/llvm` with DXMT's documented flags, once.
4. **DXMT.** Two meson cross-builds, `build-win64.txt` and `build-win32.txt`, with `-Denable_d3d12=true -Dwine_build_path=… -Dnative_llvm_path=…`.
5. **Stage.** Everything goes into `build/dxmt/`:
   - `x86_64-windows/`, `i386-windows/` and `x86_64-unix/`;
   - `COPYING.LIB` and `LICENSE`;
   - a `version` file holding the fork commit.
6. **Probe.** Builds `build/dxmt/dxil-probe` (§6) against the same LLVM.

**App bundle.** `make app` depends on `make dxmt`.
- **Windows DLLs and licence files** go into `MacNeutron.app/Contents/Resources/DXMT/`.
- **`x86_64-unix/*`** (Mach-O) goes into `Contents/Frameworks/DXMT/`, signed.

**Install** (`DXMTInstaller.install(layout:from:)`):
- **Mac-side bridge:** copies `x86_64-unix/*` into `Libraries/Wine/lib/wine/x86_64-unix/`, and `winemetal.dll` into the matching `x86_64-windows/` and `i386-windows/`. Both halves always come from the same build.
- **Per-game DLLs:** copies `d3d11`, `d3d10core`, `dxgi` and `d3d12` into `Libraries/DXMT/x64` and `x32` (32-bit has no `d3d12`).
- **Version:** writes `<tool>/dxmt-version` last.
- **When it runs:** after every runtime install (after the GPTK overlay), and at app start when the bundled version differs from the installed one.
- **Finding the bundle:** next to the launcher, or through `Contents/Helpers → ../Resources/DXMT` and `../Frameworks/DXMT`, as for `steam.exe` and the presenter.

**Graphics backend:** when `Libraries/DXMT/x64/d3d12.dll` exists, the `dxmt` backend also copies `d3d12.dll` into `system32`, and its overrides become `dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b`. Without it, nothing changes.

**README:** a note that MacNeutron ships DXMT (LGPL-2.1+) from `github.com/chadouming/dxmt` at the commit in `dxmt-version`, and what `make dxmt` needs.

## 6. Tests, capture and the DXIL probe

- **`dxmt/tests/d3d12_clear.c`** (mingw):
  - creates a D3D12 device, direct queue, flip-model swap chain, command allocator and list, and a fence;
  - clears and presents N frames;
  - prints the adapter description, `D3D12_FEATURE_SHADER_MODEL` (highest), the resource binding tier, and the average frame time.
- **`dxmt/tests/d3d12_dxil.c`** (mingw): creates a root signature and a graphics PSO from `dxmt/tests/shaders/triangle.vs.dxil` and `triangle.ps.dxil`, and prints the HRESULT.
- **Test shaders:** `dxmt/tests/shaders/*.hlsl` plus `compile.sh`, which runs DXC's `dxc.exe` under our Wine for `vs_6_0`/`ps_6_0`/`cs_6_0`. The generated `.dxil` files are committed.
- **`dxmt/tools/dxil-probe.cpp`:**
  - reads a DXIL container and finds the `DXIL` part;
  - checks its program header (version, bitcode offset and size);
  - loads the bitcode with LLVM 15's `parseBitcodeFile`;
  - prints one line per file: `ok|fail <file> <DXIL version> <dx.op histogram top 10> <entry points>`, or the LLVM error.
- **`dxmt/check.sh`** (`make dxmt-check`, real Wine, no Steam):
  1. The D3D11 `present_loop` (from `presenter/tests`) on the `dxmt` backend completes, with frame time within 10% of the same run on the runtime's DXMT 0.80.
  2. `d3d12_clear` presents all frames on the `dxmt` backend.
  3. `d3d12_dxil` returns `E_NOTIMPL`, and with `DXMT_DXIL_DUMP` its two shaders appear in the folder.
  4. `present_loop` on `d3dmetal` still completes.
  5. `dxil-probe` runs on the test shaders (result recorded, not graded).

## 7. Errors

| Condition | Behavior |
|---|---|
| Build tool missing | `make dxmt` names it with its Homebrew formula and stops |
| Download checksum mismatch | Stops; nothing staged |
| LLVM or meson failure | Stops with the log path |
| Bundle has no DXMT | Nothing installed; the runtime's DXMT 0.80 stays |
| DXMT without `d3d12.dll` | D3D12 stays on Wine's builtin (`d3d12=b`) for the `dxmt` backend |
| Runtime reinstall | Our DXMT re-applied after the GPTK overlay |

## 8. Acceptance on the maintainer's Mac

Recorded in `docs/testing/acceptance-dxmt-fork.md`:

1. `make dxmt` and `make app` succeed; the app installs our DXMT (the `dxmt-version` commit matches the pin).
2. `make dxmt-check` passes items 1–4.
3. **A D3D11 game on our DXMT:** SMITE 2 with `-dx11` on the `dxmt` backend, or another D3D11 title. Record whether it runs, FPS and GPU time.
4. **SMITE 2 (D3D12) on the `dxmt` backend** with `DXMT_DXIL_DUMP`: record how many shaders were captured and where the game stopped.
5. **`dxil-probe`** on SMITE 2's shaders and the test shaders: record ok/fail counts and LLVM errors. This decides sub-project 2's approach.
6. D3DMetal is still SMITE 2's working default.

## 9. Risks

- **Upstream churn:** D3D12 changes weekly upstream. Mitigation: pin, and merge on our schedule.
- **LLVM 15 and DXIL:** DXIL is LLVM 3.7-era bitcode, so LLVM 15 may not read it. The probe answers this before sub-project 2 is designed; the fallback is a separate reader, such as dxil-spirv's.
- **Build cost:** LLVM takes roughly 30–60 minutes and a few GB, once.
- **LGPL:** shipping DXMT binaries requires the corresponding source to be available: the public fork, a pinned commit, and the licence files bundled.
- **The Wine 8.16 tree** we build against differs from the runtime's Wine 11. DXMT 0.80 shows this works; a winemetal ABI break would show up in check item 1.
- **Rosetta after macOS 27:** DXMT has an arm64ec build path upstream; a later sub-project can move to it.
