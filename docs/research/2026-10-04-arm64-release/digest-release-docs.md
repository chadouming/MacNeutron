# SP5 interface digest: release prerequisites and documentation

Repo `/Users/chad/Documents/MacProton`, HEAD `92d8f83` (spec approved; `origin/main` tracking ref = `95f8883`, so HEAD
is **not** contained in `origin/main` today). Spec: `docs/superpowers/specs/2026-10-04-macneutron-arm64-release-design.md`
(§6, §7.2, §7.3, §13). Everything below was read locally; nothing contacted Apple. No `release/` or `tools/` directory
exists yet; no root `LICENSE`; no git tags.

---

## A. Release tools on this Mac (§6.1, §6.2, §6.3)

| Tool | Path / version | Facts the plan needs |
|---|---|---|
| `notarytool` | `xcrun notarytool`, 1.1.3 (42) | Subcommands: `store-credentials`, `submit`, `info`, `wait`, `history`, `log`. No standalone binary on PATH: always `xcrun notarytool`. |
| `notarytool submit` | | `submit [<options>] <file-path>`; `-p/--keychain-profile <name>`; `--wait/--no-wait` (default no-wait); `--timeout <duration>` (`3600`, `60m`, `1h`); `-f/--output-format normal|json|plist` (json suppresses progress, one result at the end); `--force` uploads despite pre-flight problems (never use). Also `--keychain <path>`, `--webhook`, `--s3-acceleration`. |
| `notarytool log` | | `log [<options>] <submission-id> [<output-path>]` (stdout default; always pretty JSON). Needs credentials (`-p`). |
| `notarytool history` / `info` / `wait` | | All take the same credential options; **none has an anonymous mode**: `history` needs `-p` or key/Apple-ID options and contacts Apple. Not run. |
| `notarytool store-credentials` | | `store-credentials [<profile-name>] [--apple-id … --team-id … --password …] [--key … --key-id … --issuer …] [--sync] [--validate/--no-validate] [--keychain …]`. **`--validate` is the default: it contacts Apple** to check the credentials before saving. Interactive prompts for anything omitted. |
| Keychain profile `macneutron` | absent | `security find-generic-password -s com.apple.gke.notary.tool -a com.apple.gke.notary.tool.saved-creds.macneutron` exits 44 (not found); no notary profile of any name exists. The maintainer's §6.1 step is still to do. |
| `stapler` | `/usr/bin/stapler` (also `xcrun stapler`) | `stapler staple [-q] [-v] path`, `stapler validate [-q] [-v] path`. Man page: **"stapler requires internet access to retrieve tickets when stapling or validating"**, and `validate` compares with the latest ticket from the service. One path per call; the folder containing the path must be writable; a symlink at `Contents/CodeResources` breaks staple (`wine.app` has 19 symlinks, none there: `Contents/MacOS/ntdll.so`, `Resources/bin/{regsvr32,wineboot,msidb,wineconsole,…}`). Exit codes: 0, `EX_USAGE`, `EX_NOINPUT` (no/invalid ticket, unsigned), `EX_DATAERR`, `EX_NOPERM` (revoked), `EX_NOHOST` (not notarized), `EX_CANTCREAT`. Re-signing invalidates a stapled ticket. |
| `syspolicy_check` | `/usr/bin/syspolicy_check` (**not** `xcrun`, not `/usr/sbin`) | `syspolicy_check notary-submission <bundle-path> [-v] [--json]`, `syspolicy_check distribution <bundle-path> [-v] [--json]` (`--json`: errors as JSON on stdout, rest on stderr). Takes an application bundle; `wine.app` is `CFBundlePackageType APPL`, so it qualifies. `distribution` runs Gatekeeper, XProtect and **provisioning-profile** checks. |
| `spctl` | `/usr/sbin/spctl` | `spctl --assess [-t type] [-v…] file`; man says the types are `execute|install|open` (default execute). `-t exec` is accepted (tested on Calculator.app: `accepted`, `source=Apple System`). **The verdict goes to stderr**: capture `2>&1` before matching `accepted`. |
| `ditto` | `/usr/bin/ditto` | For `-c -k --keepParent` and for nesting `wine.app` (keeps symlinks, xattrs, signature, ticket). |
| `jq` | `/usr/bin/jq` 1.7.1-apple | Ships with macOS; release.sh can read `.status`/`.id` from `--output-format json` with no new dependency (`plutil -extract status raw` also reads JSON). Do not rely on `notarytool`'s exit code alone; require `.status == "Accepted"`. |
| Signing identity | 1 valid "Developer ID Application" identity in the keychain | `MACNEUTRON_SIGN_IDENTITY` as for `make wine-arm64` (`wine-arm64/lib.sh:75-83 check_signing`). |
| Provisioning profile | only `~/Downloads/Mac_Neutron.provisionprofile` | `ExpirationDate` 2044-09-28 (decoded with `security cms -D`). `MACNEUTRON_PROVISIONING_PROFILE` is checked by `check_profile_plist` (`lib.sh:60-73`) against `APP_ID=49QMZXLR8S.net.authspot.macneutron.wine` (`lib.sh:56`). Spec §6.1 wants it moved to a stable path: nothing in code assumes `~/Downloads`. |
| OS / Xcode | macOS 27.0.1, Xcode 27.0 | |

