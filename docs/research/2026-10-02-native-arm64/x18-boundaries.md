I've designed the contract-correct handling, (b), and my recommendation is phased: use (a) for bring-up now and ship (b). Everything was read-only. No Wine processes were started, nothing was built, and nothing was created under `build/arm64/entitled/` because no files were needed. Two short lldb probes on an ad-hoc `flex` process were killed afterwards, and no probe processes are left. Scan outputs are in the scratchpad under `x18scan/`.

**How x18 mode works on macOS 27.0.1** (all VERIFIED by reading source or disassembling)
- **Who gets the mode.** The cross-architecture entitlement makes a process eligible to toggle x18 (`machine_task.c:333-337`). New threads start OFF (`pcb.c:703`), and the mode is a single bit, bit 48 of TPIDR_EL0 (`machine_machdep.h:59-60`).
- **OFF zeroes x18 constantly.** On every exception return the kernel does `mov x18,#0` and reloads the saved x18 only if the bit is ON at that moment (`locore.s:1918-1922`). So with the mode OFF, x18 is zeroed by any interrupt, syscall or signal return. Any assembly that keeps x18 live while OFF will crash intermittently.
- **Signals don't change the mode.** Delivery leaves it alone, so a handler runs in whatever mode was interrupted (Apple's test `tests/x18_toggle.c:135-150` enters its handler ON). `sigreturn` does not restore it either (`x18_toggle.c:199` asserts it stays OFF after the handler turned it off). A handler that sends execution into PE code must turn ON itself, or the `x18 = teb` it wrote into the saved context is silently dropped.
- **Apple already ships "ON for the whole thread".** Every arm64 app built against an SDK older than macOS 13 runs that way (`machine_task.c:347-354`). Apple labels that "Temporary override". Apple's own toggle test also calls `usleep()` while ON (`x18_toggle.c:86-99`).
- **What a toggle costs** (from disassembling the live macOS 27.0.1 code):
  - `os_set_custom_x18_abi_enabled` is 14 instructions, then a tail call into a commpage routine at `0xfffe642a4` of about 16 instructions.
  - In total that is about 31 instructions: 2 `mrs` and 1 `msr` of TPIDR_EL0, 5 pointer-authentication operations, two small stack frames, and no syscall.
  - The commpage routine zeroes x15 itself, so a syscall (`svc` pfz_exit) only happens after a deferred preemption. The XNU source copy in the scratchpad (`commpage_asm.s:516`) lacks that zeroing, so it is older than this build.
  - Toggling to the current state hits `brk #1` with the annotation "attempted to switch to already enabled/disabled custom x18 ABI mode".
  - Estimated cost is 5-20 ns per toggle (INFERRED until benchmarked).

**Every PE↔unix transition in Wine 11.19** (`dlls/ntdll/unix/signal_arm64.c` unless noted)

