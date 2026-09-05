.PHONY: build test clean dmg notarize release cut

build:
	swift build --package-path app/VPNSwitch

test:
	swift test --package-path app/VPNSwitch

clean:
	swift package clean --package-path app/VPNSwitch
	rm -rf app/VPNSwitch/.build

# Builds a signed, distributable DMG (app/build/VPNSwitch-<version>.dmg).
# See app/release/make-dmg.sh for the full rationale (always builds from
# source first, ad-hoc signing refused unless ALLOW_ADHOC_DMG=1).
dmg:
	app/release/make-dmg.sh

# Submits the just-built DMG to Apple notarization, staples the ticket,
# and verifies it against Gatekeeper. See app/release/notarize-dmg.sh for
# credential setup and the full rationale. Never run as a side effect of
# `dmg` or `release` — invoked deliberately by a human operator.
notarize:
	app/release/notarize-dmg.sh

# Publishes a GitHub release: generates the update manifest (appcast.json)
# describing the just-built, notarized DMG, then uploads both as release
# assets via `gh release create`. See app/release/publish-release.sh for
# the full precondition list and rationale (never a shell literal for the
# version, working tree must be clean, tag must not already exist, DMG
# must exist and pass notarization).
#
# Deliberately NOT a dependency of `build`, `test`, `all`, or the default
# target, and not listed first in this Makefile (make's default target is
# the first target, `build`) — `make` and `make all` must never publish a
# release as a side effect. Only `make release`, invoked deliberately by a
# human operator, runs this.
release:
	app/release/publish-release.sh

# One-shot release cutter: bump version, commit, push, build, notarize,
# and publish, all in one command. See app/release/cut-release.sh for the
# full step list and failure semantics. THIS IS THE ONLY TARGET IN THIS
# MAKEFILE THAT PUSHES TO ORIGIN — none of `dmg`, `notarize`, or `release`
# above touch the remote's branches (only `release` creates a tag/release,
# never a branch push). Requires VERSION=X.Y.Z; set CUT_DRY_RUN=1 to
# preview every step without changing or publishing anything.
cut:
	@if [ -z "$(VERSION)" ]; then \
		echo "Usage: make cut VERSION=X.Y.Z" >&2; \
		exit 1; \
	fi
	app/release/cut-release.sh "$(VERSION)"
