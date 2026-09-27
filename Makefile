.PHONY: build test smoke app

APP = build/MacNeutron.app

build:
	swift build -c release

test:
	swift test

# Real Wine; see Tests/Smoke/smoke.sh for prerequisites.
smoke: build
	sh Tests/Smoke/smoke.sh

# Ad-hoc signed MacNeutron.app with the macneutron CLI inside it.
app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Helpers
	cp App/Info.plist $(APP)/Contents/Info.plist
	cp .build/release/MacNeutronApp $(APP)/Contents/MacOS/MacNeutron
	cp .build/release/macneutron $(APP)/Contents/Helpers/macneutron
	codesign --force --sign - $(APP)/Contents/Helpers/macneutron
	codesign --force --sign - $(APP)
