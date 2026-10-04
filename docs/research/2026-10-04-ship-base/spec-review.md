## facts
# Sceptic re-check (facts lens): Ship-base Wine spec

All 14 findings survive; none is fully refuted. Three needed corrections:
- Finding 7 is downgraded to PLAUSIBLE, and the mechanism it named was wrong.
- The alternative fix proposed in Finding 1 would never fire.
- Finding 6 is reframed: it is a coverage gap first, and the letter case second.

I add three new findings. N1 is the most serious item in this review: S2 cannot pass as written.

Some evidence comes from a scratch deps build that an earlier reviewer left in `sp3-review/` (the tarballs, `deps/lib/*.dylib` and the build logs). I did not build it. I checked the four tarballs: their SHA-256 values match the spec's pins exactly, and I then inspected the built files read-only.

## Findings, most serious first

### N1. The x18 gate in §5 fails on gnutls 3.8.13, so S2 can't pass (CONFIRMED, new)
- **Where:**
  - §5 (spec:115): "no x18 use in either dylib (the regex of … `x18-cache-scan.sh` over `otool -tV`)".
  - §10: "x18 instructions in a bundled dylib | `bundle.sh` stops".
- **Problem:** gnutls contains data blocks inside its code section, and `otool -tV` disassembles them as if they were instructions. The regex matches them. Every gnutls 3.8.13 build therefore stops `bundle.sh`.
- **Evidence:**
  - I ran the regex from `x18-cache-scan.sh:12` over `otool -tV` of both the scratch-built `sp3-review/deps/lib/libgnutls.30.dylib` and Homebrew's `/opt/homebrew/opt/gnutls/lib/libgnutls.30.dylib`. Each gives the same 7 hits:
    - `gcm_ghash_v8_4x`: `stnp s13, s29, [x18, #-0x40]`;
    - `_sha256_block_data_order` ×3 and `_sha512_block_data_order` ×3, for example `ldrb w27, [x18, #0x5b0]`.
  - Every hit falls after the routine's last `ret` (0xc77b8 and 0xc4d80 in the scratch build).
  - The words that follow are `.long 0x428a2f98`, which is SHA-256's first round constant K[0], and `.long 0x53414847` / `0x474f5450`. Those are ASCII from the "GHASH for ARMv8, CRYPTOGAMS" ID string. So these are constant tables and an ID string, not code.
  - Homebrew's nettle, hogweed, gmp and freetype each give 0 hits.
  - This refutes the brief's "[V] Homebrew's builds of the same versions scan at 0 x18 instructions" (brief §1, line 39), and the other reviewer's "holds" line that says gnutls scans at 0.
- **How the wrong count arose:** in this session, plain `grep` is a shell function (rtk). It printed 0 for the same input on which `/usr/bin/grep` finds the hits.
- **Fix:**
  - Change the gate from "zero hits" to "every hit classified".
  - Commit an allowlist, for example `wine-arm64/x18-allow.txt`, with one line per dylib, routine and count, covering these 3 CRYPTOGAMS routines with the reason "data after `ret`". Any other hit, or a changed count, fails the build.
  - Scans must call `/usr/bin/grep`.
  - Correct brief §1 to match.
  - Building gnutls with `--disable-hardware-acceleration` would also remove the hits, but it gives up the ARMv8 AES-GCM and SHA speed for TLS.

### 1. S1 can pass with no nettle, gmp or libunistring licence texts (CONFIRMED; fix corrected)
- **Where:**
  - §4 (spec:89): "each bundled third-party dylib has its folder".
  - §1 (spec:41): nettle, hogweed and gmp are folded into `libgnutls.30.dylib`.
- **Evidence:**
  - `licences_check.sh:43-44` only checks for the nettle and gmp folders when a `libnettle*` or `libgmp*` dylib is present. Under the chosen packaging, neither file will exist.
  - For gnutls, line 42 asks only for `COPYING.LESSERv2`. That leaves out the LGPLv3 and GPLv3 texts that the libunistring election in §1 needs.
  - `find wine.app -name '*.dylib'` finds nothing today.
- **Correction to the other reviewer's alternative fix:** triggering on `nm -gU` finding nettle or gmp symbols would never fire.
  - In the scratch build, `nm -gU libgnutls.30.dylib` finds 0 `_nettle_` or `___gmp` symbols.
  - `nm` without `-gU` finds 653 of them as local (`t`) symbols.
- **Fix:**
  - Base the licence requirement on the pins and the §1 elections, not on which dylibs exist.
  - Shipping `libgnutls` should require `gnutls/COPYING.LESSERv2`, plus `nettle/` and `gmp/` with `COPYING.LESSERv3` and `COPYINGv3`.
  - All of these texts are in the tarballs. I confirmed them in the extracted trees: nettle-4.0 and gmp-6.3.0 both have `COPYING.LESSERv3` and `COPYINGv3`.

### 2. "The 8 allowlisted externals" means two different sets (CONFIRMED)
- **Where:** §4 (spec:83, 88, 89).
- **Evidence:**
  - `ls build/wine-arm64-src/fex-ec/External` gives `SoftFloat-3e cephes fmt range-v3 rpmalloc tiny-json unordered_dense xxhash`.
  - `ninja -t query Bin/libarm64ecfex.dll` shows the DLL links `Source/Common/cpp-optparse/libcpp-optparse.a`, which is outside `External/`.
  - `git -C build/wine-arm64-src/fex submodule status` shows only 6 of §4's 8 as submodules: fmt, range-v3, rpmalloc, unordered_dense, xxhash and `Source/Common/cpp-optparse`. cephes, tiny-json and SoftFloat-3e are part of FEX's own tree.
  - `licences_check.sh:35` already uses the correct directory set.
- **Problem:** if the allowlist is taken from §4's licence list, the build fails on SoftFloat-3e and the drift gate never sees cpp-optparse.
- **Fix:**
  - Name the drift allowlist as the `fex-ec/External` set above, and keep the licence-file list separate.
  - Also gate the link inputs that come from outside `External/`, using that `ninja -t query`.
  - In SOURCE, record "6 submodule commits; the rest are covered by `FEX_COMMIT`".

### 3. §4's SOURCE key list omits MacNeutron's commit, so S1 stays red (CONFIRMED)
- **Where:** §4 (spec:88), "each pin (Wine, FEX …, DXMT, LLVM, llvm-mingw, the four tarballs …)".
- **Evidence:**
  - `licences_check.sh:49` requires `MACNEUTRON_COMMIT`.
  - Running the check today prints `MISSING SOURCE line MACNEUTRON_COMMIT=` among its 37 MISSING lines, and it exits 1.
  - Brief §2 (line 107) includes MacNeutron in the SOURCE list. It is the key that ties the published patches to the binary.
- **Fix:** add MacNeutron's commit to the SOURCE list in §4.

### 4. One of the "three additions" is already in `x18-boundaries.md` (CONFIRMED)
- **Where:**
  - §2 (spec:61), "Three sites `x18-boundaries.md` lacks: `__wine_syscall_dispatcher_return` reads x18 while OFF";
  - §8 (spec:149), "missed the three additions";
  - §13 item 6;
  - the native spec's amended §5.3: "missed three sites, `__wine_syscall_dispatcher_return`'s x18 read".
- **Evidence:**
  - `x18-boundaries.md:43` says "`:1885`: read the TEB from `[sp,#0x90]` instead."
  - `git show wine-11.19:dlls/ntdll/unix/signal_arm64.c` lines 1884-1885 are `__ASM_GLOBAL_FUNC( __wine_syscall_dispatcher_return,` followed by `"ldr w11, [x18, #0x380]"`.
  - In the patched tree the same lines are 1892-1893. The brief's ":1893" is therefore the same line plus 8.
- **Fix:**
  - Say "two additions" (passing `brk #1` through, and the invariant check) in §2, §8, §13 item 6 and the native spec §5.3.
  - Re-justify the 110–140 line estimate, or re-estimate it.

