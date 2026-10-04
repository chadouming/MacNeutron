.PHONY: build test smoke app bridge bridge-check presenter presenter-check dxmt dxmt-tests dxmt-tests-arm64ec dxmt-check dxil-corpus wine-arm64 wine-arm64-export wine-arm64-tests wine-arm64-check

APP = build/MacNeutron.app
# Every Windows-side binary is built with the pinned llvm-mingw (Clang); dxmt/toolchain.sh fetches it once.
MINGW_BIN = $(shell sh dxmt/toolchain.sh)
MINGW = $(MINGW_BIN)/x86_64-w64-mingw32-clang -O2 -static -s
MINGWXX = $(MINGW_BIN)/x86_64-w64-mingw32-clang++ -O2 -static -s
MINGW_A64 = $(MINGW_BIN)/aarch64-w64-mingw32-clang -O2 -static -s
BRIDGE = build/bridge
PRESENTER = build/presenter

build:
	swift build -c release

test:
	swift test

# Real Wine; see Tests/Smoke/smoke.sh for prerequisites.
smoke: build
	sh Tests/Smoke/smoke.sh

# Windows helpers for the Steam bridge (docs/superpowers/specs/2026-09-28-macneutron-steam-bridge-design.md), and
# steam.exe and its test helper for the arm64 runtime in $(BRIDGE)/arm64 (ship-base spec §7: neither steam.exe runs
# on the other runtime). steamprobe.exe stays x64: it runs under FEX there.
bridge:
	mkdir -p $(BRIDGE)/tests $(BRIDGE)/arm64/tests
	$(MINGW) -o $(BRIDGE)/steam.exe bridge/steam.c -ladvapi32
	$(MINGW) -fms-extensions -o $(BRIDGE)/steamprobe.exe bridge/probe.c
	$(MINGW) -o $(BRIDGE)/tests/helper.exe bridge/tests/helper.c -ladvapi32 -lshell32
	$(MINGW_A64) -o $(BRIDGE)/arm64/steam.exe bridge/steam.c -ladvapi32
	$(MINGW_A64) -o $(BRIDGE)/arm64/tests/helper.exe bridge/tests/helper.c -ladvapi32 -lshell32

# steam.exe under the installed runtime (real Wine, no Steam).
bridge-check: bridge
	sh bridge/probe.sh --redact-self-test
	sh bridge/check.sh

# MetalFX presenter (docs/superpowers/specs/2026-09-28-macneutron-metalfx-upscaler-design.md) and its test program.
presenter:
	mkdir -p $(PRESENTER)
	clang -arch x86_64 -arch arm64 -fobjc-arc -O2 -dynamiclib -framework Foundation -framework AppKit \
		-framework QuartzCore -framework Metal -framework MetalFX \
		-o $(PRESENTER)/libmacneutron-present.dylib presenter/present.m
	$(MINGW) -o $(PRESENTER)/present_loop.exe presenter/tests/present_loop.c -ld3d11 -ldxgi -luser32 -lgdi32 -ldxguid -luuid

# The presenter under the installed runtime on D3DMetal (real Wine, no Steam).
presenter-check: presenter
	sh presenter/check.sh

# MacNeutron's DXMT fork with Direct3D 12 (docs/superpowers/specs/2026-09-28-macneutron-dxmt-fork-design.md).
# First run: about 500 MB of downloads and a few minutes of LLVM build; see dxmt/build.sh.
dxmt:
	sh dxmt/build.sh

# D3D12 test programs for our DXMT, built in parallel (one compiler per core).
DXMT_TESTS = $(patsubst dxmt/tests/%.cpp,build/dxmt-tests/%.exe,$(wildcard dxmt/tests/d3d12_*.cpp))
dxmt-tests:
	mkdir -p build/dxmt-tests
	$(MAKE) -s -j$(shell sysctl -n hw.ncpu) $(DXMT_TESTS)
build/dxmt-tests/%.exe: dxmt/tests/%.cpp dxmt/tests/d3d12_common.hpp
	$(MINGWXX) -std=c++17 -o $@ $< -ld3d12 -ldxgi -luser32 -lpsapi

