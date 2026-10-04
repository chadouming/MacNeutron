# Sub-project 5 map: release packaging and licensing

Reader: release packaging and licensing. Read-only. Repo at `95f8883` (HEAD). All paths are repo-relative unless they
start with `build/` (untracked, local build output on the maintainer's Mac) or are GitHub names. "[live]" marks a
`gh` query run on 2026-10-04. "[I]" marks my inference. Nothing here is legal advice (the repo says the same:
`wine-arm64/licenses/README:7`).

---

## 1. How MacNeutron.app is built, signed and distributed today

### 1.1 There is no release

- No GitHub release, no tag: `gh release list -R chadouming/MacNeutron` returns nothing [live]; `git tag` is empty.
- The repository is PUBLIC and has no licence: `gh repo view` gives `visibility: PUBLIC`, `licenseInfo: null` [live].
  No `LICENSE`/`COPYING` file is tracked (`git ls-files` holds only `wine-arm64/licenses/*`,
  `wine-arm64/tests/licences_test.sh` and a research script).
- The project's own licence is explicitly deferred to "before the first release":
  - `docs/superpowers/specs/2026-09-28-macneutron-steam-bridge-design.md:187` (our own `steam.c`, `probe.c` need one
    "before public release"; "the maintainer's choice");
  - `docs/superpowers/specs/2026-10-04-macneutron-ship-base-wine-design.md:105` ("MacNeutron's own code gets a line
    once the repository has a licence (to be decided before sub-project 5's first release)").
- No CI: no `.github/` directory. No release, notarize, package or DMG script anywhere: `notarytool`, `stapler`,
  `productbuild`, `pkgbuild` appear in no tracked file outside `docs/research` (grep over `git ls-files`). `ditto` and
  `hdiutil` appear only for the GPTK import (`Sources/MacNeutronCore/GPTKImporter.swift:108-110`,
  `Sources/MacNeutronCore/GPTKDiskImage.swift:42,67,85`).
- The app design spec put signing out of scope: `docs/superpowers/specs/2026-09-27-macneutron-app-design.md:8`
  ("Out: … Developer ID signing and notarization").

### 1.2 How users get it: build from source

- `README.md:36-41`: `make app` → `build/MacNeutron.app`, "ad-hoc signed", then `open build/MacNeutron.app`.
- `README.md:10-11`: requirements Apple Silicon, macOS 26+, Rosetta 2, Xcode 27; the arm64 runtime needs macOS 27 and
  the Developer ID setup.
- `README.md:39` still says `make app` "needs brew install mingw-w64"; the Makefile actually builds every Windows binary
  with the pinned llvm-mingw (`Makefile:4-8`; `README.md:32-34` says so too). Stale line [doc drift].

### 1.3 `make app` (`Makefile:85-104`)

| Step | Line | What |
|---|---|---|
| deps | 86 | `app: build bridge presenter dxmt` |
| layout | 87-92 | `build/MacNeutron.app/Contents/{MacOS,Helpers,Resources,Frameworks}`; `App/Info.plist`; `MacOS/MacNeutron` (SwiftPM `MacNeutronApp`); `Helpers/macneutron` (CLI) |
| steam.exe | 93 | `build/bridge/steam.exe` → `Contents/Resources/steam.exe` (x64 only; `build/bridge/arm64/steam.exe` and `arm64/tests/helper.exe`, built at `Makefile:30-31`, are never copied, and `writeToolFiles` looks for exactly one `steam.exe`, `RuntimeInstaller.swift:121-126`: the app needs a second slot for the arm64 runtime) |
| presenter | 95-97 | `libmacneutron-present.dylib` → `Contents/Frameworks/`, ad-hoc signed |
| DXMT LGPL check | 98 | `sh dxmt/published.sh build/dxmt-src/dxmt $(cat build/dxmt/version)`: fails unless the DXMT commit is on the public fork's `macneutron` branch (`dxmt/published.sh:2-9`, "MacNeutron ships DXMT under the LGPL, so the exact source … must be public"). Needs network (`git fetch`, `:7`) |
| DXMT | 99-103 | `build/dxmt/{x86_64-windows,i386-windows,version,COPYING.LIB,LICENSE,LICENSE.OLD}` → `Contents/Resources/DXMT/`; `x86_64-unix/*` (winemetal.so) → `Contents/Frameworks/DXMT/`, each ad-hoc signed |
| seal | 104 | `codesign --force --sign - $(APP)` |

- Every `codesign` in the target is `--sign -` (ad hoc), with no `--options runtime` and no `--timestamp`
  (`Makefile:94,97,103,104`). As built, MacNeutron.app cannot be notarized regardless of wine.app [I: notarization
  requires Developer ID, hardened runtime and a secure timestamp].
- `App/Info.plist:5-13`: `CFBundleIdentifier io.github.chadouming.MacNeutron`, `CFBundleShortVersionString 0.1.0`,
  `CFBundleVersion 1`, `LSMinimumSystemVersion 26.0`, `LSUIElement true`. No entitlements file for the app exists.
- `App/Info.plist` is not wine.app's: two identities and two minimum OSes (`wine-arm64/Info.plist:6,16`:
  `net.authspot.macneutron.wine`, `27.0`; team `49QMZXLR8S`, `wine-arm64/wine.entitlements:6,8`).

### 1.4 Where the app installs things at run time

- Tool folder: `~/Library/Application Support/MacNeutron/compatibilitytools.d/macneutron`
  (`Sources/MacNeutronCore/ToolLayout.swift:14-18`), a path with spaces.
- `RuntimeInstaller.writeToolFiles` (`Sources/MacNeutronCore/RuntimeInstaller.swift:110-133`) writes
  `compatibilitytool.vdf`, `toolmanifest.vdf`, the `proton` stub, copies the launcher to `bin/macneutron`, finds
  `steam.exe` next to the launcher or in `../Resources/steam.exe` (`:121-126`), the presenter in `../Frameworks/`
  (`:128-132`). Copies are temp-file + `rename(2)`, skipped when identical (`:136-148`). Runs at every app start.
- So the app copies its own signed helpers out of its bundle into Application Support; the copies run from there.
  How that interacts with notarization/quarantine is never discussed in the repo (no hit for `quarantine`, `xattr`,
  `Gatekeeper`, `spctl`, `translocat` in `Sources`, `wine-arm64`, `docs/superpowers`, `docs/research`).

---

## 2. How the Rosetta runtime is distributed

- `RuntimePin.current` (`Sources/MacNeutronCore/RuntimeInstaller.swift:12-15`): `runtime-v4.7.3`,
  `https://github.com/dappermint/winecx-gptk/releases/download/runtime-v4.7.3/Libraries.tar.gz`, SHA-256
  `a4b5d634…fd331`. A third party (dappermint) builds and hosts it; MacNeutron downloads it at install time.
  It is the latest release there (`gh release list -R dappermint/winecx-gptk`: "runtime 4.7.3 Latest", 2026-09-17)
  [live]. Size: "461 MB" (`README.md:51`).
- Code comment, `RuntimeInstaller.swift:11`: "ponytail: upstream release; point `url` at the chadouming/winecx-gptk fork
  before the first public release." That fork does not exist (`gh repo view chadouming/winecx-gptk`: "Could not
  resolve") [live].
- Flow: `cachedDownload` → `~/Library/Caches/MacNeutron/<version>.tar.gz` (`:151-160`); `download` via
  `URLSession.shared.download`, HTTP 200 required (`:163-168`); `install` checks SHA-256, untars to
  `runtime.staging`, requires `Libraries/Wine/bin/{wine,wineserver}`, swaps `Libraries/` (`:74-105`); then re-applies
  GPTK and the bundled DXMT (`:101-104`). CLI: `macneutron install-runtime [--tool-dir] [--tarball]`
  (`Sources/MacNeutronCore/CommandLineTool.swift:9,31`).
- Contents: CrossOver 26.3 changes on Wine 11.17 x86_64, DXMT 0.80, DXVK-macOS (`RuntimeInstaller.swift:10`;
  `docs/superpowers/specs/2026-09-27-macproton-runtime-design.md:75`), and its own `lsteamclient` x86_64/i386
  (`docs/superpowers/specs/2026-09-28-macneutron-steam-bridge-design.md:44`).
- It "ships the full x86_64 set (gnutls 3.8.9, nettle 3.10, FreeType, plus FFmpeg, GStreamer, MoltenVK, krb5) with no
  licence files [V]. That is not a precedent to copy." (`docs/research/2026-10-04-ship-base/brief.md:26`; same in
  `docs/research/2026-10-04-ship-base/maps-summaries.md:28`).
- The Rosetta runtime's Wine binaries are unsigned (`docs/superpowers/specs/2026-09-28-macneutron-metalfx-upscaler-design.md:29`).
- Today MacNeutron is not the distributor of that tarball or of its lsteamclient: the bridge spec relies on that
  (`…steam-bridge-design.md:14,28,187`: "the runtime's distributor carries it"; "MacNeutron doesn't redistribute it").
  Re-hosting it under chadouming (the `:11` TODO) would change that.

---

## 3. The arm64 runtime (`wine.app`): what exists today

### 3.1 Build, sign, stage

- `make wine-arm64` → `sh wine-arm64/build.sh` (`Makefile:109-110`) → `sh wine-arm64/bundle.sh`
  (`wine-arm64/build.sh:352`) → `build/wine-arm64/wine.app` (staged by `mv` only after every assert,
  `wine-arm64/bundle.sh:2-3,222-224`).
- Signing inputs (env, never committed): `MACNEUTRON_SIGN_IDENTITY` ("Developer ID Application: … (49QMZXLR8S)"),
  `MACNEUTRON_PROVISIONING_PROFILE` (path) — `wine-arm64/README.md:38-41`,
  `docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md:366-367`.
- `check_signing` (`wine-arm64/lib.sh:75-83`) runs before any fetch (`wine-arm64/build.sh:42`) and before bundling
  (`wine-arm64/bundle.sh:22`); `check_profile_plist` (`wine-arm64/lib.sh:60-71`) requires App ID
  `49QMZXLR8S.net.authspot.macneutron.wine` (`:56`), `cross-architecture-support = true`, and an unexpired profile.
- No ad-hoc mode, and nobody else can build a working runtime: "only a team with the capability granted can produce
  a working runtime" (`…native-arm64-design.md:369`; `wine-arm64/README.md:34-36,43-46`). Consequence [I]: wine.app
  can only reach users as a binary the maintainer builds and signs; "build it on the user's Mac" is not an option for
  the bundle as a whole.
- Signing (`wine-arm64/bundle.sh:107-119`):
  - `Info.plist` copied; profile copied to `Contents/embedded.provisionprofile` (`:108`);
  - every Mach-O except the loader: `codesign -f -s "$ID" --options runtime` (`:115-117`);
  - the bundle (entitlements land on `Contents/MacOS/wine`): `--options runtime --entitlements wine-arm64/wine.entitlements` (`:118-119`).
- Entitlements (`wine-arm64/wine.entitlements:5-16`): `com.apple.application-identifier`,
  `com.apple.developer.team-identifier`, `com.apple.developer.cross-architecture-support`,
  `com.apple.security.cs.allow-jit`, `…allow-unsigned-executable-memory`, `…disable-library-validation`.
- Asserts already in place that are notarization prerequisites (`wine-arm64/bundle.sh`):
  `codesign --verify --strict --deep` (`:122`); loader has the cross-arch entitlement (`:123-124`); no
  `get-task-allow` (`:125-127`); every Mach-O has a secure timestamp `Timestamp=` (`:133`); `minos 27.0` (`:131-132`);
  no dependency outside `/usr/lib`, `/System`, `@…` (`:136-138`); no non-`@` rpath (`:141-144`);
  `disable-library-validation` present (`:216-217`). Ship-base spec `§4` added the timestamp/get-task-allow asserts
  for this reason (`…ship-base-wine-design.md:108`).
- `wine-arm64/Info.plist:4-17` has `CFBundleIdentifier`, `CFBundleExecutable`, `CFBundleName`, `CFBundlePackageType`,
  `CFBundleInfoDictionaryVersion`, `LSMinimumSystemVersion 27.0`; no `CFBundleShortVersionString` or
  `CFBundleVersion`. Whether that matters for notarization or for a launcher version check is unrecorded.

### 3.2 Bundle size and content (local staged build, `build/wine-arm64/wine.app`)

- 1.3 GB total; `Resources/lib/wine/aarch64-windows` 1.2 GB / 1001 files; `aarch64-unix` 37 MB; `DXMT/` 18 MB;
  `share/` 41 MB; `licenses/` 464 KB (`du`, local).
- Largest PE files: `icu.dll` 80 MB, `lsteamclient.dll` 57 MB, `wined3d.dll` 52 MB, `mshtml.dll` 44 MB.
- 249 `.a` import libraries (36 MB, e.g. `libc++.a` 14 MB) ship inside `aarch64-windows`: they are `make install`'s
  development files (`wine-arm64/bundle.sh:36-39` moves `bin lib share` wholesale; `include/` is not moved).
- Layout: `docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md:191-214`; bundle additions in
  `…ship-base-wine-design.md:81-94`; acceptance numbers in `docs/testing/acceptance-arm64-ship-base.md:94-108`.

---

## 4. What the SP3 docs' three release items mean concretely

All three are in the ship-base spec's Out list, assigned to SP5:
`docs/superpowers/specs/2026-10-04-macneutron-ship-base-wine-design.md:23` ("notarization, release source archives,
and refusing development inputs in release bundles (sub-project 5)") and row 5
(`…native-arm64-design.md:65`: "release packaging: notarization of the entitled bundle (unverified, §11), release
source archives, refusing development inputs in release bundles, stripping builtin PE files (`lsteamclient.dll` is
57 MB)").

### 4.1 "Release source archives"

- Origin: `docs/research/2026-10-04-ship-base/brief.md:115`: "LGPL source access: a public repo at a tagged commit
  (the repo is PUBLIC [V]), plus source archives attached to the same release as wine.app. That release step belongs to
  SP5. A written offer is not needed [I]." Alternative rejected: no SOURCE file and no archives is "weaker under
  LGPL-2.1 §4" (`:119`). The same in `docs/research/2026-10-04-ship-base/maps-summaries.md:74`.
- What exists: `licenses/SOURCE`, generated by `wine-arm64/build.sh:333-350`, one `KEY=value` per input:
  `MACNEUTRON_COMMIT`, `WINE_COMMIT`, `WINE_SERIES`, `FEX_COMMIT`, `FEX_SERIES`, six `FEX_SUBMODULE_*`,
  `DXMT_COMMIT`, `DXMT_SERIES`, `LLVM_TAG`, `LLVM_MINGW_SHA256`, `LSTEAMCLIENT_COMMIT`, `LSTEAMCLIENT_SERIES`, and the
  four tarballs' `*_URL`/`*_SHA256` (`deps_pins`, `:169,349`). `licenses/README:3-7` tells a reader the patches and pins
  are in this public repo at `MACNEUTRON_COMMIT`, and per component where the upstream is (`:9-76`).
- What doesn't exist: no tag, no archive is produced; the patched trees live only in `build/wine-arm64-src/`
  (`wine`, `fex` + submodules, `dxmt`, `lsteamclient`, `deps-src/*` tarballs). `wine-arm64/export.sh` writes commits
  back to patches; nothing packs sources.
- Candidate archive contents [I], by obligation recorded in `wine-arm64/licenses/README`:
  - LGPL: Wine at `WINE_COMMIT` + `patches/wine` (`:9-14`); DXMT at `DXMT_COMMIT` + `patches/dxmt` (`:24-28`);
    gnutls/libtasn1/libunistring, nettle, gmp tarballs, and "libgnutls.30.dylib must stay rebuildable from what we
    publish" (`brief.md:85`; `licenses/README:49-67`).
  - Not required by licence but cheap: FEX (MIT), FreeType (FTL), LLVM (Apache).
  - lsteamclient: its source is Steamworks-SDK-derived and "never committed"
    (`…ship-base-wine-design.md:39`; `docs/superpowers/plans/2026-10-04-macneutron-ship-base-wine.md:34`), so attaching
    it to a release raises the same question as the binary (§5).
- Precedent for the "exact source is public" check: `dxmt/published.sh` (Rosetta app only).

### 4.2 "Refusing development inputs in release bundles"

Nothing refuses them today; the build records them. The marks a release gate would read:

| Mark | Where set | Meaning |
|---|---|---|
| tree mode `development` | `wine-arm64/lib.sh:23-34` (`build_mode`: dirty tree, HEAD ≠ applied commit, a stash, a second branch, a second worktree) | the tree holds unexported work |
| `wine-arm64: development build`, no stamp | `wine-arm64/build.sh:147-151,355-357` | the bundle is still staged |
| `*_SERIES=dev` in SOURCE | `wine-arm64/build.sh:333,337,339,344,348` | that tree isn't the committed patch series |
| `MACNEUTRON_COMMIT=<sha>+dirty` | `wine-arm64/build.sh:143-145` (any change under `wine-arm64 dxmt bridge Makefile`, untracked included) | repo inputs differ from the commit |
| `DXMT/version` = `<DXMT_COMMIT>+dev` | `wine-arm64/build.sh:321-322` | DXMT tree has its own work |

- `wine-arm64/tests/licences_test.sh:15` `key()` only checks a SOURCE key is present, so `dev`/`+dirty` values pass;
  `bundle.sh:198` accepts `"$DXMT_COMMIT"+?*`, i.e. `+dev` too.
- `bundle.sh:199-200` checks `DXMT_COMMIT` is an ancestor of the local DXMT HEAD, not that it is published.
- Other development-only things in the bundle [I]: the 249 `.a` import libraries (§3.2); `DXMT/aarch64-windows/dxmt-replay.exe`
  (`bundle.sh:55`) is a tool, not a game DLL (whether it ships is a choice); the provisioning profile path is a
  machine-local input, fine. `MACNEUTRON_COMMIT` being unpushed is also unchecked (the commit must be public for
  `licenses/README:6` to hold).
- Also a Rosetta-side analogue: `dxmt/published.sh` refuses an unpublished DXMT commit, but only `make app` runs it.

### 4.3 "Stripping builtin PE files"

- Source: `docs/testing/acceptance-arm64-ship-base.md:101` (`lsteamclient.dll 57 MB … not stripped`) and `:375`
  ("Wine doesn't strip its builtin PE files. Noted for sub-project 5's packaging").
- Cause: Wine's configure gives the PE side `aarch64_CFLAGS = -g -O2` and `arm64ec_CFLAGS = -g -O2`, plus `-gdwarf-4` in
  `*_EXTRACFLAGS` (`build/wine-arm64-src/wine-build/Makefile:81,83,105,107`); `make install` keeps it.
- It's bundle-wide, not just lsteamclient (`llvm-objdump -h`, local): non-debug vs DWARF sections —
  `lsteamclient.dll` 4.4 MB vs 52.2 MB (`.debug_str` alone 0x24705f7 ≈ 38 MB); `icu.dll` 8.4 vs 69.8; `wined3d.dll`
  6.2 vs 45.8; `mshtml.dll` 3.4 vs 40.1. Extrapolating [I], most of the 1.2 GB `aarch64-windows` is DWARF.
- Levers [I]: configure Wine's PE side without `-g` (would need a `.configure-inputs` change → full Wine rebuild,
  `wine-arm64/build.sh:241,249-257`); or `llvm-strip --strip-debug` over `aarch64-windows/*.{dll,exe,…}` in `bundle.sh`
  before signing (PE files carry no code signature, `bundle.sh:110`, but the bundle seal covers them, so it must
  precede `:118`); optionally keep the unstripped set as a separate symbols archive. Must not disturb the builtin
  marker check (`bundle.sh:192-196`, bytes 64-79) or `llvm-readobj --coff-load-config` CHPE check (`:206-207`).
  DXMT's DLLs are already `meson --strip` (`wine-arm64/build.sh:312`); `lsteamclient.dll` is built by Wine's own build
  (patch 0016), so only the Wine-side lever covers it.

---

## 5. lsteamclient licensing

### 5.1 What the repo records

- Proton's `lsteamclient/LICENSE` is Valve's Steamworks SDK licence, not BSD:
  `…steam-bridge-design.md:40`; `…ship-base-wine-design.md:40`; `docs/research/2026-10-04-ship-base/brief.md:263,365`
  ("local LICENSE blob 16381609e5 and Proton's proton_10.0 lsteamclient/LICENSE").
- winecx's import commit labels it LGPL-2.1, contradicting the LICENSE that commit adds
  (`docs/research/2026-10-04-ship-base/maps-summaries.md:55`).
- One file, `cxx.h`, is LGPL-2.1+ (CodeWeavers, from Wine): `wine-arm64/bundle.sh:103-106` writes that NOTE;
  `wine-arm64/licenses/README:69-76`; `wine-arm64/README.md:221-225`.
- The licence text itself (local copy `build/wine-arm64-src/lsteamclient/lsteamclient/LICENSE`, 149 lines): §1.1(a)
  (`:36-37`) grants use and local reproduction of the SDK in source form only to develop the licensee's own software;
  §1.1(b) (`:39-41`) allows distribution only of the SDK's `redistributable_bin` folder, in object code, with that
  software; §1.3 reserves all other rights. lsteamclient.dll/.so are neither `redistributable_bin` nor the
  licensee's "Licensee Software" in an obvious sense [I]. Term/termination at `:78`.
- Current positions:
  - Rosetta: MacNeutron neither builds nor ships lsteamclient; the runtime distributor does
    (`…steam-bridge-design.md:14,28,187`).
  - arm64: local builds bundle it "covered by the Steamworks SDK licence's development grant"
    (`…ship-base-wine-design.md:244`); release inclusion "not decided" — options listed as "ship it, ask Valve, or
    release without it and leave Steam-API games on Rosetta", decided in SP5 "before the first release"; until then
    "MacNeutron doesn't redistribute it" (`…ship-base-wine-design.md:18,40`; `wine-arm64/licenses/README:72-73`;
    `wine-arm64/README.md:224-225`; roadmap `…native-arm64-design.md:64-65`: "not redistributed until decided").
  - If no: "Steam-API games stay on Rosetta" (`brief.md:318`; `maps-summaries.md:55`).

### 5.2 What exactly would be redistributed

- Source: Proton `lsteamclient/` at `db9e6ffbf24a95b104fb699dd62532c70a2f9a51` (`wine-arm64/deps.pins:17-18`), sparse
  checkout excluding `steamworks_sdk_*` and `gen_wrapper.py` (`wine-arm64/build.sh:100-102`), plus three winecx Mac
  fixes (`wine-arm64/README.md:222-224`). Linked into Wine as `dlls/lsteamclient` (`wine-arm64/build.sh:135-140`),
  registered by Wine patch 0016.
- Local tree (`build/wine-arm64-src/lsteamclient/lsteamclient/`, 276 files, 18 MB): 212 generated
  `cppISteam*_<VERSION>.cpp` unix thunks, `winISteam*.c` PE thunks, `steamclient_generated.{c,h}`,
  `steamclient_structs_generated.h`, `unix_private_generated.h` (20,700 lines), `unixlib_generated.*`, hand-written
  `*_manual.{c,cpp}`, `steamclient_main.c`, `unixlib.cpp`. The generated `.cpp` files include only `unix_private.h`
  (219 of 219 `#include "unix_private.h"`); no raw Valve SDK header is compiled. But `unix_private_generated.h`
  declares Valve's interface vtables (e.g. `virtual int32_t CreateSteamPipe() = 0`, `:10`) and
  `steamclient_structs_generated.h` Valve's struct layouts, generated from the SDK headers by `gen_wrapper.py`.
  So the binaries compile in SDK-derived declarations (interface layouts, versions, structs), no Valve
  implementation code [V for the tree; I for the "derived" characterisation].
- Binaries: `Resources/lib/wine/aarch64-windows/lsteamclient.dll` (ARM64X, Wine builtin, 57 MB unstripped / ~4.4 MB
  code+data) and `Resources/lib/wine/aarch64-unix/lsteamclient.so` (arm64, 4.4 MB, links `@rpath/ntdll.so`,
  `/usr/lib/libc++.1.dylib`) — `docs/testing/acceptance-arm64-ship-base.md:99-101`. Valve's own code
  (`steamclient.dylib`) is never shipped: it's loaded from the user's Mac Steam via `STEAM_COMPAT_CLIENT_INSTALL_PATH`
  (`…ship-base-wine-design.md:75`).
- Release coupling: both files are sealed inside the Developer-ID-signed wine.app; leaving them out means a different
  build (Wine patch 0016 registers the DLL; `bundle.sh:204-217` dies if either file is missing, and
  `licences_test.sh:61-64` requires its licence files when `lsteamclient.so` is present).

### 5.3 Options (from the repo, with the constraints the repo records)

| Option | Evidence / constraint |
|---|---|
| Ship it in release wine.app | Makes MacNeutron the distributor, reversing `…steam-bridge-design.md:187` (`brief.md:263`). Licence grant above does not obviously cover it [I] |
| Ask Valve | Listed in `…ship-base-wine-design.md:40`; no record of contact |
| Omit; Steam-API games stay on Rosetta | `…ship-base-wine-design.md:40`; `brief.md:318`. Needs a bundle variant without it (bundle.sh `:204-217` asserts presence) and a launcher that treats "no bridge on arm64" like `ToolLayout.steamBridgeInstalled` false (`…steam-bridge-design.md:127,137`) |
| Build on the user's Mac | Not recorded as an option. Would need llvm-mingw, a configured Wine 11.19 tree (headers, winebuild, import libs) and clang++ (`…ship-base-wine-design.md:166`); the result can't enter the sealed bundle; whether Wine would load a builtin `.so` from outside its `dll_dir` is unrecorded [I] |
| Download at first run | Not recorded. Only precedent: the Rosetta runtime, whose third-party distributor ships lsteamclient (§2). A prebuilt from MacNeutron is redistribution again [I] |

---

## 6. Notarization of the entitled bundle

Known [V, in repo]:
- Unverified: `…native-arm64-design.md:474-477` ("Notarization of a bundle with it is unverified (sub-project 5)";
  Apple could revoke the entitlement); `…ship-base-wine-design.md:248`; `brief.md:116,317`;
  `…arm64-dxmt-design.md:20`.
- Prerequisites met: Developer ID, hardened runtime, secure timestamp, no get-task-allow, a Developer ID profile
  (`brief.md:116`; `maps-summaries.md:75`; asserts at `wine-arm64/bundle.sh:116-133`).
- In-bundle symlinks pass `--verify --strict --deep` (`…native-arm64-design.md:211`); the SP1 trial's out-of-bundle
  symlink failed strict verify, "notarization would not" accept it
  (`docs/research/2026-10-02-native-arm64/entitled-trial.md:25`).
- The entitlement was granted for App ID `net.authspot.macneutron.wine`, team `49QMZXLR8S`, "through a Developer ID
  provisioning profile" (`…native-arm64-design.md:48`); the profile is embedded (`bundle.sh:108`).
- Every DXMT update means rebuild, re-sign, re-notarize wine.app (`docs/research/2026-10-03-arm64-dxmt/maps.md:413`;
  `docs/research/2026-10-03-arm64-dxmt/brief.md:141`).
- A modified bundle still runs (patch 0007 only reads entitlements, never the seal) but fails verification and
  notarization (`docs/research/2026-10-03-arm64-dxmt/maps.md:348`).
- An experiment was suggested and not done: "Pulling a one-off manual `notarytool submit` into SP3: fine as an
  experiment" (`brief.md:121`).

Unknown (nothing in repo):
- Whether Apple's notary service accepts `com.apple.developer.cross-architecture-support` in a Developer ID profile.
- Submission size: 1.3 GB as staged (§3.2); much smaller after stripping [I].
- Packaging for notarization/stapling: wine.app nested inside MacNeutron.app vs a separate download; zip/dmg; whether
  the ticket is stapled to wine.app before archiving.
- Quarantine/Gatekeeper path for a runtime the app downloads or copies into Application Support, and launched by the
  launcher (not LaunchServices). `wine-arm64/check.sh:19` installs with `cp -cR` to
  `…/wine-arm64 check/Application Support/wine.app`; no quarantine case is tested.
- MacNeutron.app itself: needs Developer ID + hardened runtime + timestamp (today ad hoc, `Makefile:94-104`); its
  hardened runtime would strip `DYLD_*`, which the Rosetta presenter path relies on via the launcher
  (`…metalfx-upscaler-design.md:29`; row 5's "presenter loaded without `DYLD_INSERT_LIBRARIES`",
  `…native-arm64-design.md:65`) [I: interplay].
- Whether the unsigned Rosetta runtime tarball causes notarization/Gatekeeper trouble once MacNeutron.app is
  notarized: not discussed.

---

## 7. The Rosetta app's missing LLVM and mingw-w64 notices

- Recorded: `docs/research/2026-10-04-ship-base/brief.md:132` ("MacNeutron.app … its x86_64 winemetal.so contains LLVM,
  and its DXMT DLLs and steam.exe contain the mingw-w64 runtime [V]. That is a small separate change"); parked in
  SP3's Out list (`…ship-base-wine-design.md:24`) and in row 5 ("Parked here, with no owner",
  `…native-arm64-design.md:65`).
- What ships today: only DXMT's `COPYING.LIB`, `LICENSE`, `LICENSE.OLD` (`Makefile:100-101`;
  `build/MacNeutron.app/Contents/Resources/DXMT/`). Affected binaries:
  - `Contents/Frameworks/DXMT/x86_64-unix/winemetal.so`: LLVM 15 built by `dxmt/build.sh:54-55` and linked in (`:73`);
  - `Contents/Resources/DXMT/{x86_64,i386}-windows/*.dll`: llvm-mingw (`dxmt/build.sh:69-73`);
  - `Contents/Resources/steam.exe`: `$(MINGW) … -static` (`Makefile:6,27`).
- Also missing [V by grep: 0 hits for `DXBC|Microsoft|Bessonov` in `build/dxmt/{LICENSE,LICENSE.OLD,COPYING.LIB}`]:
  DXMT's compiled-in DXBCParser (MIT, Microsoft) and constexpr GUID parser (MIT) notices, plus LLVM's ConvertUTF and
  regex notices — wine.app covers these in `wine-arm64/licenses/NOTICES.md:131-222`.
- Reusable pattern: wine.app's `put` lines `wine-arm64/bundle.sh:80-83` (`build/dxmt-src/llvm-project/llvm/LICENSE.TXT`,
  `lib/Support/COPYRIGHT.regex`, `build/dxmt-src/llvm-mingw/LICENSE.TXT`,
  `aarch64-w64-mingw32/share/mingw32/COPYING.MinGW-w64-runtime.txt`) and `licences_test.sh`.