Env var names: `MACNEUTRON_SIGN_IDENTITY`, `MACNEUTRON_PROVISIONING_PROFILE` (existing, `lib.sh:76-77`, `bundle.sh:108,116,118`,
`Makefile:145` comment); **`MACNEUTRON_NOTARY_PROFILE` is new** (default `macneutron`), referenced nowhere yet.

---

## B. The staged `licenses/SOURCE` and the source trees (§6.3 step 2, §7.2, R5)

`build/wine-arm64/wine.app/Contents/Resources/licenses/SOURCE` is byte-identical to `build/wine-arm64-src/SOURCE`
(bundle.sh copies it: `bundle.sh:70 put "$S" SOURCE "$L/"`). Keys, in order:

```
MACNEUTRON_COMMIT=96adc9a9261692e61acff4cbc36335fb3ee6ac4f      <- not HEAD (92d8f83); see flag B1
WINE_COMMIT=455e3509b98a6919fd4ad1def4803e08c41c03b2
WINE_SERIES=3a2668767a061ec86c97222f558b12df00b0f744c7514f2c7b128ed8bedc3caa
FEX_COMMIT=4ed80fd07176dce976a7351f559d59a47b68cbae
FEX_SERIES=1398dcb9fb03c8c8ec980e9c193e0ff2043e0cb001cfc65129ef60deb0df44f4
FEX_SUBMODULE_fmt=1be298e1…  FEX_SUBMODULE_range-v3=ca1388fb…  FEX_SUBMODULE_rpmalloc=1d85c246…
FEX_SUBMODULE_unordered_dense=3234af2c…  FEX_SUBMODULE_xxhash=e626a72b…  FEX_SUBMODULE_cpp-optparse=9f94388a…
DXMT_COMMIT=1fba8d25b5e29ab49012d633676a6b0d4b3b96c5
DXMT_SERIES=63a4969e01badbd44da0822dc56f0ccfea3792edd08a0db0fadafadba28839c3
LLVM_TAG=llvmorg-15.0.7
LLVM_MINGW_SHA256=d1dc5d1e…
LSTEAMCLIENT_COMMIT=db9e6ffbf24a95b104fb699dd62532c70a2f9a51
LSTEAMCLIENT_SERIES=3e73ad3a…
FREETYPE_URL / FREETYPE_SHA256, GNUTLS_URL / GNUTLS_SHA256, NETTLE_URL / NETTLE_SHA256, GMP_URL / GMP_SHA256
```

No `DXMT_SUBMODULE_*` yet. No `*_SERIES=dev`, no `+dirty` in the current file.