### 5. The two WINEMSYNC mismatch directions print different messages (CONFIRMED)
- **Where:** §6 (spec:132), "exits non-zero with msync's own message"; §10.
- **Evidence** (`cx/wine1117:dlls/ntdll/unix/msync.c`):
  - A `WINEMSYNC=0` client facing an msync server prints "Server is running with WINEMSYNC but this process is not…" and exits (lines 636-650; the ERR is at line 648).
  - A `WINEMSYNC=1` client facing a plain server prints "Failed bootstrap_look_up for wine-…-msync" and exits (lines 690-694).
  - Upstream's `DECL_HANDLER(get_inproc_alert_fd)` (`server/thread.c:2382`) returns `STATUS_INVALID_PARAMETER` when there is no in-process fd. That is why the first direction only fires against an msync server.
  - Brief §3 names only the first message.
- **Fix:** have the mode rows test both directions and name each one's message.

### 6. The §2 heading says "verified unless marked", but several bullets are unmarked inferences (CONFIRMED)
- **Where:** the §2 heading (spec:52).
- **Unmarked inferences:**
  - "Bundling works": probe A was ad hoc, hardened runtime, with disable-library-validation. Carrying that over to Developer ID signing is an inference (brief §10 claim 1).
  - "a library that uses it breaks": the brief marks this [I] (line 39).
  - "an invariant check makes a missed ON site loud": the brief calls it "an untested proposal [I]" (line 225).
  - "the 7 touched files compile with -Wall": the run was `-fsyntax-only`, and the trial diff touches 15 files (`grep -c '^diff --git'`), 7 of them `.c`.
  - "works across two hardened-runtime processes": tested on an ad-hoc 16K process and a 4K Rosetta client, not on the entitled 4K `wine.app` (claim 5).
  - The MAP_JIT bullet: the probes ran unentitled with 16K pages (brief line 186).
- **Fix:** mark each of these [I] or "unentitled/ad hoc", and write "pass `-Wall -fsyntax-only`".

### 7. `fonts-tls` never reaches the crypt32 or dwrite loads (CONFIRMED)
- **Where:** §5 (spec:118).
- **Evidence:**
  - `secur32/Makefile.in:5` lists crypt32 under `DELAYIMPORTS`.
  - `acquire_credentials_handle` (`schannel.c:678-760`) calls no crypt32 function when no auth data is passed.
  - Nothing in the program loads dwrite.
  - So `crypt32/unixlib.c:111` and `dwrite/freetype.c:118` never run in this step.
  - Even if crypt32 loaded, its message is lowercase ("failed to load libgnutls…", `unixlib.c:113`), and the case-sensitive pattern would miss it.