- The Rosetta runtime tarball (third party) has no licence files either (§2).

---

## 8. Licence tree and its test (what SP5 inherits)

- `Resources/licenses/` (33 files) + `Resources/DXMT/` (3): `docs/testing/acceptance-arm64-ship-base.md:110-115`;
  filled by `wine-arm64/bundle.sh:64-106`.
- `wine-arm64/tests/licences_test.sh <wine.app>` (`:10-73`): verbatim files exist (`:19-30`), NOTICES.md holders
  (`:33-36`), FEX External drift (`:39-43`), conditional FreeType/gnutls/lsteamclient files (`:47-64`), SOURCE keys
  (`:67-70`); `--self-test` proves red (`:81-99`). Run by `bundle.sh:128` and `Makefile:151-152`.
- `wine-arm64/licenses/README:1-78` maps component → licence → source; the FreeType credit line is at `:78` and
  `README.md:30`. MacNeutron's own code has no line yet (`…ship-base-wine-design.md:105`).
- `licences_test.sh` would need changes if lsteamclient is omitted (its check is conditional, `:61`, so omission
  passes) or if MacNeutron gets a licence line.

---

## 9. Open design questions (each with the lines that make it a question)

1. **Is there a first release at all in SP5, and of what?** Row 5 scopes "release packaging"
   (`…native-arm64-design.md:65`), but no release, tag, CI or project licence exists (`gh` [live]; no LICENSE) and the
   README tells users to build from source (`README.md:36-41`). Does SP5 ship MacNeutron.app + wine.app, or only make
   them shippable?