| # | Transition | Direction | Is x18 saved/restored? | Where the toggle goes |
|---|---|---|---|---|
| 1 | Syscall dispatcher `:1722`, used by aarch64 and ARM64EC stubs (`include/wine/asm.h:250-270`) | PE→unix | Saved to the frame at `:1725` | Assembly: turn OFF after the `kernel_stack` label (`:1772`), before the argument-copy loop (`:1784-1792`) |
| 2 | Unix-call dispatcher `:1893` (ARM64EC is redirected into it at `unix/loader.c:1585-1589`) | PE→unix | Saved at `:1897` | Assembly: turn OFF after the label at `:1926` |
| 3 | Return path `:1800`→`ret x16` `:1852`; unix-call fast return `:1935-1940` | unix→PE | Reloaded from the frame at `:1819` / `:1935` | Assembly: turn ON after both `raise()` slow paths (`:1803`, `:1810`, which are libc and must run OFF) and before the x18 reload |
| 3a | Covered by row 3, no toggle of their own: thread start (`signal_start_thread` `:1683` → `init_syscall_frame` `:1616`, frame x18 = teb at `:1673`), APCs `:806`, exceptions raised from syscalls `:846`/`:855`, `NtContinue` (`unix/server.c:839`) → `signal_set_full_context` `:366`, `NtRaiseException` (`unix/thread.c:1665`) | unix→PE | Frame x18 = TEB; `NtSetContextThread` skips x18 (`:434`) | None |
| 4 | User callback `call_user_mode_callback` `:880` → `br x3` `:924` | unix→PE | Set from the teb argument at `:907` | Assembly: turn ON just before `mov sp,x0` at `:922`, after `trace_usercall` (`:932`) |
| 4a | `NtCallbackReturn` `:1052` → `user_mode_callback_return` `:944` | PE→unix | — | The OFF from row 1 is matched by the ON of the outer syscall's return; this frame never exits through row 3 |
| 5 | Signal handlers that redirect into PE: `setup_raise_exception` `:772` (x18 written at `:799`), `restore_context` `:335`/`:347`, `usr2_handler` `:1491` (`:1509`, `:1519`) | unix→PE | Saved context holds x18 | C: turn ON before the handler returns |
| 6 | Signal handlers that redirect into unix: `handle_syscall_fault` → `longjmp` `:1109` or dispatcher return `:1119`; `quit_handler` `:1376` → abort (never returns) | unix→unix | — | Stay OFF |
| 7 | Entry to all 9 handlers registered at `:1578-1596` (segv/bus `:1131`, ill `:1181`, trap `:1213`, fpe `:1280`, int `:1341`, abrt `:1357`, quit `:1376`, usr1 `:1416`, usr2 `:1491`) | PE→unix | Saved context holds x18 (INFERRED: kernel copies it at delivery) | C wrapper: if ON, turn OFF before any libc call |
| 8 | Suspend/resume: `usr1_handler` `:1416`, including its program-counter fixups `:1430-1451` and the ARM64EC cooperative-suspend branch `:1458-1465`. Resume = handler return, or `usr2` via the slow path | Either | Saved context | Keep the entry mode |
| 9 | ARM64EC emulator: `KiUserEmulationDispatcher` (`signal_arm64ec.c:1270`), emulated syscalls via `dispatch_syscall` `:1281` → row 1, BeginSimulation | PE↔PE | Unchanged | None — no new boundary |

**Design (b): strict toggling at every boundary**
- **Syscall entry.** At the label, still ON:
  - Compute the service-table pointer from `[x18,#0x370]` and the trace flag from `[x18,#0x380]` into callee-saved registers (moved up from `:1777` and `:1795`).
  - Spill x0-x7 to the kernel stack below the frame, not into `frame->x[]`. A suspend during this window can run `NtSetContextThread`, which writes `frame->x[]` (`:433-436`) and would corrupt the live arguments.
  - Turn OFF, then reload x0-x7, x8 from `[frame,#0x120]` and x11 from `[frame,#0xf8]`.
  - Placing the OFF here means the suspend handler's redirect (`:1435`) still resumes in the ON part. It also means the argument-copy loop, the only instruction that can fault, runs OFF, so `handle_syscall_fault`'s redirect lands in OFF code that turns ON itself.
- **Syscall return.** After the slow-path checks: park x0 and x16 in x19/x20 (both reloaded at `:1819-1820`), turn ON, restore them, re-test CONTEXT_INTEGER, then the existing reloads.
- **Unix-call dispatcher.**
  - Entry: park x0-x2 in x20-x22 (saved at `:1898-1899`), turn OFF.
  - Fast return: park x0 in x20, turn ON, reload x20-x23 from the frame, then the existing `ldp x18,x19` at `:1935`. Don't use x19 as scratch; after `:1927` it carries the unwind (CFA) information.
- **x18 reads that would run while OFF must go**:
  - `:1777` and `:1795`: moved to before the toggle, as above.
  - `:1885`: read the TEB from `[sp,#0x90]` instead.
  - `:907-919` and `:933`: use the x4 teb argument; set x18 only after turning ON. The new sequence is `mov x19,x4; mov x20,x0; mov x21,x3`, turn ON, `mov x18,x19; mov sp,x20; br x21`. Update the suspend fixup at `:1451` to read register 21 instead of 3.