**Where SOURCE is written:** `wine-arm64/build.sh:331-350` (step 8), `series <mode> <hash>` at `:333` prints `dev` for a
development tree; `MACNEUTRON_COMMIT=$mac` from `:143-145` (`git rev-parse HEAD`, `+dirty` when
`git status --porcelain --untracked-files=normal -- wine-arm64 dxmt bridge Makefile` is non-empty; **`presenter` is
not in that pathspec yet**, §5.3 adds it). FEX submodule lines: `build.sh:340-342` (awk over `git submodule status`,
keeps the 6 names). Up-to-date exit without rewriting SOURCE: `build.sh:153-161`. Series hashes: `build.sh:105-108`
(`series_of` = `lib.sh:43-45`, sha256 of pins + patch files with the identity blanked; `lsteamclient_series` =
`lib.sh:49-54`, `deps.pins`' `LSTEAMCLIENT_` lines + patches). Tree modes: `build_mode` `lib.sh:23-35`
(`pinned|applied|development|reapply`); patching: `patch_tree` `build.sh:51-58` (`git am` each patch, writes
`<tree>.applied` = HEAD and `<tree>.series`).

### Per tree (all read-only checks, `GIT_NO_LAZY_FETCH=1`)

| Tree (`build/wine-arm64-src/…`) | SOURCE keys | HEAD (= `<t>.applied`) | Pin relation | Shallow | Partial clone | Submodules | Blobs for `git archive HEAD` |
|---|---|---|---|---|---|---|---|
| `wine` | `WINE_COMMIT`, `WINE_SERIES` | `dd92a4b` | `HEAD~19 == WINE_COMMIT` (19 patches) | yes (20 commits) | no | none | all 12,463 present; tree clean |
| `fex` | `FEX_COMMIT`, `FEX_SERIES`, `FEX_SUBMODULE_*` | `4adb8a1` | `HEAD~5 == FEX_COMMIT` | yes | no | **16 initialised** (`--recursive`, `build.sh:76`); SOURCE names 6; only those 6 appear in `fex-ec`'s build files | all present; 16 gitlinks |
| `fex/External/{fmt,range-v3,rpmalloc,unordered_dense,xxhash}`, `fex/Source/Common/cpp-optparse` | `FEX_SUBMODULE_<name>` | = recorded commit | — | yes (each) | no | `range-v3` has a nested `doc/gh-pages` gitlink (docs; empty in an archive, fine) | present; `git archive HEAD \| git get-tar-commit-id` on `fmt` → `1be298e…` = key |
| `dxmt` | `DXMT_COMMIT`, `DXMT_SERIES` | `f37f657` | `HEAD~1 == DXMT_COMMIT` | yes | no | 2: `external/nvapi` `d08488f…`, `include/native/directx` `9df86f2…` (`.gitmodules` URLs: NVIDIA/nvapi, misyltoad/mingw-directx-headers) | present; `git archive HEAD \| git get-tar-commit-id` → `f37f657…` (works on shallow) |
| `lsteamclient` | `LSTEAMCLIENT_COMMIT`, `LSTEAMCLIENT_SERIES` | `03fae36` | `HEAD~3 == LSTEAMCLIENT_COMMIT` | yes | **yes**: `remote.origin.promisor=true`, `partialclonefilter=blob:none`, `core.sparseCheckout=true` (patterns `/lsteamclient/`, `!/lsteamclient/steamworks_sdk_*/`, `!/lsteamclient/gen_wrapper.py`) | none | **only 276 of 3,133 blobs local** (`git ls-files -t`: 276 `H`, 2,857 `S`); the 276 are exactly `lsteamclient/` minus `steamworks_sdk_*` (91 dirs) and `gen_wrapper.py`; worktree has nothing untracked or ignored |
| repo | `MACNEUTRON_COMMIT` | `92d8f83` | — | no | no | none (no gitlinks, no `.gitattributes`) | 342 tracked files; `.claude/` untracked |
| tarballs `build/wine-arm64-src/{freetype-2.14.3.tar.xz, gnutls-3.8.13.tar.xz, nettle-4.0.tar.gz, gmp-6.3.0.tar.xz}` | `*_URL`, `*_SHA256` | — | sha256 match SOURCE (checked) | — | — | — | 2.7 MB, 7.3 MB, 2.6 MB, 2.1 MB |
| LLVM 15 (`build/dxmt-src/llvm-project`, shallow at `LLVM_TAG`; cloned by `dxmt/llvm.sh:8-11`) and llvm-mingw | `LLVM_TAG`, `LLVM_MINGW_SHA256` | — | cited only | | | | not archived (§7.2) |

Sizes on disk (with .git): wine 488 MB, fex 1.5 GB, dxmt 34 MB.

### Flags for §7.2 / R5

- **B1. SOURCE lags HEAD; §6.3 step 2's "`MACNEUTRON_COMMIT` equal to HEAD" fails after any commit that doesn't change
  a build input.** `build.sh:153-161` exits "up to date" when the stamp matches and SOURCE has no `+dirty`, without
  rewriting SOURCE. Live example: staged `96adc9a`, HEAD `92d8f83` (two docs-only commits). §5.2 says
  `bundle.sh --release` "reads the existing build tree", i.e. copies this stale file. Fix options (pick one in the
  plan): (a) in release mode `bundle.sh` writes its own SOURCE with `MACNEUTRON_COMMIT=$(git rev-parse HEAD)` after
  release.sh's step 1 proved the tree clean and every tree `applied` with a matching stamp (truthful: the stamp covers
  every repo input of `wine.app`); simplest is to move the SOURCE block (`build.sh:333-350`) into a `lib.sh` function
  `write_source <out> <mac>` that both call; or (b) make the up-to-date check also compare SOURCE's
  `MACNEUTRON_COMMIT` with HEAD (re-bundles after every commit, 1.3 GB re-sign; not recommended).