- **Fix:**
  - Either add a PFX-import row (the brief's optional one) and a `DWriteCreateFactory` row, or state that these two load sites are covered only by the symbol asserts.
  - Match the failure text with `grep -i`.

### 8. The x18 scans match comment text, and the static check names only "the dispatcher" (CONFIRMED)
- **Where:** §8 (spec:154) and §5 (spec:115).
- **Evidence:**
  - The scan regex matches today's `ntdll.so` at 0x2e0f8 in `_segv_handler`, on a literal-pool comment: `" x16=%016lx x17=%016lx x18=%016lx…"`.
  - The real x18 users are 4 routines: `___wine_syscall_dispatcher`, `___wine_unix_call_dispatcher`, `_call_user_mode_callback` and `___wine_syscall_dispatcher_return`.
  - §8's "the dispatcher, callback and dispatcher-return routines" leaves out the unix-call dispatcher.
- **Fix:**
  - Strip the text after `;` before matching, in both scans.
  - List the 4 routines by name in the static check.

### 9. The patch-numbering wording is ambiguous (PLAUSIBLE, downgraded)
- **Where:** §3 (spec:77), "0001–0003 and 0005–0014 unchanged; 0004 replaced …; Numbers follow landing order".
- **What the other reviewer got wrong:** `-N` in `export.sh:22` is `--no-numbered`. It only changes the `[PATCH]` subject line; file names are numbered by position regardless.
- **Why both statements can hold:**
  - Only 0004 touches `dlls/ntdll/unix/signal_arm64.c`; 0009's hunks are in `signal_arm64ec.c`.
  - So rewriting commit e6ea94b in place keeps the strict x18 patch at 0004, and 0005–0014 export byte-identical under `--zero-commit`. msync gets 0015.
  - Dropping 0004 and appending a new patch would instead renumber 0005–0014. That would make the "patch 10" and "patch 12" comments at `check.sh:188` and `:260` stale.
- **Fix:** state "rewrite e6ea94b in place; msync is 0015, rebased onto it".

### 10. Lower-severity findings
- **`wineserver` is in the wrong folder in §3 (CONFIRMED).**
  - spec:71 puts it under `lib/wine/aarch64-unix/`. It is actually `Resources/bin/wineserver` (`bundle.sh:86`; `find` in `wine.app`).
  - Strict x18 doesn't touch it.
  - Fix: a separate line, `bin/wineserver (msync)`.
- **The line-number offset rule is wrong at both edges (CONFIRMED).**
  - spec:144 says "add 3 for its lines 58–1621 and 8 after them".
  - `git diff -U0 wine-11.19 HEAD -- dlls/ntdll/unix/signal_arm64.c` shows hunks `-59,0 +60,3` and `-1623,0 +1627,5`.
  - Fix: "+3 for lines 60–1623, +8 from 1624". No line the doc cites falls on an edge today.
- **The msync credits leave out a copyright holder (CONFIRMED).**
  - All 4 msync files on `cx/wine1117` carry "Copyright (C) 2018 Zebediah Figura" (1 match each).
  - The 8 fork commits are authored by "millia ampora" (dappermint).
  - Fix: add Figura, and the commit author's name, to spec:48 and to the README's msync line.
- **The cost figures for patch 0006's flip differ across documents, and the probe outputs weren't kept (CONFIRMED).**
  - spec:62 says 5.6 against 12.8 µs per cycle (brief §10 claim 4).
  - Brief §4 says 4.4 against 9.0 µs per cycle.
  - maps-summaries says about 2.2 µs ×2 against 9 µs.
  - The amended native §11 says "about 8.5 µs per switch".
  - Fix: one figure per mechanism, with its unit and its run, noting that the other numbers are superseded.
- **The "2 MB" `shm_addrs` table assumes 16K kernel pages (PLAUSIBLE).**
  - Object indices stay below 2^28 (bits 28 and 29 are flags), each entry is a `void *`, and the index maps as `(idx*16)/pagesize`. That gives 2 MiB at 16K pages and 8 MiB at 4K.
  - That the entitled 4K process reads 16384 is [I] (brief :153). S3's ">3,000 events" row would show a mismatch.
  - Fix: `assert(vm_kernel_page_size == 16384)` in `msync_init`, or the brief's `pages` row.
- **N2. A build path is compiled into `libgnutls` (PLAUSIBLE impact, new).**
  - `strings` on the scratch build shows `<build prefix>/deps/etc/gnutls/config`.
  - It does nothing at runtime: Wine sets `GNUTLS_SYSTEM_PRIORITY_FILE=/dev/null` when it is unset (`schannel_gnutls.c:1471`, `crypt32/unixlib.c:108`).
  - It does put the maintainer's path into a shipped binary, and it undercuts rationale (a) in brief §10 claim 2.
  - Fix: configure gnutls with `--with-system-priority-file=/dev/null`.
- **N3. The §12 and §1 fallback text is out of date (CONFIRMED, new).**
  - The scratch build used gnutls 3.8.13 with nettle 4.0 and gmp 6.3.0, both static and folded in.
  - `otool -L` shows only Security, CoreFoundation and libSystem. minos is 27.0. All 70 gnutls and 46 FreeType symbols are exported (`comm -23` against `gt70.txt` / `ft_all.txt` is empty). The configure flags in §5 all exist in `configure --help`.
  - Fix: §12's "folding … is untested" and the 5-dylib and nettle 3.10.2 fallbacks can be recorded as overtaken. The x18 gate (N1) is the remaining blocker.

## Dropped
- None of the 14 findings was fully refuted.
- The other reviewer's "holds" claim that gnutls scans at 0 x18 instructions is refuted; see N1.
- Finding 7's explanation via `format-patch -N` is wrong; the finding is downgraded to PLAUSIBLE (item 9).
- Finding 1's `nm -gU` trigger would never fire; that fix is removed.

## What I checked that holds
- **Licence check:** `licences_check.sh` prints 37 MISSING lines and exits 1. The split is 19 copies, 3 files to write, 9 holders and 6 SOURCE keys.
- **Bundle:** `wine.app` ships no dylibs today.
- **x18 line numbers:** the patched-tree numbers are right (`:1780`/`:1934` from `:1772`/`:1926` in pristine 11.19).
- **Protocol bump:** `tools/make_requests` bumps `SERVER_PROTOCOL_VERSION` by itself when `server_protocol.h` changes.
- **dappermint commits:** there are 8 msync commits dated 2026-08-21, and `e0aa380780` is the tip of `cx/wine1117`.
- **msync files:** 1246 + 49 + 856 + 51 = 2,202 lines.
- **Homebrew's `libgnutls.30`:** it names 8 `/opt/homebrew` dependencies.
- **Pins:** the tarball SHA-256 values match the pins.

Probe files: `/private/tmp/claude-501/-Users-chad-Documents-MacProton/4df1af36-0116-433f-917f-5078e899b9af/scratchpad/sp3-review/` (`gt.tv3`, `ntdll.dis`, `lic2.out`, `cx_msync.c`, `cx_server_msync.c`, `gt_trial_exports.txt`, `ft_trial_exports.txt`).

## feasibility
# Ship-base Wine spec (sub-project 3): feasibility re-check

I re-checked all 13 findings and none is refuted outright. Two sub-claims are dropped (listed at the end). Some findings needed corrections: the x18 allowlist misses `sha512`, one line reference was off, and the cost in #6 is overstated. I added four sub-findings, merged into #2, #8, #10 and #11 below.

The spec can't be completed as written in three places:
- **S2 can never pass:** the x18 scan fails on a correct `libgnutls`.
- **S5 has no defined T3 trigger:** nothing in the spec can cause a double toggle inside a Wine process.
- **S1 passes when it shouldn't:** the folded LGPL-3 libraries are never checked.

**Side effects of this re-check (please clean up):**
- My T3 re-run wrote a third crash report: `~/Library/Logs/DiagnosticReports/t3-2026-10-04-080145.ips`. The two from the first review are still there. All three can be deleted.
- One `git show` in `build/arm64/crossover/wine` used a malformed ref (a zsh `:s` modifier problem). Git tried a lazy fetch from the clone's remote, which failed (`not our ref`). After that I set `GIT_NO_LAZY_FETCH=1`.
- Probe files are in `/private/tmp/claude-501/-Users-chad-Documents-MacProton/4df1af36-0116-433f-917f-5078e899b9af/scratchpad/sp3-review/` (`gt.tv2`, `sk-int/`).

## Findings, most serious first

### 1. The x18 scan fails on a correct `libgnutls`, so S2 can never pass — CONFIRMED
- **Spec:** §5 asserts "no x18 use in either dylib (the regex of … x18-cache-scan.sh over `otool -tV`)". §8 says "`otool -tV ntdll.so` shows x18 used only inside the dispatcher…".
- **Problem:** gnutls's aarch64 assembly keeps its constant tables and an ID string inside `__text`. `otool -tV` decodes those bytes as instructions, and the regex matches them.
- **Evidence:**
  - The scratch `deps/lib/libgnutls.30.dylib` gives 7 hits with `/usr/bin/grep -cE '[^0-9a-zA-Z_][xw]18([^0-9]|$)'`.
  - By symbol, the 7 hits are 1 in `gcm_ghash_v8_4x`, 3 in `_sha256_block_data_order` and **3 in `_sha512_block_data_order`**. The other reviewer missed the sha512 ones.
  - `0xc77d0` is the SHA-256 K table: `otool -s __TEXT __text` shows `428a2f98 71374491 …` at `0xc77c0`. `0xc4d90` follows `.long 0x53414847` ("GHAS").
  - Every one of the 7 hits has a `.long` line within 2 lines of it.
  - Homebrew's libgnutls also gives 7. The brief's "Homebrew's builds … scan at 0 [V]" (brief.md:39) is wrong. In this session, the interactive `grep` is a ugrep wrapper that returns 0 where `/usr/bin/grep` returns 7. `bundle.sh` runs under `#!/bin/sh` and would get the real grep.
  - `ntdll.so` has 1 hit inside an otool comment: `_segv_handler` with `; literal pool for: " … x18=%016lx…"`.
  - New: §2 says "a scan of every bundled dylib", but §5 scans only the two. I scanned every arm64 Mach-O in today's bundle. Only `ntdll.so` (17) and `bin/wineserver` (2) have hits. The wineserver hits are both comments in `_dump_varargs_contexts` (`; literal pool for: ",x18="`).
  - `#0x18` immediates don't match: 3,670 such lines, 0 hits.
- **Fix:**
  - Strip `;` comments before matching (`sed 's/;.*//'`).
  - Allowlist by symbol: `gcm_ghash_v8_4x`, `sha256_block_data_order` and `sha512_block_data_order`. Use that instead of the `.long`-neighbour rule, which only works because of how the tables happen to decode.
  - Better primary gate: scan the assembly sources (gmp `mpn/arm64`, nettle `arm64`, gnutls `lib/accelerated/aarch64`). Apple clang never allocates x18. Keep the binary scan as a report.
  - Pick one scope for §2 and §5. A cheap option is every arm64 Mach-O except `ntdll.so`, which §8's static check covers. It passes today once comments are stripped.
  - Tell implementers to verify the gate with `/usr/bin/grep`.

### 2. T3 has no defined trigger, and Apple's annotation appears only in the crash report — CONFIRMED (the trigger part is PLAUSIBLE)
- **Spec:** §8 T3: "a negative program that enables the mode twice must die by `SIGTRAP` with Apple's annotation (exit 133 or a signal status), not as a Windows exception". The §8 wrapper "passes the toggle's `brk #1` through".
- **Problems:**
  - A PE program can't call `os_set_custom_x18_abi_enabled`, and the spec names no way to cause a double toggle inside Wine. A native negative program passes trivially and proves nothing about the wrapper.
  - The spec doesn't say how the wrapper tells the toggle's `brk #1` from a guest's own `brk`. Wine's `trap_handler` turns every BRK into a Windows exception (`signal_arm64.c:1215-1250`).
- **Evidence:**
  - Re-running the scratch `t3` (a native double enable) gives `Trace/BPT trap: 5` and `status=133` on stderr, with no annotation.
  - The annotation "attempted to switch to already enabled custom x18 ABI mode" appears only in the `.ips` file (`"type":"EXC_BREAKPOINT","signal":"SIGTRAP"`, codes 1 and 0x19843e814).
- **Fix:**
  - Add an env-gated self-test to the strict-x18 patch (for example `WINE_X18_SELFTEST=double_on`) that toggles twice inside ntdll.
  - In the wrapper, pass SIGTRAP through when the PC is not in PE code. That is simpler than matching the PC against libsystem.
  - Gate T3 on exit 133 from the `wine` process directly (not through `exe_cmd`'s `| tr … || true`) and on no `err:seh` line.
  - Report the `.ips` annotation without gating on it, or poll for the `.ips` for a few seconds.

### 3. The licence gate never checks the folded nettle and gmp, so S1 can pass without their LGPL-3 texts — CONFIRMED
- **Spec:** §4: "each bundled third-party dylib has its folder". The §1 Decisions table: "nettle, hogweed and gmp linked statically into `libgnutls.30.dylib`" and "libunistring under LGPL-3+".
- **Problem:** the nettle and gmp checks only run if a `libnettle*` or `libgmp*` dylib is present. With folding, those files never exist.
- **Evidence:**
  - `licences_check.sh:43-44` (`has 'libnettle*' && …`, `has 'libgmp*' && …`). The gnutls check at `:42` requires only `COPYING.LESSERv2`.
  - The scratch `deps/lib` has only `libgnutls.30.dylib`, plus the `.a` files for nettle, hogweed and gmp.
  - The gnutls tarball ships only `COPYING` (GPLv3) and `COPYING.LESSERv2`. Its `lib/unistring` sources are dual "LGPLv3+ or GPLv2+" (102 files) or LGPL-2.1+ (52 files), so the LGPL-3 text for libunistring must come from nettle's or gmp's `COPYING.LESSERv3`.
  - `:49` requires `MACNEUTRON_COMMIT=`, but §4's SOURCE list doesn't include MacNeutron.
- **Fix:**
  - Run the `gnutls/`, `nettle/` and `gmp/` checks whenever `libgnutls*` is present.
  - Require `gnutls/COPYING.LESSERv3` and `COPYINGv3`, taken from nettle's tarball, for libunistring.
  - Make §4's SOURCE key list match the test, including `MACNEUTRON_COMMIT` and the tarball keys.

### 4. The `msync` step's checks depend on which run started wineserver — CONFIRMED
- **Spec:** §6: "`msync: up and running.` appears only with `WINEMSYNC=1`", "no `msync: error` line", and "switches modes with `wineserver -k` between them".
- **Evidence:**
  - Both strings come from wineserver: `cx/wine1117:server/msync.c:682`, and `"msync: "` appears in 18 `fprintf` lines in that file.
  - The server keeps the stderr of the client that started it. `server/request.c:850-851` redirects only fds 0 and 1.
  - The server stays up for 3 s after the last client (`server/main.c:48`). Only the `dxmt` step waits for it (`check.sh:332`).
  - On a mismatch the client prints through `ERR` (`dlls/ntdll/unix/msync.c:649` and `:692`), which `WINEDEBUG=-all` hides.
  - If the step ends in mode 0, the next step's `WINEMSYNC=1` client fails `bootstrap_look_up` and exits 1.
- **Fix:**
  - Run `wineserver -k` before each mode block, so the step's own run starts the server and its stderr lands in the step's log.
  - Don't use `-all` for the mode rows.
  - End the step with `wineserver -k`.

### 5. The deps build picks up Homebrew's nettle — CONFIRMED
- **Spec:** §5 names `PKG_CONFIG_LIBDIR` only for "Wine's configure".
- **Evidence:**
  - The scratch `leak/gnutls-3.8.13/config.log` (configured without the variable) has `NETTLE_LIBS='-L/opt/homebrew/Cellar/nettle/4.0/lib -lnettle'` (lines 73176-73177), the matching `HOGWEED_LIBS` (72847), and `PKG_CONFIG_LIBDIR=''`.
  - gnutls finds gmp with `AC_CHECK_LIB` (`m4/hooks.m4:101`), so it also needs `LDFLAGS` pointing at the deps prefix.
  - The result would be caught late by the `otool -L` gate, after a full build, not shipped silently.
- **Fix:** for the whole deps step:
  - export `PKG_CONFIG_LIBDIR=<deps>/lib/pkgconfig`, `CPPFLAGS=-I<deps>/include`, `LDFLAGS=-L<deps>/lib` and `CC=/usr/bin/clang`;
  - unset `PKG_CONFIG_PATH`;
  - run `otool -L` on each dylib as soon as it is built.

### 6. Tarball pins in `wine-arm64/pins` force a Wine and FEX re-clone on every bump — CONFIRMED (cost corrected)
- **Spec:** §5: "Pins in `wine-arm64/pins`" and "redone only when these pins change, recorded in `deps/.complete`".
- **Evidence:**
  - `build.sh:81-82` hashes `wine-arm64/pins` into both `wine_series` and `fex_series`. A change makes applied trees `reapply`.
  - Then `:96` deletes the tree, `fetch_wine` deletes `wine-build` (`:52`), and `fetch_fex` deletes `fex-ec` and `fex-unixlib` (`:62`).
  - Correction: §5's own reconfigure rule already forces a full Wine rebuild on any deps change. The extra cost is the Wine and FEX re-clones (network) and a full FEX rebuild.
  - Separately, changing a deps configure option without a pin change leaves a stale library, because `.complete` only records pins.
- **Fix:**
  - Put the four pins in their own file (for example `wine-arm64/deps.pins`).
  - Add that file to `stamp_of` (`build.sh:85-88`), not to `series_of`.
  - Make `.complete` hash the pins plus the deps' configure lines.

### 7. The `otool -L` gate can't catch a Homebrew header leak for these two libraries — CONFIRMED (the freetype-config path is PLAUSIBLE)
- **Spec:** §5: the gate "also catches a Homebrew leak anywhere". §13 item 7: the Homebrew leak through configure is "closed by §5".
- **Evidence:**
  - Both libraries are only `dlopen`ed, so nothing links them. Today's bundle passes the gate (37 Mach-Os, no path outside the allowed prefixes) even though it was compiled against Homebrew headers (`wine-build/config.log:6512-6513, 7003-7004`).
  - `configure.ac:1680-1681` falls back to `freetype-config`. `/opt/homebrew/bin/freetype-config` is on `PATH` if our `.pc` file is ever missing.
- **Fix:** pass `FREETYPE_CFLAGS/LIBS` and `GNUTLS_CFLAGS/LIBS` explicitly (`aclocal.m4:98,103` honours them). Fail the build if a `cflags:` or `libs:` line in `config.log` contains `/opt/homebrew`.

### 8. The FEX `External/` allowlist in §4 names the wrong 8, and SOURCE can't list 8 submodule commits — CONFIRMED
- **Spec:** §4: "`fex-ec/External` holds only the 8 allowlisted externals", with "fmt, xxhash, tiny-json, cpp-optparse, unordered_dense, rpmalloc, range-v3, cephes". Also "FEX with the 8 externals' submodule commits".
- **Evidence:**
  - `ls fex-ec/External` gives SoftFloat-3e, cephes, fmt, range-v3, rpmalloc, tiny-json, unordered_dense, xxhash.
  - cpp-optparse is built from `Source/Common/cpp-optparse` (`fex-ec/Source/Common/cpp-optparse/libcpp-optparse.a`).
  - New: `git submodule status` shows that of the 8 named externals, only 6 are submodules. tiny-json and cephes are in-tree, and so is SoftFloat-3e.
  - The drift allowlist in `licences_check.sh:35` is already correct.
- **Fix:** separate the `External/` allowlist (which includes SoftFloat-3e, noticed in NOTICES.md) from the per-component LICENSE list (which includes cpp-optparse). SOURCE should record 6 submodule commits; the in-tree ones are covered by `FEX_COMMIT`.

### 9. The signature check needs downloads and a tool the spec doesn't allow — CONFIRMED (".sig returns HTTP 200" is the other reviewer's claim, not re-checked)
- **Spec:** §5: "the first fetch also checks each tarball against its upstream signature". The §1 Decisions table: "Nothing else is downloaded".
- **Evidence:** `gpg` and `gpgv` exist only at `/opt/homebrew/bin` and aren't in `need_tool`. `~/.gnupg` doesn't exist, so the signing keys would be further downloads.
- **Fix:** with the maintainer's approval for the `.sig` and key downloads, verify once by hand and record the key fingerprints in the acceptance doc. `build.sh` then checks SHA-256 only.

### 10. check.sh wiring the spec leaves out — CONFIRMED (line references corrected)
- **Spec:** §7 names `NEEDS_FEX` only for `wxflip-x64`.
- **Evidence:**
  - The lists are at `check.sh:37-38` and the loops that pull in dependencies at `:446-456`.
  - The comment at `:31` says x64 steps without `fex` run under "Wine's stub xtajit64".
  - `msync` (x64 lane) and `x18` (T2's x86_64 run) need `NEEDS_FEX`. `fonts-tls`, `msync` and `x18` need `NEEDS_PREFIX`.
- **Fix:** add those steps to the two lists.

### 11. The x18 test programs mostly don't exist, and `x18path` needs a Makefile rule — CONFIRMED
- **Evidence:**
  - `x18v.c` exists only at `build/arm64/entitled/verify/x18v.c` (69 lines, ignored via `.gitignore:3`). `x18path` and the negative program don't exist anywhere.
  - New: the Makefile chooses the compiler from the file name's prefix (`arm64-%`, `x64-%`, `Makefile:121-128`). A bare `x18path.c` matches no rule and breaks `make wine-arm64-tests`. Building it "aarch64 and x86_64" needs an explicit second rule, like `arm64ec-sync.exe`.
- **Fix:**
  - Say these programs are new.
  - Add `wine-arm64/tests/arm64-x18v.c`.
  - Name the T2 source `arm64-x18path.c` and add an explicit rule for `x64-x18path.exe`, listed in the `wine-arm64-tests` target.

### 12. Moving the `fetch` helper misses other callers — CONFIRMED
- **Spec:** §5: "`fetch` moves from `dxmt/lib.sh` into a sourced file both build scripts use".
- **Evidence:**
  - `dxmt/toolchain.sh:7,12` sources `dxmt/lib.sh` and calls `fetch`.
  - `toolchain.sh` is run by `Makefile:5`, `wine-arm64/build.sh:35`, `check.sh:395`, `dxmt/build.sh:71`, `Tests/Smoke/smoke.sh:12` and `dxmt/tests/build_test.sh:53` (new).
  - `fetch` prints a hard-coded `dxmt: downloading` (`dxmt/lib.sh:5`).
- **Fix:**
  - Have `dxmt/lib.sh` source the new file.
  - Take the message prefix from the caller.
  - Add the new file to `wine-arm64/build.sh`'s `stamp_of`.

### 13. Minor: gnutls compiles in a build-machine path — CONFIRMED
- **Evidence:** `strings libgnutls.30.dylib` shows `<scratch>/deps/etc/gnutls/config`. `otool -L` can't see it. On users' Macs the path holds the maintainer's username and wouldn't exist.
- **Fix:** add `--sysconfdir=/etc` (or `--with-system-priority-file=…`) and a `strings | grep "$B"` assert.

## Dropped
- **#6 (deps build), sub-claim "`build.sh:35` puts llvm-mingw's bare `clang` on `PATH`":** refuted as a risk. That `bin` folder has `clang` and `clang++` but no `cc`, `gcc`, `ar` or `ranlib`, autoconf tries `gcc` then `cc` first, and §5 already names `/usr/bin/clang`. Exporting `CC` is kept in #5's fix.
- **#1, sub-claim "allowlist `sha256_block_data_order` and `gcm_ghash_v8_4x`":** replaced by the full three-symbol allowlist above.

## What I checked that holds
- **Checksums:** all four tarball SHA-256s in the scratch directory match §5's table.
- **nettle 4.0 with gnutls 3.8.13:** gnutls's configure requires nettle ≥ 3.10 (`m4/hooks.m4:71`), and its `NEWS:161` says "Support building with Nettle 4.0".
- **gnutls options:** every listed option is in `gnutls-help.txt` or, for `leancrypto`, in `AC_ARG_WITH` (`configure.ac:1298`).
- **The folded `libgnutls.30.dylib`:**
  - depends only on Security, CoreFoundation and libSystem;
  - is `minos 27.0`;
  - exports no nettle or gmp symbols;
  - exports all 70 gnutls symbols in `gt70.txt`.
- **FreeType:** exports all 46 symbols in `ft_all.txt`, links only `/usr/lib` zlib and bzip2, and has 0 x18 hits.
- **Install name:** `install_name_tool -id @rpath/libgnutls.30.dylib` works, and `codesign -v` still passes afterwards.
- **Today's bundle passes the `otool -L` gate:** all 37 Mach-Os.
- **Wine's configure:** `WINE_ERROR_WITH` makes a missing FreeType fatal. Wine's soname detection (`aclocal.m4`) takes the file name after the last `/`, so `@rpath/` install names still give `libgnutls.30.dylib`.
- **`licences_check.sh`:** prints 37 MISSING today.
- **`fonts-tls` failure strings:** they exist at `win32u/freetype.c:1460` and `schannel_gnutls.c:1477`. `tahoma.ttf` ships in the bundle.
- **Signal handlers:** Wine registers nine handlers on ten signals (`signal_arm64.c:1581-1599`).
- **The ntdll x18 sites:** they are in `__wine_syscall_dispatcher`, `__wine_unix_call_dispatcher`, `call_user_mode_callback` and `__wine_syscall_dispatcher_return`, plus the `segv_handler` comment.
- **msync in 11.19:** the mode-0 client probe gets `STATUS_INVALID_PARAMETER` from the 11.19 server (`server/thread.c:2382`), so non-msync clients aren't broken. The trial diff grows `get_inproc_sync_fd_reply` from 16 to 24 bytes, as §6 says. `wineserver -k` and `-w` exit before `msync_init` (`main.c:86-103` vs `:263`).
- **`WINEMSYNC` reach:** `dxmt/check.sh`'s arm64 runner uses `env` without `-i`, so an exported `WINEMSYNC` reaches it.

## consistency
# Sceptic re-check (consistency lens): SP3 Ship-base Wine spec

I re-checked all 20 findings myself, read-only, and added 2 new ones. Three findings were partly refuted, and only those parts are dropped. Probes ran only in `scratchpad/sp3-review`: a scratch `freetype2.pc` and a link test of the `fonts-tls` calls.

One evidence warning first. In this session `grep` is a ugrep wrapper that silently returned 0 for the x18 regex. Every regex result below comes from `LC_ALL=C /usr/bin/grep`. `bundle.sh` runs under `sh`, so it isn't affected.

## Surviving findings, most serious first

### 1. The dependency builds can still see Homebrew; only Wine's configure is restricted. Mechanism CONFIRMED; the gnutls outcome is PLAUSIBLE (merges old #2)
- **Where:** §5, "Wine's configure runs with `PKG_CONFIG_LIBDIR=<deps>/lib/pkgconfig`". The gmp, nettle, gnutls and freetype builds get no such setting. §1 also promises "a Homebrew leak through configure (closed by §5)".
- **Problem:**
  - **FreeType:** pkgconf finds Homebrew's `zlib.pc` and `bzip2.pc`, so FreeType's configure will write `Requires.private: zlib, bzip2` into `freetype2.pc`. Under the restricted LIBDIR, pkgconf then rejects `freetype2`. Wine's fallback, `freetype-config`, also prints nothing, so `--with-freetype` stops configure.
  - **gnutls:** its configure finds Homebrew's shared nettle and hogweed 4.0 (the same version as our pin) instead of our static ones. It would link `/opt/homebrew/.../libnettle.8.dylib`, and nothing would be folded in.
    - Only the new `otool -L` assert catches this, and only after a full Wine build.
    - That failure is easy to misread as "libtool won't fold", which is §12's trigger for the 5-dylib fallback.
- **Evidence:**
  - Homebrew's FreeType 2.14.3 (`/opt/homebrew/lib/pkgconfig/freetype2.pc:11`) has `Requires.private: zlib, bzip2, libpng`.
  - `pkg-config --path bzip2` prints `/opt/homebrew/Library/Homebrew/os/mac/pkgconfig/27/bzip2.pc`.
  - With the scratch `.pc` and `PKG_CONFIG_LIBDIR=<scratch>`, `--exists`, `--cflags` and `--libs` each return rc=1 with "Package 'zlib', required by 'freetype2', not found".
  - Under the same LIBDIR, `freetype-config --cflags` prints an empty line. Wine's fallback for it is at `configure.ac:1679-1681` and `aclocal.m4` (`ac_cflags=${ac_cflags:-$4}`).
  - `/opt/homebrew/lib/pkgconfig/{nettle,hogweed}.pc` both say `Version: 4.0`.
- **Fix:**
  - Run every dependency configure with the same `PKG_CONFIG_LIBDIR=<deps>/lib/pkgconfig`, plus `CPPFLAGS=-I<deps>/include` and `LDFLAGS=-L<deps>/lib` for gmp.
  - In the deps step, assert that `freetype2.pc` has no `Requires.private` and that `otool -L libgnutls.30.dylib` names no nettle, hogweed or gmp.
  - Optionally, pass `FREETYPE_CFLAGS`/`FREETYPE_LIBS` and `GNUTLS_CFLAGS`/`GNUTLS_LIBS` to Wine's configure explicitly.

### 2. Putting the tarball pins in `wine-arm64/pins` deletes the Wine and FEX trees and clones them again. CONFIRMED (old #1)
- **Where:** §5, "**Pins** in `wine-arm64/pins`". Also: "redone only when these pins change, recorded in `deps/.complete`".
- **Problem:**
  - `wine-arm64/pins` is hashed into both the Wine series and the FEX series.
  - Any pin edit makes a clean tree count as `reapply`. That includes adding the 4 tarballs, or the nettle 3.10.2 fallback later.
  - `build.sh` then runs `rm -rf` on the tree, clones Wine and FEX again (with FEX's submodules), and wipes `wine-build`, `fex-ec` and `fex-unixlib`.
  - §6's "Rebuild cost" counts only Wine rebuilds.
- **Evidence:**
  - `wine-arm64/build.sh:81-82` computes the series; `:52` and `:62` delete the build folders; `:96` deletes the tree.
  - `lib.sh:29-30` returns `reapply`.
  - `tests/mode_test.sh:16` asserts this ("a pin moved").
  - `wine-arm64/README.md:106-107`.
  - `export.sh:29` also computes the series from the same file.
- **Fix:** put the tarball pins in their own file, for example `wine-arm64/deps.pins`. Include it in `stamp_of` (`build.sh:85`) but not in `series_of`, in both `build.sh` and `export.sh`. Otherwise, state the cost and say to run `make wine-arm64-export` right after editing the pins.

### 3. The `msync` step can leave the prefix's server in the wrong mode, and its server-stderr rows can read another step's log. Gap CONFIRMED; failure PLAUSIBLE (old #3)
- **Where:** §6, "the `msync` step switches modes with `wineserver -k` between them". §10: "never mixes modes in one prefix without `wineserver -k`".
- **Problem:**
  - **The step's end:** nothing requires a `-k` at the end. wineserver stays alive for 3 s after its last client.
    - If the step ends in mode 0, the next step's first `wine_run` under `WINEMSYNC=1` fails `bootstrap_look_up` and calls `exit(1)`.
    - For example, if `msync` comes before `dxmt`, then `dxmt_cmd` fails and so does S6.
  - **The step's start:** both `msync: up and running.` and every `msync: error` line are printed to the server's stderr.
    - That stderr is inherited from whichever client started the server. Today that is an earlier step, so the lines land in an earlier step's log.
    - So the mode row and the "no `msync: error`" row can pass or fail vacuously.
- **Evidence:**
  - `server/main.c:47`: the timeout is 3 seconds.
  - `msync-on-11.19-trial.diff:687` is the mismatch `ERR` plus `exit(1)`. `:730` is `Failed bootstrap_look_up` plus `exit(1)`. `:2395` (cx `server/msync.c:682`) is `fprintf(stderr, "msync: up and running.\n")`.
  - `check.sh:128`: `wine_run` adds nothing per step.
- **Fix:** the step starts and ends with `wineserver -k`. For each mode, start the server explicitly (`WINEMSYNC=<m> wineserver -p0 2> <log>`, or `-f`) and grep that log for the mode and error rows.

### 4. Nothing tests a signal landing during a toggle, although §12 says "T1–T2 stress it". CONFIRMED (old #4)
- **Where:** §12, "a signal can land between a toggle and its neighbour (T1–T2 stress it)".
- **Problem:**
  - T1 (`x18v`) spins with no syscalls, so no toggle runs during it. T2 visits each path once.
  - The S2/S3 stress tests were dropped, though the doc says this risk needs them: a timer handler firing during toggles, and a handler that redirects into PE code.
  - Also dropped without a word: the brief's T5 ("S2/S3 stress tests entitled, 0 failures") and T4's "DXMT frame-time p50 within 1%".
- **Evidence:**
  - `entitled-trial-verified.md:34`: "a 3 s spin with no syscalls".
  - `x18-boundaries.md:89` (the risk) and `:111-114` (S2 and S3).
  - `brief.md:245-246`.
- **Fix:** add a gated stress row. For example: N threads loop `NtQuerySystemTime` and a no-op unix call while another thread hammers SuspendThread/GetThreadContext/ResumeThread (usr1) and a timer signal. Expect 0 mismatches and no `brk`. Restore the DXMT p50 ≤1% to M2, or say why it was dropped.

### 5. §8 describes the wrapper's toggle rule backwards from the doc. CONFIRMED, NEW
- **Where:** §8, "it turns the mode ON when the interrupted code ran PE (and back for the handler's own unix work…)". The same bullet says the wrapper must land with the dispatchers "because handlers that run OFF redirect into PE code".
- **Problem:** the doc's rule depends on where the handler sends execution, not on what it interrupted:
  - at entry, if the mode is ON, turn it OFF;
  - on exit, turn it ON only when the new PC is PE code (or keep the entry mode for usr1 and int).
  
  Read literally, the spec gets two cases wrong:
  - It turns ON a mode that is already ON, which hits `brk #1`.
  - It leaves OFF the case its own rationale names: an OFF handler (usr2 slow path, abrt) that redirects into PE.
- **Evidence:** `x18-boundaries.md:47-59` (`was_on`, OFF before libc, `on = …KiUserExceptionDispatcher… || !is_inside_syscall(...)`). `brief.md:227`.
- **Fix:** state the doc's rule in §8: OFF at entry if ON; ON at exit when the redirected PC is PE (or keep the entry mode for usr1 and int).

### 6. T3, recognising the toggle's `brk`, and the "PE stack implies ON" check are under-defined. Gap CONFIRMED; impact PLAUSIBLE (old #5)
- **Where:** §8 T3: "a negative program that enables the mode twice must die by `SIGTRAP`". The wrapper "passes the toggle's `brk #1` through". It "checks 'PE stack implies ON' on every signal".
- **Problem:**
  - A PE program can't call `os_set_custom_x18_abi_enabled`, and the spec doesn't name T3's trigger. `probes/trappass.c` is native, so it doesn't exercise Wine's wrapper.
  - The spec doesn't say how the wrapper tells the toggle's `brk #1` apart from a `brk` in PE code.
  - It doesn't say how "PE stack" is decided on threads with no TEB (Cocoa, Metal and GCD threads). The doc's wrapper exempts them; §8's invariant doesn't, so a stray SIGABRT or SIGINT on such a thread could abort the game by mistake.
- **Evidence:**
  - `x18-boundaries.md:53` (`!data || !data->teb`).
  - `:9` and `:12`: the toggle's `brk #1` is inside the commpage routine.
  - `signal_arm64.c:1216` (`trap_handler` makes `EXCEPTION_ILLEGAL_INSTRUCTION`).
- **Fix:**
  - Name T3's trigger (for example a test-only unix call in the patch) and its file.
  - Recognise the toggle's trap by ESR immediate 1 **and** a PC inside the toggle routine's range.
  - Exempt threads with no TEB from the invariant.

### 7. Where the new check steps go, and what they depend on, isn't stated. CONFIRMED (old #7)
- **Where:** §5–§8 add `fonts-tls`, `msync`, `wxflip-x64` and `x18`. The spec says only "`wxflip-x64` (in `NEEDS_FEX`)".
- **Problem:**
  - Their positions in `STEPS` and their `NEEDS_PREFIX`/`NEEDS_FEX` membership are unset, although `msync` and `x18` both run x64 code under FEX.
  - `wxflip-x64` doesn't pull in its positive control `wxflip`, the way `g5-jit` does.
  - A failing step stops the run. Steps appended after `dxmt-x64` or `g4-bench` therefore never run on a Mac without SMITE 2 or runtime-v4.7.3.
  - This also decides which step follows `msync` (see finding 3).
- **Evidence:** `check.sh:30` ("each task appends its own"), `:34-38`, `:449-450` and `:124-125`. `README.md:68-70`.
- **Fix:** list the positions (before `dxmt`) and the `NEEDS_*` lists, and add `wxflip-x64` to the line that pulls in `wxflip`.

### 8. As written, §8's static x18 check fails on today's `ntdll.so`. CONFIRMED, NEW
- **Where:** §8, "`otool -tV ntdll.so` shows x18 used only inside the dispatcher, callback and dispatcher-return routines".
- **Problem:** the x18 regex matches 17 lines:
  - 5 in `___wine_syscall_dispatcher`, 1 in `___wine_syscall_dispatcher_return`, 3 in `___wine_unix_call_dispatcher` and 7 in `_call_user_mode_callback`;
  - plus 1 in `_segv_handler`. That one is otool's annotation `; literal pool for: " x16=%016lx x17=%016lx x18=%016lx…"`, a debug string, not a register use.
  
  The brief warns about `#0x18` matches but not about these comments. The same regex runs over the two new dylibs.
- **Evidence:** `otool -tV ntdll.so | awk …fn… | LC_ALL=C /usr/bin/grep -E '[^0-9a-zA-Z_][xw]18([^0-9]|$)'`, grouped by function. `brief.md:241`.
- **Fix:** strip `;.*$` before matching, and name the 4 allowed functions in the check. Apply the same comment stripping to `bundle.sh`'s dylib scan.

### 9. The test programs don't fit the Makefile; one source isn't in the repository, and `fonts-tls` needs libraries. CONFIRMED (old #6)
- **Where:** §8, "`x18path`, built aarch64 and x86_64". "T1: `arm64-x18v.exe`". §6, "`arm64ec-sync.exe`". §5, `arm64-fonts-tls.c`.
- **Problem:**
  - The `WA_TESTS` wildcard turns every `tests/*.c` into a target, and the file-name prefix picks the compiler. A file named `x18path.c` has no rule.
  - `x18v.c` exists only under the untracked `build/`.
  - `arm64ec-sync.exe` and the x64 `x18path` each need their own rule.
  - `fonts-tls` needs **both** `-lgdi32` and `-lsecur32`.
- **Evidence:**
  - `Makefile:113-128`.
  - `build/arm64/entitled/verify/x18v.c`, with `git ls-files | grep x18v` printing nothing.
  - The scratch link test without those flags left `CreateFontW`, `GetTextMetricsW`, `SelectObject` and `AcquireCredentialsHandleW` undefined; with them it linked.
- **Fix:**
  - Commit `tests/arm64-x18v.c`.
  - Name the path test `arm64-x18path.c`, with an extra x64 rule like `arm64ec-sync`'s.
  - Name T3's program.
  - Add `WA_FLAGS_arm64-fonts-tls = -lgdi32 -lsecur32`.

### 10. Two different "8 FEX externals" lists are mixed together. CONFIRMED (old #10)
- **Where:** §4, "fmt, xxhash, tiny-json, cpp-optparse, unordered_dense, rpmalloc, range-v3, cephes". Also "`fex-ec/External` holds only the 8 allowlisted externals" and "FEX with the 8 externals' submodule commits".
- **Problem:**
  - `fex-ec/External` holds SoftFloat-3e, cephes, fmt, range-v3, rpmalloc, tiny-json, unordered_dense and xxhash. cpp-optparse lives in `Source/Common/` instead. An allowlist built from §4's list fails on SoftFloat-3e.
  - SoftFloat-3e has no licence file, so it can only be covered by `NOTICES.md`.
  - tiny-json, cephes and SoftFloat-3e are not submodules, so they have no submodule commits.
- **Evidence:** `ls build/wine-arm64-src/fex-ec/External`. `fex/.gitmodules`. `ls fex/External/SoftFloat-3e` shows `CMakeLists.txt include src`. The correct allowlist is `licences_check.sh:35`.
- **Fix:** give two lists: the drift allowlist (`fex-ec/External`), and the licence files with their sources (6 submodule commits, plus 2 trees copied into FEX's own). Note that SoftFloat is covered by `NOTICES.md`.

### 11. The licence test misses what is folded into `libgnutls`, and the same list is kept twice. CONFIRMED (old #11)
- **Where:** §4, "each bundled third-party dylib has its folder". §1 elects LGPL-3+ for libunistring.
- **Problem:**
  - With nettle and gmp folded in, there is no `libnettle*` or `libgmp*` dylib, so the `nettle/` and `gmp/` folders are never checked.
  - `gnutls/` is checked only for `COPYING.LESSERv2`, while the unistring election needs the LGPLv3 and GPLv3 texts.
  - `bundle.sh`'s asserts and `licences_test.sh` duplicate one list. Because `bundle.sh` refuses to stage a failing bundle and `wine-arm64-check` depends on the build, the test can never be red there.
- **Evidence:** `licences_check.sh:41-44`. `Makefile:136-139`.
- **Fix:** tie the nettle, gmp, unistring and tasn1 texts to `libgnutls.30.dylib`. Keep one list: `bundle.sh` runs `licences_test.sh` against `wine.app.tmp`.

### 12. `SOURCE`'s keys disagree with the check that is meant to become the test. CONFIRMED (old #8)
- **Where:** §4, "each pin (Wine, FEX…, DXMT, LLVM, llvm-mingw, the four tarballs…)".
- **Problem:**
  - There is no MacNeutron commit, but the test requires `MACNEUTRON_COMMIT=`, and the brief listed it.
  - If it is added, the build stamp doesn't cover the repository's HEAD, so an "up to date" build keeps a stale value.
  - In a development build the series hash doesn't describe the tree.
- **Evidence:**
  - `licences_check.sh:49`. A run gives 37 MISSING, including `SOURCE line MACNEUTRON_COMMIT=`.
  - `brief.md:107`.
  - `build.sh:113-116` (the early exit) and `:179-182` (`+dev`).
- **Fix:** settle the key list in the spec and the test together, and write `dev` in place of a series hash for development trees.

### 13. `ERR` lines are silent under `WINEDEBUG=-all`. CONFIRMED, with narrower scope (old #16)
- **Where:** §10, "`ERR` line, then `abort`". Also: "The client exits with msync's message".
- **Problem:**
  - Under `-all` (the launcher's default, and g4-bench), an invariant violation aborts with no message. msync's mismatch message is also an `ERR`.
  - `check.sh`'s `wine_run` leaves `WINEDEBUG` unset, so T2 and the msync mode row do see the lines.
- **Evidence:** `include/wine/debug.h:77`. `check.sh:280`. Trial diff `:687`.
- **Fix:** print the invariant message unconditionally with `write(2)` before `abort`. Qualify §10's msync row ("silent under `-all`").

### 14. Checking signatures contradicts "Nothing else is downloaded". CONFIRMED (old #12)
- **Where:** §1, "Nothing else is downloaded". §5, "the first fetch also checks each tarball against its upstream signature".
- **Problem:**
  - `.sig` files, the GNU keyring and FreeType's key are unapproved downloads.
  - `gpg` is installed (`/opt/homebrew/bin/gpg`), but `need_tool` doesn't list it.
- **Fix:** list them in the Downloads decision as a one-time manual step outside `build.sh`, or drop the signature check.

### 15. The committed licence files aren't build inputs. CONFIRMED (old #9)
- **Where:** §4, "Committed `wine-arm64/licenses/NOTICES.md` … `licenses/README`".
- **Problem:** neither file is in the stamp, so editing them leaves an "up to date" bundle with the old notices.
- **Evidence:** `build.sh:85-88` and `:113-116`.
- **Fix:** add both files, and the deps pins file from finding 2, to `stamp_of`.

### 16. "Three sites `x18-boundaries.md` lacks" is really two. CONFIRMED (old #15)
- **Where:** §2 ("`__wine_syscall_dispatcher_return` reads x18 while OFF"). Native spec `:255` repeats "missed three sites".
- **Problem:** the doc already covers that site.
- **Evidence:** `x18-boundaries.md:43` ("`:1885`: read the TEB from `[sp,#0x90]`"). In `git show 455e3509…:dlls/ntdll/unix/signal_arm64.c`, line 1885 is `ldr w11, [x18, #0x380]` inside `__wine_syscall_dispatcher_return`.
- **Fix:** say "two additions" in both specs, and restate the reason for the 110–140 line estimate.

### 17. Patch numbering is ambiguous, and §8's line offsets come from patch 0004 itself. CONFIRMED (old #13, corrected)
- **Where:** §3, "0004 replaced by the strict x18 patch; … Numbers follow landing order". §8, "add 3 for its lines 58–1621 and 8 after them".
- **Problem:**
  - `export.sh` numbers patches sequentially. If 0004 is dropped and the x18 patch appended, 0005 onward shift down by one. That breaks `README.md`'s per-number credits (0006, 0009, 0013) and every "patch 0006", "patch 0014" and "patch 13" reference.
  - Only 0004 touches `signal_arm64.c`, so the +3/+8 offsets are 0004's own hunks. Once 0004 is rewritten in place, the doc's original line numbers apply.
- **Evidence:**
  - `export.sh:22`.
  - `/usr/bin/grep -lF dlls/ntdll/unix/signal_arm64.c patches/wine/*.patch` matches only 0004.
  - 0004's hunks are `@@ -57,6 +57,9 @@` and `@@ -1621,6 +1624,11 @@`.
- **Fix:** say "0004 is rewritten in place (numbers unchanged); msync is 0015". Say the offsets apply only while 0004's ON-once hunk is in the tree.

### 18. Smaller missing pieces. CONFIRMED (old #18)
- **The `fetch` move:** `dxmt/toolchain.sh:12` also calls `fetch`; it is the third user, and `dxmt/lib.sh:1` names it. S6 lacks sub-project 2's D5-style re-run (SP2 spec `:167`). `dxmt/build.sh:14-18` exits before `fetch` when up to date, so no S6 step runs the moved helper.
- **`wine-arm64/README.md`:** the Licences section (msync and x18 credits), the steps, the check time and the deps need updating.
- **`deps/.complete`:** it records the pins but not the dependencies' configure flags, while Wine's configure line is recorded. `dxmt/llvm.sh` is a precedent for not recording flags; say which rule applies.

### 19. The msync credit names the branch tip, not the msync commits. CONFIRMED (narrowed old #14)
- **Where:** §1, "dappermint `winecx` `e0aa380780`".
- **Problem:**
  - `e0aa380780` is the tip of `cx/wine1117`: millia ampora, 2026-09-17, "fix(kernelbase): preserve last error in flsgetvalue2".
  - The 8 msync commits are `8df1826853`, `9be392b3b4`, `3a7a712d66`, `307f90fdb1`, `620d8c542f`, `a7ef7b3b01`, `ef72fdb55b` and `6d316146c2` (millia ampora, 2026-08-21).
- **Evidence:** `git rev-parse cx/wine1117` and `git log cx/wine1117 -- server/msync.c …` in the crossover clone. `brief.md:361`: the credits "should name the fork's commits as well as CrossOver".
- **Fix:** credit "cx/wine1117 at e0aa380780", list the 8 msync commits, and name their author.

### 20. Brief items dropped without a mention. CONFIRMED (narrowed old #20)
- **Signing asserts** (`Timestamp=` on every Mach-O, no get-task-allow): `brief.md:128`.
- **Page size in the entitled bundle:** a check that `vm_kernel_page_size` reads 16384 there (`brief.md:153`, `:178`). Also, §2's "Every private API it uses works across two hardened-runtime processes" drops the brief's caveat that this was never tested with the entitled 4K `wine.app` (`brief.md:361`). Worker processes run at 4K and wineserver at 16K.
- **The licence test's red-proofs:** `brief.md:127`.
- **msync's authors in `NOTICES.md`:** `brief.md:180`.

**Fix:** restore each, or list it as dropped.

### 21. The bundle layout puts `wineserver` in the wrong place. CONFIRMED (old #17)
- **Where:** §3, "`lib/wine/aarch64-unix/ntdll.so, wineserver`".
- **Problem:** `wineserver` is at `Resources/bin/wineserver`, and strict x18 changes only `ntdll.so`.
- **Evidence:** `bundle.sh:86`. `find wine.app -name 'wineserver*'`.
- **Fix:** correct the layout line.

### 22. DXMT's licence files aren't placed in the "one tree". PLAUSIBLE (old #19)
- **Where:** §4, "**One tree:** `Resources/licenses/<component>/`". §3: "`DXMT/…` (unchanged)".
- **Problem:** DXMT's 3 texts stay in `Resources/DXMT/` (`bundle.sh:56`), and §4's README description doesn't point there.
- **Fix:** state it in §4's description of `licenses/README`.

## Dropped
- **Old #13, the 0009 clause** ("rewriting 0004 means rebasing 0009, which also touches `signal_arm64.c`"): refuted. The `grep -l signal_arm64.c` hit was the regex `.` matching `signal_arm64ec.c`; only 0004 touches `signal_arm64.c`.
- **Old #14, the author clause** ("the maintainer as author breaks the convention"): refuted. Wine 0009 (from Madeira) and 0013 (from CodeWeavers) are adapted patches with the maintainer as author (`README.md:115-118`), so the msync patch follows that precedent.
- **Old #20, the negative-control clone:** covered. §5 records a red run before the change (dbu 0,0 and `0x80090305`).
- **Old #20, §3.4's fault-driven MAP_JIT numbers:** covered. The amended native §3.4 (`:154`) cites SP3 §2, which gives the corrected 5.6 µs vs 12.8 µs.
- **Old #2:** merged into finding 1, not dropped.

## Also checked (holds)
- `licences_check.sh` gives exactly 37 MISSING on today's bundle.
- All 37 Mach-O files' `otool -L` entries, install IDs included, use allowed prefixes.
- Among the bundled unix `.so` files, only `ntdll.so` has x18 hits (`/usr/bin/grep` scan). `winemetal.so`, `libarm64ecfex.so` and the rest are clean.
- `MacOS/ntdll.so` is a link to `lib/wine/aarch64-unix/ntdll.so` (`bundle.sh:42`, `:84-85`).
- Under the restricted `PKG_CONFIG_LIBDIR`, Homebrew's `freetype-config` returns nothing, so it can't leak Homebrew's headers through Wine's fallback.
- wineserver's default timeout is 3 s (`server/main.c:47`).
- On the doc's line numbers: pre-patch `:1885` becomes patched `:1893`, as §8 says.