2. **MacNeutron's own licence.** Required "before public release" (`…steam-bridge-design.md:187`) and before SP5's
   first release (`…ship-base-wine-design.md:105`); maintainer's call, undecided.
3. **lsteamclient in release wine.app: ship / ask Valve / omit.** Undecided (`…ship-base-wine-design.md:40`); the SDK
   licence's grants (LICENSE `:36-41`) don't obviously cover it; omission forces a bundle variant (bundle.sh `:204-217`
   asserts presence) and launcher fallback. If omitted, every Steam-API game stays on Rosetta (`brief.md:318`),
   which collides with SP9's cutover goal (`…native-arm64-design.md:69`).
4. **The Rosetta runtime's host.** `RuntimeInstaller.swift:11` plans to re-point to a chadouming fork "before the first
   public release" (fork doesn't exist [live]); that would make MacNeutron the redistributor of a tarball with
   lsteamclient and FFmpeg/GStreamer/gnutls etc. without licence files (`brief.md:26`), contradicting
   `…steam-bridge-design.md:187`. Keep dappermint's URL, fork it, or rebuild?
5. **How wine.app reaches users.** Nested in MacNeutron.app (one notarization, +1.3 GB or ~0.2 GB stripped [I] app) or
   a separate download like the Rosetta runtime (`RuntimeInstaller.swift:12-15,151-168`)? Row 5 says "installing
   `wine.app` (at a path with spaces)" (`…native-arm64-design.md:65`; `wine-arm64/check.sh:19`) but not from where.
   Only the maintainer can build it (`…native-arm64-design.md:369`).
