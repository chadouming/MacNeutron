.PHONY: build test smoke app bridge bridge-check

APP = build/MacNeutron.app
MINGW = x86_64-w64-mingw32-gcc -O2 -static -s
BRIDGE = build/bridge

build:
	swift build -c release

test:
	swift test

# Real Wine; see Tests/Smoke/smoke.sh for prerequisites.
smoke: build
	sh Tests/Smoke/smoke.sh

# Windows helpers for the Steam bridge (docs/superpowers/specs/2026-09-28-macneutron-steam-bridge-design.md).
bridge:
	@command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "bridge: needs brew install mingw-w64" >&2; exit 1; }
	mkdir -p $(BRIDGE)/tests
	$(MINGW) -o $(BRIDGE)/steam.exe bridge/steam.c -ladvapi32
	$(MINGW) -o $(BRIDGE)/steamprobe.exe bridge/probe.c
	$(MINGW) -o $(BRIDGE)/tests/helper.exe bridge/tests/helper.c -ladvapi32 -lshell32

# steam.exe under the installed runtime (real Wine, no Steam).
bridge-check: bridge
	sh bridge/check.sh

# Ad-hoc signed MacNeutron.app with the macneutron CLI inside it.
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Helpers
	cp App/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/MacNeutronApp $(APP)/Contents/MacOS/MacNeutron
	cp .build/release/macneutron $(APP)/Contents/Helpers/macneutron
	codesign --force --sign - $(APP)/Contents/Helpers/macneutron
	codesign --force --sign - $(APP)
