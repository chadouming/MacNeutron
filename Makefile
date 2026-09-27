.PHONY: build test smoke

build:
	swift build -c release

test:
	swift test

# Real Wine; see Tests/Smoke/smoke.sh for prerequisites.
smoke: build
	sh Tests/Smoke/smoke.sh