6. **Notarization of the restricted entitlement.** Unverified (`…native-arm64-design.md:476`; `brief.md:116`); the
   cheap one-off `notarytool submit` experiment (`brief.md:121`) was never run. Should SP5 run it first, as a gate,
   before designing the pipeline? Fallback if refused?
7. **MacNeutron.app signing.** Ad hoc today (`Makefile:94-104`); notarizing it needs Developer ID + hardened runtime +
   timestamp, and the hardened runtime ignores `DYLD_*` (`…ship-base-wine-design.md:66`), which interacts with the
   presenter injection (`…metalfx-upscaler-design.md:29`; row 5). Same Developer ID team as wine.app? Which bundle ID
   (`io.github.chadouming.MacNeutron` vs `net.authspot.…`)?
8. **Release gate on development inputs.** Marks exist (`lib.sh:23-34`, `build.sh:143-151,321-348`) but nothing refuses
   them (`licences_test.sh:15`, `bundle.sh:198-200`); also unchecked: `MACNEUTRON_COMMIT` and `DXMT_COMMIT` pushed to
   the public remotes (`licenses/README:6`; `dxmt/published.sh` exists but only `make app` runs it). Where does the
   refusal live (bundle.sh behind a `RELEASE=1`, or a separate release script)?
9. **Source archives: contents and host.** `brief.md:115` says archives "attached to the same release as wine.app";
   nothing produces them; which trees (patched vs pin + patches), and whether lsteamclient's source may be attached
   (never committed, `…ship-base-wine-design.md:39`).
