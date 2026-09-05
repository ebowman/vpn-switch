.PHONY: build test clean

build:
	swift build --package-path app/VPNSwitch

test:
	swift test --package-path app/VPNSwitch

clean:
	swift package clean --package-path app/VPNSwitch
	rm -rf app/VPNSwitch/.build

# release/dmg/notarize targets are added by a later bead; do NOT add them here.
