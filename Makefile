.PHONY: build test smoke app bridge bridge-check presenter presenter-check dxmt dxmt-tests dxmt-check

APP = build/MacNeutron.app
# Every Windows-side binary is built with the pinned llvm-mingw (Clang); dxmt/toolchain.sh fetches it once.
MINGW_BIN = $(shell sh dxmt/toolchain.sh)
MINGW = $(MINGW_BIN)/x86_64-w64-mingw32-clang -O2 -static -s
MINGWXX = $(MINGW_BIN)/x86_64-w64-mingw32-clang++ -O2 -static -s
BRIDGE = build/bridge
PRESENTER = build/presenter

build:
	swift build -c release

test:
	swift test

# Real Wine; see Tests/Smoke/smoke.sh for prerequisites.
smoke: build
	sh Tests/Smoke/smoke.sh

# Windows helpers for the Steam bridge (docs/superpowers/specs/2026-09-28-macneutron-steam-bridge-design.md).
bridge:
	mkdir -p $(BRIDGE)/tests
	$(MINGW) -o $(BRIDGE)/steam.exe bridge/steam.c -ladvapi32
	$(MINGW) -o $(BRIDGE)/steamprobe.exe bridge/probe.c
	$(MINGW) -o $(BRIDGE)/tests/helper.exe bridge/tests/helper.c -ladvapi32 -lshell32

# steam.exe under the installed runtime (real Wine, no Steam).
bridge-check: bridge
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
# First run: about 500 MB of downloads and a 30-60 minute LLVM build; see dxmt/build.sh.
dxmt:
	sh dxmt/build.sh

# D3D12 test programs for our DXMT.
dxmt-tests:
	mkdir -p build/dxmt-tests
	$(MINGWXX) -o build/dxmt-tests/d3d12_clear.exe dxmt/tests/d3d12_clear.cpp -ld3d12 -ldxgi -luser32
	$(MINGWXX) -o build/dxmt-tests/d3d12_dxil.exe dxmt/tests/d3d12_dxil.cpp -ld3d12
	$(MINGWXX) -std=c++17 -o build/dxmt-tests/d3d12_dxil_exec.exe dxmt/tests/d3d12_dxil_exec.cpp -ld3d12 -ldxgi

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