10. **Stripping: configure vs post-pass, and keep symbols?** DWARF dominates (`Makefile:81,105` of the Wine build; 52 of
    57 MB in lsteamclient.dll, 70 of 78 MB in icu.dll); configure change forces a full Wine rebuild
    (`build.sh:249-257`); a post-pass must precede signing (`bundle.sh:118`) and keep the builtin marker/CHPE checks
    (`bundle.sh:192-207`). Also: drop the 249 `.a` import libs and `dxmt-replay.exe`?
11. **Rosetta app notices.** Parked in row 5 with no owner (`…native-arm64-design.md:65`); scope is LLVM + mingw-w64
    per `brief.md:132`, but DXBCParser/com_guid/ConvertUTF/regex notices are missing too (§7). Does the fix also add a
    licence test for MacNeutron.app?
12. **Versioning.** wine.app has no `CFBundleShortVersionString`/`CFBundleVersion` (`wine-arm64/Info.plist:4-17`);
    MacNeutron.app is `0.1.0`/`1` (`App/Info.plist:10-11`); the Rosetta runtime has `runtime-version`
    (`RuntimeInstaller.swift:100`). How does the launcher know which wine.app it has (SOURCE? DXMT/version? a new
    file?), and how are updates delivered (each DXMT update = re-notarize, `arm64-dxmt/maps.md:413`)?
13. **Quarantine/Gatekeeper.** Never mentioned in the repo (grep). A downloaded or copied wine.app exec'd by the
    launcher from Application Support: does it need its ticket stapled, and does quarantine propagate through the
    app's copy/untar?
14. **Provisioning profile lifetime.** `check_profile_plist` refuses an expired profile at build time
    (`lib.sh:68-70`); what an expired embedded profile does to an installed, already-signed wine.app at run time is
    unrecorded.
