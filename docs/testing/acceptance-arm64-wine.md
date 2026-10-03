# Native arm64 Wine and FEX acceptance test (sub-project 1)

Spec: `docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md` §1, §8 and §10. Manual, on the
maintainer's Mac, with the Developer ID identity and the provisioning profile for `net.authspot.macneutron.wine`
(`wine-arm64/README.md`), and MacNeutron's runtime-v4.7.3 installed (G4's Rosetta baseline). GPTK is imported for
`make dxmt-check`. Record results at the bottom.

## Steps

1. **Clean build:** `rm -rf build/wine-arm64 build/wine-arm64-src && make wine-arm64`, with `MACNEUTRON_SIGN_IDENTITY` and
   `MACNEUTRON_PROVISIONING_PROFILE` set. Then `codesign --verify --strict --deep build/wine-arm64/wine.app`.
2. **Checks:** `make wine-arm64-check 2>&1 | tee build/wine-arm64-acceptance.log` (outside `build/wine-arm64 check/`, which
   every run deletes). It builds the launcher and the test programs, finds the runtime up to date, runs `mode_test` and `profile_test`, then `check.sh`.
3. **The Rosetta stack:** `make test` and `make dxmt-check`.
4. **Pass:**
   - step 1 succeeds and `codesign` verifies;
   - step 2 ends with every step `PASS`, G1, G2, G3 and G5 included, a G4 report, and `PASS orphans` (nothing of either
     runtime is left, whether the run passed or failed);
   - step 3 passes as before;
   - G4 is measured, not gated: the table, the three geometric means and the worst five rows are recorded.

## Results

| Date | Mac | macOS | Wine | FEX | Patches |
|---|---|---|---|---|---|
| 2026-10-03 | Mac17,8 (Apple M5 Pro, 48 GB) | 27.0.1 (26A434) | wine-11.19, `455e3509b98a6919fd4ad1def4803e08c41c03b2` | `4ed80fd07176dce976a7351f559d59a47b68cbae` (2026-08-26) | 12 Wine (`patches/wine`), 5 FEX (`patches/fex`) |

Repository at `0f0dbde` (the build inputs are the pins and patches in it). **All of spec §10 passes: items 1-4 below.**

**Week-1 checkpoint:** met. The x64 hello ran in Task 5 on the first try.

### 1. Clean build (§10.1)

`rm -rf build/wine-arm64 build/wine-arm64-src && make wine-arm64`: fresh shallow clones of Wine 11.19 and FEX at the
pins, 12 + 5 patches applied with `git am`, configure, build, FEX, bundle and sign; 3 min 48 s on this Mac. Ended with
`wine-arm64: built .../build/wine-arm64/wine.app`. `codesign --verify --strict --deep build/wine-arm64/wine.app`: exit 0.
`codesign -d --entitlements -` on `Contents/MacOS/wine` lists `com.apple.application-identifier`,
`com.apple.developer.cross-architecture-support` and `com.apple.developer.team-identifier`.

### 2. `make wine-arm64-check` (§10.2)

