SHELL := /bin/bash

APP_NAME    := TokenMeter
BUNDLE_ID   := com.dylanhu.TokenMeter
BUILD_DIR   := build
APP         := $(BUILD_DIR)/$(APP_NAME).app
MIN_MACOS   := 14.0

VERSION     := $(shell git describe --tags --always --dirty 2>/dev/null || echo 0.1.0)
BUILD_NUM   := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

# SwiftUI's @State macro ships with the Xcode toolchain, not the Command Line
# Tools. When Xcode is installed, prefer it so `swift build` works either way.
XCODE_DEVELOPER := /Applications/Xcode.app/Contents/Developer
ifneq ($(wildcard $(XCODE_DEVELOPER)),)
DEVELOPER_DIR ?= $(XCODE_DEVELOPER)
export DEVELOPER_DIR
TOOLCHAIN_NOTE := using $(DEVELOPER_DIR)
endif

.PHONY: all build release test lint format lint-fix bundle run install uninstall clean check setup help snapshot

all: check

help:
	@echo "TokenMeter — macOS menu bar app for LLM API spend"
	@echo
	@echo "  make build     Debug build"
	@echo "  make release   Release build"
	@echo "  make test      Run the test suite"
	@echo "  make lint      SwiftFormat + SwiftLint checks (no writes)"
	@echo "  make format    Apply SwiftFormat and safe SwiftLint fixes"
	@echo "  make check     Format check + lint + tests (pre-push gate)"
	@echo "  make bundle    Build TokenMeter.app into build/"
	@echo "  make run       Bundle and launch"
	@echo "  make install   Bundle and copy into /Applications"
	@echo "  make setup     Install development tooling (brew)"
	@echo "  make snapshot  Render UI screenshots to docs/ (no display needed)"
	@echo "  make clean     Remove build products"
	@echo
	@echo "Toolchain: $(if $(TOOLCHAIN_NOTE),$(TOOLCHAIN_NOTE),Command Line Tools only — SwiftUI macros may fail; install Xcode)"

build:
	swift build

release:
	swift build -c release

test:
	swift test

lint:
	@command -v swiftformat >/dev/null 2>&1 || { echo "error: swiftformat missing — run 'make setup'"; exit 1; }
	@command -v swiftlint  >/dev/null 2>&1 || { echo "error: swiftlint missing — run 'make setup'"; exit 1; }
	swiftformat --lint .
	swiftlint lint --quiet --strict

format:
	swiftformat .
	swiftlint lint --fix --quiet || true

lint-fix: format

check: lint test
	@echo "All checks passed."

snapshot: build
	@mkdir -p docs/screenshots
	./.build/debug/$(APP_NAME) --snapshot docs/screenshots/popover-dark.png --appearance dark
	./.build/debug/$(APP_NAME) --snapshot docs/screenshots/popover-light.png --appearance light
	./.build/debug/$(APP_NAME) --snapshot docs/screenshots/onboarding.png --view empty --appearance dark
	./.build/debug/$(APP_NAME) --snapshot docs/screenshots/settings.png --view settings --appearance light

bundle: release
	@VERSION="$(VERSION)" BUILD_NUM="$(BUILD_NUM)" MIN_MACOS="$(MIN_MACOS)" \
		APP_NAME="$(APP_NAME)" BUNDLE_ID="$(BUNDLE_ID)" APP="$(APP)" \
		./scripts/bundle.sh

run: bundle
	open "$(APP)"

install: bundle
	@rm -r "/Applications/$(APP_NAME).app" 2>/dev/null || true
	cp -R "$(APP)" /Applications/
	@echo "Installed to /Applications/$(APP_NAME).app"

uninstall:
	@rm -r "/Applications/$(APP_NAME).app" 2>/dev/null || true
	@echo "Removed /Applications/$(APP_NAME).app"

setup:
	brew install swiftformat swiftlint

clean:
	swift package clean
	@rm -r "$(BUILD_DIR)" 2>/dev/null || true
