#!/usr/bin/env bash
# Assembles TokenMeter.app from the SwiftPM release binary and ad-hoc signs it.
#
# SwiftPM cannot produce an .app bundle, so this script does the packaging:
# a Contents/MacOS layout, Info.plist with LSUIElement (no Dock icon), and a
# code signature. Set CODESIGN_IDENTITY to sign with a Developer ID instead.
set -euo pipefail

: "${APP_NAME:?APP_NAME not set}"
: "${BUNDLE_ID:?BUNDLE_ID not set}"
: "${APP:?APP not set}"
: "${VERSION:=0.0.0}"
: "${BUILD_NUM:=1}"
: "${MIN_MACOS:=14.0}"
: "${CODESIGN_IDENTITY:=-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${ROOT_DIR}/.build/release/${APP_NAME}"
PLIST_TEMPLATE="${ROOT_DIR}/Resources/Info.plist"

if [[ ! -x "${BINARY}" ]]; then
    echo "error: release binary not found at ${BINARY}; run 'swift build -c release'" >&2
    exit 1
fi

echo "Bundling ${APP} (version ${VERSION}, build ${BUILD_NUM})"

rm -r "${APP}" 2>/dev/null || true
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BINARY}" "${APP}/Contents/MacOS/${APP_NAME}"

sed -e "s|__BUNDLE_ID__|${BUNDLE_ID}|g" \
    -e "s|__VERSION__|${VERSION}|g" \
    -e "s|__BUILD_NUM__|${BUILD_NUM}|g" \
    -e "s|__MIN_MACOS__|${MIN_MACOS}|g" \
    "${PLIST_TEMPLATE}" > "${APP}/Contents/Info.plist"

/usr/bin/plutil -lint "${APP}/Contents/Info.plist" >/dev/null

# Ad-hoc by default. Note for contributors: ad-hoc signatures change on every
# rebuild, which macOS treats as a new app for Keychain ACL purposes, so the
# first credential read after a rebuild may prompt.
codesign --force --sign "${CODESIGN_IDENTITY}" --identifier "${BUNDLE_ID}" --timestamp=none "${APP}"
codesign --verify --strict "${APP}"

echo "Built ${APP}"