- **Signal handler wrapper:**
```c
#define X18_WRAP(h, keep) static void h##_x18( int sig, siginfo_t *si, void *ctx ) {      \
    ucontext_t *uc = ctx; ULONG_PTR pc = PC_sig(uc), sp = SP_sig(uc);                        \
    BOOL was_on = os_custom_x18_abi_enabled(), on; struct thread_data *data;                 \
    if (was_on) os_set_custom_x18_abi_enabled( false );   /* before any libc call */         \
    h( sig, si, ctx );                                                                        \
    data = get_thread_data();                                                                 \
    if (keep || (PC_sig(uc) == pc && SP_sig(uc) == sp) || !data || !data->teb) on = was_on;  \
    else on = PC_sig(uc) == (ULONG_PTR)pKiUserExceptionDispatcher ||                          \
              PC_sig(uc) == (ULONG_PTR)pKiUserEmulationDispatcher ||                          \
              !is_inside_syscall( data, SP_sig(uc) );                                         \
    if (on) os_set_custom_x18_abi_enabled( true );  /* kernel reloads saved x18 only if ON */ }
```
  `keep` is 1 for usr1 and int, 0 for the other seven. Point the registrations at `:1578-1596` to the `_x18` versions.
- **Build:** the API is marked available from macOS 26.4, so `ntdll.so` needs deployment target ≥ 26.4, or a weak import plus `__builtin_available`.
- **Size:** about 80-100 lines, all in `signal_arm64.c`. Runtime cost is two toggles plus about 10 extra instructions per syscall or unix-call round trip, and two toggles per signal. At 100k transitions/s and ~20 ns that is about 0.2% of one core (INFERRED).

**Design (a): turn it ON once per thread**
```c
    pthread_sigmask( SIG_UNBLOCK, &server_block_set, NULL );   /* signal_arm64.c:1676 */
#ifdef __APPLE__
    if (!os_custom_x18_abi_enabled()) os_set_custom_x18_abi_enabled( true );
#endif
```
Every thread that runs PE code passes through here (`server.c:1771` for the main thread, `:1805` for the rest). The kernel then preserves x18 for the life of the thread (`locore.s:1920-1921`, `pcb.c:379-412`), so the existing assembly works unchanged.

**Does any Apple library use x18?** (VERIFIED)
- **Libraries a DXMT game process actually runs:** I disassembled 49 images and found no code that touches x18.
  - That covers libSystem and its `system/` parts, objc, libc++, libdispatch, Metal, CoreFoundation, Foundation, AppKit, IOKit, IOSurface, QuartzCore, CoreGraphics, CoreAudio, AudioToolbox, CoreVideo, Security, GameController, CoreText and HIToolbox.
  - It also covers all 14 AGX Metal driver bundles, MTLCompiler, GPUCompiler, MetalFX and IOGPU.
  - The only real code there is libunwind saving x18 and later restoring that same thread's saved value. That is harmless in both modes.