# The same programs and present_loop for ARM64EC, for the arm64 runtime (arm64 DXMT spec §7), built in parallel.
MINGW_EC = $(MINGW_BIN)/arm64ec-w64-mingw32-clang -O2 -static -s
MINGWXX_EC = $(MINGW_BIN)/arm64ec-w64-mingw32-clang++ -O2 -static -s
DXMT_TESTS_EC = $(patsubst dxmt/tests/%.cpp,build/dxmt-tests-arm64ec/%.exe,$(wildcard dxmt/tests/d3d12_*.cpp)) \
	build/dxmt-tests-arm64ec/present_loop.exe
dxmt-tests-arm64ec:
	mkdir -p build/dxmt-tests-arm64ec
	$(MAKE) -s -j$(shell sysctl -n hw.ncpu) $(DXMT_TESTS_EC)
build/dxmt-tests-arm64ec/%.exe: dxmt/tests/%.cpp dxmt/tests/d3d12_common.hpp
	$(MINGWXX_EC) -std=c++17 -o $@ $< -ld3d12 -ldxgi -luser32 -lpsapi
build/dxmt-tests-arm64ec/present_loop.exe: presenter/tests/present_loop.c
	$(MINGW_EC) -o $@ $< -ld3d11 -ldxgi -luser32 -lgdi32 -ldxguid -luuid

# Translate a folder of captured DXIL shaders offline (DIR=~/dxil-smite2); never commit a game's shaders.
dxil-corpus: dxmt
	build/dxmt/dxil-translate "$(DIR)"

# Our DXMT under the installed runtime (real Wine, no Steam); see dxmt/check.sh.
dxmt-check: build dxmt presenter dxmt-tests
	sh dxmt/tests/build_test.sh
	sh dxmt/check.sh