7 min 22 s. Printed, in order (the lines are `build/wine-arm64-acceptance.log`; the G2 default run's counts are not printed
there and come from the step's own log, `build/wine-arm64 check/g2-litmus.log`, shown below):

```
PASS mode_test
PASS profile_test
PASS macos
PASS signature
PASS boot
PASS pages
PASS unentitled
PASS arm64
PASS isec
PASS g3-cpu
feature LSE=1
feature LRCPC=1
feature LRCPC2=1
feature AFP=1
PASS fex
PASS g1-hello
PASS g1-seh
PASS g1-threads
PASS g1-kuser
PASS g1-smc
PASS g1-tsc
info CPUID 0x15: eax 1 ebx 1 ecx 1000000000
info QueryPerformanceFrequency 10000000 Hz; RDTSC ran at 999999976 Hz over 208.0 ms
info CPUID says 1000000000 Hz; measured / CPUID = 1.0000
PASS g1-unaligned
PASS g2-litmus
info TSO on: 8 s
info TSO off: litmus MP forbidden=12578 runs=10000000
info TSO off: litmus LB forbidden=0 runs=10000000
info TSO off: litmus 2+2W forbidden=0 runs=10000000
info TSO off: litmus IRIW forbidden=7036 runs=10000000
info TSO off: 6 s
PASS viewec
PASS wxflip
info 19 trace lines
PASS g5-jit
info x64-bench: 0 flips after the marker
PASS g4-bench
PASS orphans
```

(`PASS g4-bench` is followed by G4's lines, in §4 below, and then `PASS orphans`.)

- **Steps 0-5** (spec §7.3): `macos`, `signature`, `boot`, `pages` (5 processes of `wineboot -u` and the `arm64-hello` process, all
  `host page size: 4k`), `arm64` (`PROCESSOR_ARCHITECTURE_ARM64` = 12, `dwPageSize=4096`) and `fex` (`Wow64\amd64` =
  `libarm64ecfex.dll`) pass. Also `unentitled` (a loader re-signed without the entitlement refuses to run and names the
  missing entitlement), and `isec` and `viewec` (the bounds checks and the EC marking of mapped views, Wine patches 9
  and 11).
- **G1 Correctness:** `g1-hello`, `g1-seh` (with the C++ throw/catch test), `g1-threads` (32 threads, counter 3,200,000),
  `g1-kuser`, `g1-smc` (a fresh RWX page and the exe's own `.text`), plus `g1-tsc` and `g1-unaligned`, all `PASS` under
  FEX. `x64-hello`: `hello from x86_64`, `native machine 0xaa64`.
- **G2 Memory ordering**, 10,000,000 iterations per pattern. **Default run** (FEX's defaults; the step log):
  `litmus MP forbidden=0`, `LB forbidden=0`, `2+2W forbidden=0`, `IRIW forbidden=0`, in 8 s. The program also prints
  `MP: the reader saw flag before the writer was done in 9998823 runs` there (6117067 in the control).
  **Control run** (`FEX_TSOENABLED=0`): MP forbidden=12,578, LB 0, 2+2W 0, IRIW 7,036, in 6 s. The control sees
  violations, so the test can detect them; only MP is gated.
- **G3 CPU features:** `feature LSE=1`, `LRCPC=1`, `LRCPC2=1`, `AFP=1`: ISAR0[23:20] >= 2, ISAR1[23:20] >= 2 and
  MMFR1[47:44] >= 1 hold.
- **G5 JIT:** a full `x64-bench` run under `WINEDEBUG=+wxflip`: **0 flips after FEX's initialization**. The positive
  control `wxflip` (`arm64-wxflip`, a program that makes the flips happen) traces 19 lines, so the channel works. (Task 9's run
  before FEX's dual view had 612 flips.)
- **Orphan check (§10.4):** the last line is `PASS orphans`. A `ps` afterwards found no `wine`, `wineserver` or
  `macneutron` process of either runtime.

### 3. The Rosetta stack unchanged (§10.3)

- `make test`: `Test run with 197 tests in 0 suites passed after 21.941 seconds.`
- `make dxmt-check`: `dxmt-check: all passed` (213 `ok` lines, no failure; 5 min 53 s). The `Terminated: 15` lines it prints are
  the script's own two-minute watchdog subshells being stopped.

### 4. G4 Speed: FEX against Rosetta (measured, not gated)

`x64-bench`: the same `.exe`, 5 separate processes per side, on this Mac in this session. FEX runs on this stack;
Rosetta runs through `macneutron launch waitforexitandrun` with the pinned runtime-v4.7.3 in the `rosetta/` prefix
(the launcher's normal environment). Each cell is the median of the 5 runs, in seconds; the ratio is FEX divided by Rosetta,
so above 1 FEX is slower.

```
info run 1: fex 30 s, rosetta 37 s
info run 2: fex 31 s, rosetta 37 s
info run 3: fex 30 s, rosetta 37 s
info run 4: fex 30 s, rosetta 37 s
info run 5: fex 30 s, rosetta 37 s
info fex: cpuid sse41=1 avx=1 avx2=1 fma=1 mxcsr=0x1f80
info rosetta: cpuid sse41=1 avx=1 avx2=1 fma=1 mxcsr=0x1f80
```

Both sides saw the same CPUID features (SSE4.1, AVX, AVX2, FMA) and the same MXCSR.

| Row | FEX (s) | Rosetta (s) | FEX ÷ Rosetta |
|---|---|---|---|
| int_add_chain | 0.8034 | 0.8008 | 1.003 |
| int_mul_chain | 0.9957 | 0.9978 | 0.998 |
| int_div64 | 0.8931 | 0.9035 | 0.988 |
| popcnt | 0.7360 | 0.8514 | 0.864 |
| bitops_mix | 0.8237 | 1.0023 | 0.822 |
| branch_predictable | 0.5173 | 0.3770 | 1.372 |
| branch_random | 0.7263 | 0.7516 | 0.966 |
| cmov_select | 0.9326 | 0.8718 | 1.070 |
| indirect_calls | 0.6862 | 0.8009 | 0.857 |
| direct_calls | 0.8870 | 0.7629 | 1.163 |
| sse_scalar_f32 | 0.9893 | 0.9948 | 0.995 |
| sse_scalar_f64 | 0.9925 | 0.9941 | 0.998 |
| sse_packed_ps | 0.9700 | 0.9826 | 0.987 |
| sse_int_paddd | 0.8053 | 0.8077 | 0.997 |
| sse_shuffle | 0.7989 | 1.6065 | 0.497 |
| cvttsd2si | 0.8775 | 0.8872 | 0.989 |
| sqrtps | 0.8701 | 0.8669 | 1.004 |
| divps | 0.9803 | 0.9811 | 0.999 |
| denormal_adds | 0.8988 | 0.8487 | 1.059 |
| sse41_dpps | 0.8051 | 0.9506 | 0.847 |
| avx2_packed_ps | 0.7615 | 0.8585 | 0.887 |
| fma256_ps | 1.1599 | 0.9749 | 1.190 |
| mem_seq_read | 0.9218 | 0.4351 | 2.119 |
| mem_seq_write | 1.0047 | 0.5002 | 2.009 |
| mem_random_chase | 0.8030 | 0.8070 | 0.995 |
| rep_movsb_64MB | 0.2195 | 3.0419 | 0.072 |
| memcpy_256B_hot | 0.7837 | 0.7894 | 0.993 |
| atomic_xadd | 0.7816 | 0.7800 | 1.002 |
| atomic_cmpxchg | 0.8976 | 0.8990 | 0.998 |
| mt_xadd_4 | 0.4769 | 0.4790 | 0.996 |
| mt_xadd_8 | 1.1186 | 1.1072 | 1.010 |
| mt_spsc_ring | 0.2000 | 0.2025 | 0.988 |
| mt_memcpy_4 | 0.5778 | 0.8191 | 0.705 |
| call_chain64 | 1.1423 | 1.0720 | 1.066 |
| call_virtual | 0.9785 | 0.8047 | 1.216 |
| call_std_function | 1.0138 | 0.7385 | 1.373 |

```
geomean single-threaded=0.934 multithreaded=0.915 calls=1.212
worst: mem_seq_read=2.119 mem_seq_write=2.009 call_std_function=1.373 branch_predictable=1.372 call_virtual=1.216
ratio > 1 means FEX is slower
```

- **Geometric means:** single-threaded rows 0.934, multithreaded rows 0.915, call-heavy rows 1.212. On the single- and
  multithreaded rows FEX is about 7-9% faster than Rosetta on this suite.
- **Worst five:** `mem_seq_read` 2.119 and `mem_seq_write` 2.009 (scalar loads and stores over 64 MB; FEX's software TSO
  is the likely cause, not isolated in this run), `call_std_function` 1.373, `branch_predictable` 1.372 and `call_virtual`
  1.216. The best row, `rep_movsb_64MB` (0.072), is Rosetta's slow `rep movsb`, not a FEX strength.
- **The call-heavy geometric mean is not settled.** It moves with the code layout of the benchmark binary:
  1.106 in Task 10's first run, 1.214 after its fix round (which also made `call_chain64` really 64 deep) and 1.212 now, and
  `call_virtual` alone has read between 0.93 and 1.22 across builds (1.216 here). A few rows (`branch_random`,
  `indirect_calls`, `direct_calls`, `call_virtual`) are layout-sensitive. Read it as 1.1-1.2, not as a measurement of the
  translator's call cost to the second digit.
- This is a synthetic suite, one Mac, one session. A game's switch is decided per game from that game's own measurements
  (sub-project 9), not from these numbers.