- **Whole shared cache:** 4,086 of 4,088 images, scanned in 186 s. The two skipped are iOSSupport accessibility bundles with spaces in their paths. It found 1,021 textual matches:
  - **Lookup tables decoded as instructions:** libm, the SHA-256 constant table in corecrypto/dyld/MobileGestalt/BootabilityBrain, OpenSSL-style tables in libwebrtc/CryptexServer, and a data symbol in libsystem_platform. I classified these by their neighbours (SVE/SME instructions, `udf`, nonsense like `str b21,[x18,…]`), e.g. libm `_exp` at `0x1913FB718`.
  - **Real code:** UEFI firmware modules in EfiSupport (they save and restore x18; apps don't load them), libunwind context save/restore, libswiftRuntime `__swift_get_cpu_context` (a read-only capture), and the JavaScriptCore probe trampoline.
  - No code anywhere uses x18 as a pointer or depends on its value.

**Risks of (a)**
- **It breaks the documented contract.** The SDK header (`os/arch/arm64.h:78-82`) forbids calling any macOS library code while the mode is ON. Under (a), libc, Metal, AppKit and MoltenVK all run ON.
- **Today nothing breaks.** The scan is clean, and the kernel gives x18 no meaning in userland except zeroing it.
- **What could break later** (INFERRED): the header says turning the mode off restores x18's "system-defined operating semantics" (`:75-76`, `:107-115`). If Apple ever gives x18 a kernel-managed value, such as a shadow call stack pointer, every framework call on an always-ON Wine thread would see the TEB there instead. That would be silent corruption, and not a regression from Apple's point of view. The "Temporary" legacy path is the only thing holding that back, and a scan can't see a future change in advance.

**Risks of (b)**
- **Any unbalanced path traps.** A missed site means `brk #1`. That is loud, not silent.
- **Async windows.** Signals can land between a toggle and the register restore; the keep-or-destination rule above handles them, but it needs the S2/S3 stress tests.
- **Rebase cost.** `signal_arm64.c` changes upstream, so this is ongoing merge work.
- **Still not fully contract-pure.** Apple's `_sigtramp` and any third-party signal handlers run in the interrupted mode. Apple's own test does the same, so this is sanctioned.
- **Effect on a future emulator JIT.** Under (b), PE-side JIT code can't call `pthread_jit_write_protect_np` directly; that has to be a unix call. The planned mprotect-based W^X flipping on the unix side is unaffected.

**Microbenchmark plan**
```
x18bench.c: entitled bundle via scratchpad/xarch/mkbundle.sh (same ent.plist), clang -O2 -mmacosx-version-min=26.4
 1 Run once at QOS_CLASS_USER_INTERACTIVE (P-core), once at QOS_CLASS_BACKGROUND (E-core)
 2 clock_gettime_nsec_np(CLOCK_UPTIME_RAW) around N=10M iterations; 21 trials; report median and p99
 3 Cycles/ns calibration: 1e9-long dependent add chain
 4 Loops written in asm; 200 ms warm-up per case; thread starts OFF
 5 C0 empty bl/ret loop (call floor)
 6 C1 os_custom_x18_abi_enabled()
 7 C2 os_set(true)+os_set(false) pair; per toggle = (C2 - 2*C0)/2
 8 C3 C2 plus reloading x18 from memory after ON
 9 C4 syscall-entry spill alone: stp/ldp x0-x7 below a 0x330 frame
10 C5 return-path park/unpark of x0/x16 alone
11 C6 model of today's dispatcher: save x18-x30 and q0-q31, switch sp, blr to empty C, restore
12 C7 C6 plus toggles at the (b) positions; report absolute and % delta vs C6
13 C8 references: getpid(), pthread_getspecific(), mach_absolute_time()
14 S1 2x hw.ncpu CPU spinners while running C2 for 10 s; histogram >1 us outliers (pfz_exit / preemption)
15 S2 60 s under S1: ON; x18=magic; spin 1 us; check x18==magic; OFF; check mode reads OFF;
16    usleep(0); check x18==0. Expect 0 failures
17 S3 ITIMER_PROF at 50 us with an X18_WRAP'd keep-mode handler during S2, plus a handler that
18    redirects PC to a resume stub and must exit ON. Expect 0 failures, no brk
19 S4 raise(SIGUSR2) loop: empty handler vs wrapped handler = per-signal cost of the wrapper
20 S5 pthread_create from an ON thread; child must read OFF
21 S6 in a child process: toggle to the current state; expect brk #1 and the crash annotation string
22 In-Wine A/B, builds (a) and (b) under build/arm64/entitled:
23 W1 PE loop of 10M NtQuerySystemTime (cheap unix syscall)
24 W2 PE loop of 10M __wine_unix_call to a no-op unix function
25 W3 KeUserModeCallback round trip (SendMessage to own window)
26 W4 W^X flip fault (execute after write on an RWX page): toggles should be noise next to mprotect
27 W5 DXMT title: frame time p50/p99 over 60 s, 3 runs each
28 Pass if: per toggle <= 10 ns median on a P-core; (b) adds <= 30 ns per W1/W2 round trip
29          and <= 1% to DXMT p50; S2/S3 have 0 failures; S6 traps exactly as the disassembly predicts
30 If over budget: re-check C4/C5 vs C2 to see whether spills or the toggle dominate
```

**Recommendation**
- **Now, for bring-up: (a).** It is one guarded call and is exactly what macOS already does for older apps. It unblocks the W^X, page-zero and KUSER work today.
- **For shipping: (b).** It costs about 80-100 lines in one file and roughly 10-40 ns per round trip. Mistakes show up as an immediate `brk` trap rather than silent corruption after a macOS update. Apple granted the capability under this contract, and it labels the behaviour (a) relies on as temporary.
- **Either way:** rerun the 186-second cache scan on every macOS beta as an early warning.