- **B2. The spec's lsteamclient command does not work.** Run read-only:
  `GIT_NO_LAZY_FETCH=1 git -C build/wine-arm64-src/lsteamclient archive --format=tar HEAD -- lsteamclient/ ':(exclude)lsteamclient/steamworks_sdk_*' ':(exclude)lsteamclient/gen_wrapper.py'`
  → `fatal: could not fetch 61e77ac… from promisor remote` (that blob is `.github/ISSUE_TEMPLATE/compatibility-report.md`,
  outside the pathspec). `git archive HEAD:lsteamclient -- ':(exclude)…'` also fails, on `gen_wrapper.py` (excluded).
  Even `git archive HEAD -- lsteamclient/LICENSE` fails the same way. Git 2.54 (Apple Git-157) reads blobs before it
  applies the pathspec, so in this blob-less clone it either fails offline or, with lazy fetching on, downloads
  Proton blobs one by one from GitHub (the very `steamworks_sdk_*` content the archive must exclude). Workable
  replacement: since `build_mode` = `applied` proves the tree clean and HEAD = `lsteamclient.applied`, and the sparse
  worktree holds exactly the 276 wanted files with nothing untracked, archive the **worktree**:
  `tar -C build/wine-arm64-src/lsteamclient -czf … lsteamclient` (or `git ls-files -t` `H` entries fed to
  `tar -T`), and record the commit beside it (no `git get-tar-commit-id` for this one). R5 then checks the file list
  and blob hashes against `git ls-tree -r HEAD -- lsteamclient/` minus the exclusions, plus `HEAD~3 == LSTEAMCLIENT_COMMIT`.