# Ad-hoc signed MacNeutron.app with the macneutron CLI inside it.
app: build bridge presenter dxmt
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Helpers
	cp App/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/MacNeutronApp $(APP)/Contents/MacOS/MacNeutron
	cp .build/release/macneutron $(APP)/Contents/Helpers/macneutron
	mkdir -p $(APP)/Contents/Resources
	cp $(BRIDGE)/steam.exe $(APP)/Contents/Resources/steam.exe
	codesign --force --sign - $(APP)/Contents/Helpers/macneutron
	mkdir -p $(APP)/Contents/Frameworks
	cp $(PRESENTER)/libmacneutron-present.dylib $(APP)/Contents/Frameworks/libmacneutron-present.dylib
	codesign --force --sign - $(APP)/Contents/Frameworks/libmacneutron-present.dylib
	sh dxmt/published.sh build/dxmt-src/dxmt $$(cat build/dxmt/version)
	mkdir -p $(APP)/Contents/Resources/DXMT $(APP)/Contents/Frameworks/DXMT
	cp -R build/dxmt/x86_64-windows build/dxmt/i386-windows build/dxmt/version \
		build/dxmt/COPYING.LIB build/dxmt/LICENSE build/dxmt/LICENSE.OLD $(APP)/Contents/Resources/DXMT/
	cp -R build/dxmt/x86_64-unix $(APP)/Contents/Frameworks/DXMT/
	for f in $(APP)/Contents/Frameworks/DXMT/x86_64-unix/*; do codesign --force --sign - "$$f"; done
	codesign --force --sign - $(APP)

# Native arm64 Wine 11.19 with our patches, FEX for x64 code and our DXMT for ARM64X
# (docs/superpowers/specs/2026-10-02-macneutron-native-arm64-design.md §5, §6; 2026-10-03-macneutron-arm64-dxmt-design.md).
# First run: shallow clones of Wine, FEX and DXMT, an arm64 LLVM build and some compiling; see wine-arm64/build.sh.
wine-arm64:
	sh wine-arm64/build.sh

# Commits made in build/wine-arm64-src/wine, fex and dxmt back into wine-arm64/patches/wine, fex and dxmt.
wine-arm64-export:
	sh wine-arm64/export.sh

# Test programs for the arm64 stack, built in parallel. The file name's prefix picks the compiler (arm64-, arm64ec-,
# x64-); a program that needs more flags sets WA_FLAGS_<name> (arm64ec-viewec: -lonecore), which comes last. x64-bench, a
# benchmark (gate G4), is built -O2: the later -O wins. winshot is a Mac program: it reads a window's pixels off the screen.
WA_TESTS = $(patsubst wine-arm64/tests/%.c,build/wine-arm64-tests/%.exe,$(wildcard wine-arm64/tests/*.c)) \
	$(patsubst wine-arm64/tests/%.cpp,build/wine-arm64-tests/%.exe,$(wildcard wine-arm64/tests/*.cpp))
WA_FLAGS = -O1 -fms-extensions -D_WIN32_WINNT=0x0A00
WA_FLAGS_arm64ec-viewec = -lonecore
WA_FLAGS_x64-bench = -O2
WA_FLAGS_arm64-fonts-tls = -lgdi32 -lsecur32 -ldwrite -lcrypt32
WA_FLAGS_arm64-x18v = -lntdll
WA_FLAGS_arm64-x18path = -lntdll
wine-arm64-tests:
	mkdir -p build/wine-arm64-tests
	$(MAKE) -s -j$(shell sysctl -n hw.ncpu) $(WA_TESTS) build/wine-arm64-tests/x64-x18path.exe build/wine-arm64-tests/winshot
build/wine-arm64-tests/arm64-%.exe: wine-arm64/tests/arm64-%.c
	$(MINGW_BIN)/aarch64-w64-mingw32-clang $(WA_FLAGS) -o $@ $< $(WA_FLAGS_$(basename $(@F)))
build/wine-arm64-tests/arm64ec-%.exe: wine-arm64/tests/arm64ec-%.c
	$(MINGW_BIN)/arm64ec-w64-mingw32-clang $(WA_FLAGS) -o $@ $< $(WA_FLAGS_$(basename $(@F)))
build/wine-arm64-tests/x64-%.exe: wine-arm64/tests/x64-%.c
	$(MINGW_BIN)/x86_64-w64-mingw32-clang $(WA_FLAGS) -o $@ $< $(WA_FLAGS_$(basename $(@F)))
build/wine-arm64-tests/x64-%.exe: wine-arm64/tests/x64-%.cpp
	$(MINGW_BIN)/x86_64-w64-mingw32-clang++ $(WA_FLAGS) -static -o $@ $< $(WA_FLAGS_$(basename $(@F)))
# arm64-x18path's source built for x64 too: its paths under FEX (ship-base spec §9, T2).
build/wine-arm64-tests/x64-x18path.exe: wine-arm64/tests/arm64-x18path.c
	$(MINGW_BIN)/x86_64-w64-mingw32-clang $(WA_FLAGS) -o $@ $< $(WA_FLAGS_arm64-x18path)
build/wine-arm64-tests/winshot: wine-arm64/tools/winshot.c
	/usr/bin/clang -O1 -o $@ $< -framework CoreGraphics -framework ImageIO -framework CoreFoundation

# The arm64 runtime on this Mac: boots, runs native ARM64 code, leaves nothing behind (spec §7.3). Needs
# MACNEUTRON_SIGN_IDENTITY and MACNEUTRON_PROVISIONING_PROFILE (the build signs the runtime), and for gate G4's
# Rosetta baseline an installed runtime-v4.7.3, run by the launcher `build` makes; the dxmt-* steps' D3DMetal reference
# also needs GPTK imported into it and its tarball cached (dxmt/check.sh).
wine-arm64-check: build bridge wine-arm64 wine-arm64-tests dxmt dxmt-tests presenter dxmt-tests-arm64ec
	sh wine-arm64/tests/mode_test.sh
	sh wine-arm64/tests/profile_test.sh
	sh wine-arm64/tests/licences_test.sh build/wine-arm64/wine.app
	sh wine-arm64/tests/licences_test.sh --self-test build/wine-arm64/wine.app
	sh wine-arm64/check.sh