- **B3. `git get-tar-commit-id` names the applied commit, not `*_COMMIT`.** For every patched tree the archive's
  commit id is HEAD (the local `git am` commit: `dd92a4b`, `4adb8a1`, `f37f657`), dated at patch time and not
  reproducible elsewhere; `*_COMMIT` is `HEAD~N`. R5 as written ("matches its `*_COMMIT` … (`git get-tar-commit-id`)")
  can't pass. R5 should check: tar commit id == `<tree>.applied`; in the build tree `git rev-parse HEAD~N == *_COMMIT`
  with N = number of `wine-arm64/patches/<t>/*.patch` (19 / 5 / 1(+1 with §5.3's 0002) / 3); `series_of` /
  `lsteamclient_series` recomputed from the repo archive's pins and patches == `*_SERIES`. Submodule archives do
  round-trip (`fmt` → its `FEX_SUBMODULE_fmt`). Optionally add `<T>_APPLIED=<sha>` keys to SOURCE so R5 is checkable
  from the archive alone.
- **B4. `DXMT_SUBMODULE_*` is new work.** Copy `build.sh:340-342`'s awk for `git -C "$D" submodule status`; the
  basename rule gives `DXMT_SUBMODULE_nvapi` and `DXMT_SUBMODULE_directx`. Add both to `licences_test.sh`'s key list
  (`wine-arm64/tests/licences_test.sh:70-73`). `build.sh`, `licences_test.sh` and `licenses/README` are stamp inputs
  (`build.sh:110-115`), so these edits force a rebuild/rebundle — expected.
- **B5. FEX archive scope:** archive exactly the six SOURCE submodules (the other ten — Catch2, Vulkan-Headers,
  drm-headers, the three `*-tests-bins`, jemalloc_glibc, tracy, vixl, zydis — are initialised but unused by the
  arm64ec/unixlib builds; `licences_test.sh:37-42` already forbids them in `fex-ec/External`).
- Wine: `.git/info/exclude` holds `/dlls/lsteamclient` and `dlls/lsteamclient` is a symlink into the lsteamclient tree
  (`build.sh:139-142`); `git archive HEAD` won't include it (correct: lsteamclient is its own archive entry).
- The repo archive is plain `git archive --prefix=MacNeutron/ HEAD` (no submodules, no export-ignore). Note
  `wine-arm64/licenses/README:6` points readers to `https://github.com/chadouming/MacNeutron` at `MACNEUTRON_COMMIT`
  (origin is `git@github.com:chadouming/MacNeutron.git`): that commit must be pushed (step 1's `origin/main` check) and
  the repo public at publication, or the pointer should name the source archive instead.

---

## C. §6.3 step 1 inputs in today's code

- **Clean repo / HEAD in `origin/main`:** today HEAD `92d8f83` ∉ `origin/main` (`95f8883`), and the tree has an
  uncommitted spec edit: step 1 refuses now (expected). The check is only as fresh as the tracking ref: release.sh must
  `git fetch origin` (network, GitHub) or say it trusts the local ref.
- **"`make wine-arm64` reporting all four trees applied and up to date":** `build.sh` prints only `wine-arm64: up to
  date` (`:158`) or `wine-arm64: development build` (`:149`); no per-tree report. Cheapest exact check: release.sh
  sources `wine-arm64/lib.sh` and calls `build_mode <tree> <applied> <series-file> <series>` for wine, fex, dxmt and
  lsteamclient (series from `series_of`/`lsteamclient_series` as at `build.sh:105-108`), requiring `applied` for each,
  then runs `sh wine-arm64/build.sh` and requires the `up to date` line. Naming each failing tree is what R1 wants.
- **`DXMT_COMMIT` published:** `dxmt/published.sh <clone> <commit>` (whole file, 9 lines) runs
  `git -C <clone> fetch -q origin macneutron` then `merge-base --is-ancestor <commit> FETCH_HEAD`; messages
  `dxmt: can't reach the fork…` / `dxmt: <c> isn't on the fork's macneutron branch; push it before shipping (LGPL)`.
  Only caller: `Makefile:98` with `build/dxmt-src/dxmt` and `$(cat build/dxmt/version)` — **both produced only by
  `make dxmt` (`dxmt/build.sh:46`), which §8.2 deletes**. release.sh must pass `DXMT_COMMIT` from `dxmt/pins:4` and a
  clone that survives: `build/wine-arm64-src/dxmt` works (shallow, origin = the fork; `fetch origin macneutron` adds
  objects and `refs/remotes/origin/macneutron`/`FETCH_HEAD` but leaves `build_mode` = `applied`), or a throwaway clone
  under `build/release/`. Note `dxmt/pins:2` says `DXMT_COMMIT` "is the head of the fork's `macneutron` branch".
  `published.sh`'s header comment ("`make app` runs it") must change.
- **VERSION:** `git tag -l "v$V"` (no tags exist) plus `^[0-9]+\.[0-9]+\.[0-9]+$`. The Makefile has no `VERSION`
  variable and no `release` target; `.PHONY` is `Makefile:1`.
- Use `LC_ALL=C /usr/bin/grep` in release.sh (the interactive `grep` is a ugrep wrapper that can return 0 silently).

## D. Other release inputs

- `App/Info.plist`: `CFBundleShortVersionString 0.1.0`, `CFBundleVersion 1`, **`LSMinimumSystemVersion 26.0`** (→ 27.0,
  §3.11/§6.3 step 3), `CFBundleIdentifier io.github.chadouming.MacNeutron`, `LSUIElement true`.
- `wine-arm64/Info.plist`: 6 keys (`CFBundleIdentifier net.authspot.macneutron.wine`, `CFBundleExecutable wine`,
  `CFBundleName Wine`, `CFBundlePackageType APPL`, `CFBundleInfoDictionaryVersion 6.0`, `LSMinimumSystemVersion 27.0`);
  no `CFBundleShortVersionString`/`CFBundleVersion` (§5.1 adds them at bundle time; the file is a stamp input).
- `wine.app` top level: `Info.plist MacOS Resources _CodeSignature embedded.provisionprofile`; 1.3 GB; carries
  `com.apple.provenance`. Stapling adds a ticket file at `Contents/CodeResources` (outside `_CodeSignature`); R0 should
  record that `codesign --verify --strict` and the §5.1 identity (loader CDHash) are unchanged after staple, since
  §3.9 compares identities of the stapled source and the installed copy.
- `Makefile:86-104` (`app`): ad hoc, `presenter` dylib into `Frameworks/`, `published.sh`, x86_64 DXMT into
  `Resources/DXMT` and `Frameworks/DXMT`: all replaced per §8.2; `release.sh` does its own Developer ID build (§6.3 step 3).
- `wine-arm64/tests/licences_test.sh` (99 lines): `check <wine.app> <build dir>` (`:10-74`), usage
  `licences_test.sh [--self-test] <wine.app>` (`:76-82`), self-test `red` (`:86-99`). File list `:19-30` lacks
  `licenses/macneutron/LICENSE` (§7.1); lsteamclient block `:61-64`; key list `:70-73`. §7.1's app mode is new.
- `wine-arm64/licenses/README:69-76` lsteamclient entry; `:72-73` is the "Whether a release bundle may include it is
  not decided yet (ship-base spec §1): this bundle is a local build." text §7.1 replaces; no MacNeutron entry yet.

---

## E. Documentation (§7.3)

### `README.md` (129 lines) headings

`1 # MacNeutron` · `13 ## Build and test` · `36 ## The app` · `48 ## Install the runtime from the command line` ·
`58 ## Per-game options` · `77 ## Graphics` · `114 ## Steam API` · `123 ## Upscaling`. No download, setup, requirements
or Licence section.

### `README.md` lines §7.3 changes

| Line(s) | Today | Change |
|---|---|---|
| 3-4 | "…translated by Wine and DXMT (Apple's D3DMetal optional, per game)." | drop D3DMetal |
| 6-8 | **Status:** Rosetta runtime, "(x86_64 Wine under Rosetta 2)"; arm64 "in development", "sub-project 5 … is next" | release status (0.1.0, arm64 only). **`Rosetta 2` literal (refusal string)** |
| 10-11 | **Requirements:** "macOS 26 or later, Rosetta 2, Xcode 27"; arm64 needs macOS 27 + Developer ID | macOS 27, Apple Silicon, Steam; no Rosetta (player); building needs Xcode 27 + `wine-arm64/README.md`'s Developer ID setup (no ad-hoc `wine.app`). **`Rosetta 2` literal** |
| 15-23 | `make dxmt` (19), `make dxmt-check … (needs GPTK imported)` (20) | `make dxmt` gone (§8.2); `dxmt-check` needs the frozen reference; add `make release VERSION=…` |
| 25-28 | arm64 runtime capabilities paragraph | keep, reword as the shipped runtime |
| 29-30 | `wine.app` licences; FreeType credit line | keep (FreeType credit is a licence requirement) |
| 32-34 | "`make dxmt` and `make app` need cmake ninja meson + Metal Toolchain" | `make app` now builds `wine.app` and needs the signing variables (§8.2) |
| 39 | `make app … ad-hoc signed, with the CLI and steam.exe inside (needs brew install mingw-w64)` | app embeds `Contents/Helpers/wine.app`; needs `MACNEUTRON_SIGN_IDENTITY`/`…PROVISIONING_PROFILE` |
| 43-46 | setup: "install the runtime, optionally import Apple's Game Porting Toolkit (drop its `.dmg`), then turn on Steam Play mode" | requirements → runtime (automatic) → Steam Play mode; add download/unzip/move-to-Applications (App Translocation, §12) |
| 48-56 | section "Install the runtime from the command line": `install-runtime` (51), `import-gptk` (52), `install-dxmt` (53), "never ships Apple's files; `import-gptk` copies D3DMetal" (56) | replace with `macneutron install --tool-dir <dir> --wine-app <path>`; **must not name `import-gptk`** even as "replaces" (refusal string) |
| 67 | `MACNEUTRON_GRAPHICS=d3dmetal\|dxmt\|dxvk` | `dxmt\|wined3d` |
| 69 | `MACNEUTRON_NO_AVX=1` row | delete |
| 68, 70-75 | LOG, NO_MSYNC, NO_STEAM_BRIDGE, NO_METALFX, DXMT_D3D12_SM6, DXMT_D3D12_OVERLAP, MACNEUTRON_PRECACHE | keep (§7.3 lists only the MACNEUTRON_ ones; the DXMT_*/PRECACHE rows still apply on arm64) |
| 79-82 | DXMT licences "in `MacNeutron.app/Contents/Resources/DXMT`", fork commit "in the tool folder's `dxmt-version`" | now `wine.app/Contents/Resources/DXMT/{COPYING.LIB,LICENSE,LICENSE.OLD,version}`; `dxmt-version` removed (§3.1) |
| 86-87 | "import GPTK and set **Graphics: D3DMetal** … `MACNEUTRON_GRAPHICS=d3dmetal`" | fallback becomes `wined3d` (Direct3D 9-11 only) |
| 89-112 | pre-caching, overlap, DXMT_* knobs | keep |
| 116-118 | bridge "built for macOS by the runtime" | add: ships under Valve's Steamworks SDK licence (`licenses/lsteamclient/`) |
| 120-121 | SteamID warning | keep |
| new | — | 32-bit and Direct3D 9 games unsupported in 0.1; `~/Library/Caches/MacNeutron/runtime-v*.tar.gz` can be deleted (§3.1); profile expiry note (§12); a **Licence** section (MacNeutron MIT; patch folders' licences per §1) |


### `wine-arm64/README.md` (241 lines)

Headings: `1 # wine-arm64…` · `20 ## Requirements` · `48 ## Build and check` · `107 ### FreeType and gnutls` ·
`121 ### The Steam bridge` · `137 ## Layout` · `151 ## Development loop` · `183 ## Next Wine rebase` · `199 ## Licences`.

| Line(s) | Text | Named by §7.3? |
|---|---|---|
| 17-18 | "This is a development build for sub-projects 1 to 3. The shipped runtime is still the Rosetta one (`make dxmt`, the app)." | **yes** |
| 224-225 | "Whether a release bundle may include it is decided in sub-project 5; until then MacNeutron doesn't redistribute it (local builds only)." | **yes** (refusal string `doesn't redistribute`, on line 225 alone) |
| 63-64 | "Gate G4's Rosetta baseline runs MacNeutron's installed runtime-v4.7.3 (`MACNEUTRON_TOOL` names another tool folder)" | **yes** (Rosetta-baseline prerequisites → frozen reference, `MACNEUTRON_REFERENCE`) |
| 68-70 | "**GPTK imported** and MacNeutron's runtime-v4.7.3 installed with its tarball cached…" | **yes** |
| 101-102 | "The lanes compare our DXMT with D3DMetal on the installed Rosetta runtime … runtime-v4.7.3 … GPTK imported." | **yes** |
| 55, 59-62 | `make … dxmt dxmt-tests presenter dxmt-tests-arm64ec`; "`make dxmt …`: our Rosetta DXMT" | not named; stale after §8.2 (`make dxmt` deleted) |
| 65-66 | "`WINEMSYNC=1`, as on the Rosetta runtime" | not named; reword |
| 7 | "msync (on wherever `WINEMSYNC=1` is set: `check.sh`, later the launcher)" | not named; stale after §3.7 |
| 125-126 | "Copying the DLL into game prefixes is the launcher's, later (sub-project 5)." | not named; stale after §3.5 |
| 165-166 | "`dxmt/pins`' `DXMT_COMMIT` (the Rosetta stack's pin; `build/dxmt-src/dxmt`, that stack's clone, is never touched)" | not named; stale after §8.2 |

No line in `wine-arm64/README.md` contains `Rosetta 2` or `import-gptk` today.

### Refusal strings (§7.3 last bullet, R1)

Today's hits: `README.md:6,10` (`Rosetta 2`), `README.md:52,56` (`import-gptk`), `wine-arm64/README.md:225`
(`doesn't redistribute`, ASCII apostrophe). Match with `LC_ALL=C /usr/bin/grep -nF`. **Spec tension:** §7.3 asks the
README to say "no Rosetta" and to present `install` "instead of `install-runtime`/`import-gptk`/`install-dxmt`"; the
first is safe ("no Rosetta" ≠ `Rosetta 2`), the second must not name `import-gptk`. §8.1's frozen-reference prose in
`wine-arm64/README.md` must likewise avoid the literal `Rosetta 2`.

---

## F. §13 amendments: exact targets

### Native arm64 spec (`docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md`, 481 lines)

| Spec §13 item | Line | Current text (abridged) |
|---|---|---|
| §1 decisions | **47** | `\| When a game switches \| Per game. A 64-bit D3D11/12 game moves once it runs on the arm64 stack at ≤ ~1.4× the CPU cost it has under Rosetta. 32-bit and D3D9 games stay on Rosetta until their own sub-projects land \|` (§13 quotes it paraphrased) |
| also asserting the superseded position (not named in §13) | 22 | Scope Out: "the Rosetta runtime stays the only shipped runtime until sub-project 5" |
| same | 39 | "A game's switch is decided per game from that game's own measurements (sub-project 9), not by G4." |
| status line (optional) | 4 | `- **Status:** Approved 2026-10-03. Sub-project 1 implemented … Sub-projects 2 and 3 are done too (§2).` |
| §2 row 5 | **65** | `\| 5 \| **Launcher: a second runtime** \| 3 \| Per-game runtime choice, separate prefixes, preflight split; …` — title and first clause contradict arm64-only; rename + point to the SP5 spec |
| §2 row 6 | **66** | SMITE 2 parity and measurements → "planned, gate nothing" |
| §2 row 7 | **67** | `**Direct3D 9** (optional, can start now on Rosetta)` → "restore Direct3D 9" |
| §2 row 8 | **68** | `**32-bit games**` → "restore 32-bit support" |
| §2 row 9 | **69** | `**Per-game cutover** … then delete GPTK, DXVK, the AVX switch and the Rosetta preflight` → folded into row 5 |
| §11 | **476** | `  - Notarization of a bundle with it is unverified (sub-project 5).` → points to R0 |
| (G4 table, mentions GPTK) | 433 | not named; G4 baseline moves to the frozen reference (§8.2) |

### Status lines ("Superseded in part by …") — the six §13 names, all with `- **Status:**` at line 4

| File | Line 4 today |
|---|---|
| `2026-09-27-macproton-runtime-design.md` | `- **Status:** Draft for review` |
| `2026-09-27-macneutron-app-design.md` | `- **Status:** Draft for review` |
| `2026-09-28-macneutron-metalfx-design.md` | `- **Status:** Approved 2026-09-28; stopped at the feasibility gate (§9) … Not implemented.` |
| `2026-09-28-macneutron-metalfx-upscaler-design.md` | `- **Status:** Draft for review` |
| `2026-09-28-macneutron-steam-bridge-design.md` | `- **Status:** Approved 2026-09-28; amended the same day (see "Amendment")` |
| `2026-09-28-macneutron-dxmt-fork-design.md` | `- **Status:** Draft for review` |

Specs **not** in §13's list that still describe removed pieces (grep `install-runtime|import-gptk|install-dxmt|GPTK|runtime-v4`
plus `Rosetta|make dxmt`): `2026-09-29-macneutron-d3d12-stubs-design.md:41` (D3DMetal from GPTK as evidence),
`2026-09-29-macneutron-dxil-translator-design.md:34` (D3DMetal reference, GPTK imported),
`2026-09-30-macneutron-pipeline-cache-design.md:277,301` (GPTK backend; `install-dxmt build/dxmt`),
`2026-10-03-macneutron-arm64-dxmt-design.md:180` (GPTK/runtime tarball for the reference),
`2026-10-01-macneutron-gpu-overlap-design.md` (4 Rosetta/`make dxmt` hits), `2026-10-02-macneutron-gpu-efficiency-design.md`
(3), `2026-10-04-macneutron-ship-base-wine-design.md` (9 Rosetta mentions, e.g. its lsteamclient decision §1 now
superseded by SP5 §1). Decide whether they get the same status line; the plan otherwise leaves them.
`docs/superpowers/plans/*` and `docs/research/*` hits are historical working notes: leave.

### Acceptance records (`docs/testing/`, no status lines today; title at line 1, "Spec:"/"Manual" at line 3)

All 13 match the grep. **Rosetta-era (the "Historical:" line):** `acceptance-app.md`, `acceptance-bridge.md`,
`acceptance-dxmt-d3d12-stubs.md`, `acceptance-dxmt-fork.md`, `acceptance-dxmt-gpu-efficiency.md`,
`acceptance-dxmt-gpu-overlap.md`, `acceptance-dxmt-pipeline-cache.md`, `acceptance-metalfx.md`, `acceptance-runtime.md`,
`acceptance-upscaler.md` (10).
**arm64 records** (`acceptance-arm64-wine.md`, `acceptance-arm64-dxmt.md`, `acceptance-arm64-ship-base.md`) are not
Rosetta-era but their reproduce steps name runtime-v4.7.3/GPTK for baselines (2-3 hits each): §13's wording
("Rosetta-era records") excludes them; the plan should either give them a one-line "baselines now come from the frozen
reference" note or leave them, explicitly.

---

## G. Spec items the code makes awkward (summary)

1. §6.3 step 2 `MACNEUTRON_COMMIT == HEAD` vs `build.sh:153-161` (SOURCE not rewritten on up-to-date): B1.
2. §7.2 lsteamclient `git archive` command fails offline in the blob-less clone (Git 2.54 reads blobs before the
   pathspec): B2; archive the clean sparse worktree instead.
3. §7.2 / R5 "`git get-tar-commit-id` names the commit" = the applied commit, not `*_COMMIT`: B3.
4. §6.3 step 1 `published.sh` depends on `build/dxmt-src/dxmt` + `build/dxmt/version`, both from the deleted `make dxmt`: C.
5. §6.3 step 1 "make wine-arm64 reporting all four trees applied" — no per-tree output exists; use `lib.sh build_mode`: C.
6. §6.3 step 1 "HEAD contained in `origin/main`" needs a fresh fetch (network) to mean anything: C.
7. `stapler validate` and `store-credentials` (default `--validate`) are online; L6/R2's `stapler validate` is an online
   check, only R0's launchd run proves the offline Gatekeeper path.
8. §7.3 asks the README to mention the replaced verbs; the refusal list forbids `import-gptk` in it: E.
9. §13's status-line list omits several specs that describe GPTK/`install-dxmt` flows: F.
10. §5.3 adds `presenter` to the `+dirty` pathspec at `build.sh:144`; until then a presenter edit wouldn't mark SOURCE dirty.
