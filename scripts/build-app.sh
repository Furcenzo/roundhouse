#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Furcenzo
# Part of mac-app-kit (shared scripts of the Furcenzo Mac apps): change it there and run its sync.sh, not here.
#
# Builds the release version and packages it as build/<APP_NAME>.app (names and IDs come from app.conf).
#   VERSION=1.2.3      version written to Info.plist (default 0.1.0)
#   UNIVERSAL=1        build for both Apple silicon and Intel (used for public releases)
#   SIGN_IDENTITY=…    code signing identity; default: "<APP_NAME> Local Dev" when it exists in the keychain
#                      (see scripts/setup-dev-signing.sh), otherwise ad-hoc ("-")
#   CHANNEL=release    the real app (BUNDLE_ID, APP_NAME) – used by release.sh and install-local.sh.
#                      Default "dev" (when app.conf has DEV_CHANNEL=1): bundle ID BUNDLE_ID.dev, name
#                      "<APP_NAME> Dev", so development builds never stand in for the installed app (login item,
#                      Spotlight, LaunchServices pick an app by its bundle ID) and keep their own permissions.
#   OUTPUT_DIR=…       where the .app goes (default build; releases use build/release so they don't
#                      replace the development app the permissions belong to)
#
# Why the signature matters: macOS remembers privacy permissions (Accessibility, Screen Recording, files…) per
# code signature. With an ad-hoc signature every build looks like a new app and asks for them again.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/app-config.sh

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$(dev_identity)" || {
        SIGN_IDENTITY="-"
        echo "warning: no \"$DEV_IDENTITY\" certificate – signing ad-hoc, so macOS forgets the app's" >&2
        echo "         permissions after every build. Run scripts/setup-dev-signing.sh once." >&2
    }
fi

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/$EXECUTABLE"

APP="${OUTPUT_DIR:-build}/$APP_BUNDLE"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"

# App icon (drawn by scripts/make-icon.sh)
ICON_KEY=""
if [[ -f "$ICON_ICNS" ]]; then
    cp -f "$ICON_ICNS" "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

# Translations (English is the development language, see CLAUDE.md)
LOCALIZATIONS=()
for lproj in "$RESOURCES"/*.lproj(N); do
    cp -R "$lproj" "$APP/Contents/Resources/"
    LOCALIZATIONS+=("<string>$(basename "$lproj" .lproj)</string>")
done

VERSION="${VERSION:-0.1.0}"
if [[ "${CHANNEL:-dev}" == "release" || "$DEV_CHANNEL" != "1" ]]; then
    DISPLAY_NAME="$APP_NAME"
else
    BUNDLE_ID="$BUNDLE_ID.dev"
    DISPLAY_NAME="$APP_NAME Dev"
fi
AGENT_KEY=""
[[ "$AGENT_APP" == "1" ]] && AGENT_KEY="<key>LSUIElement</key><true/>"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    ${ICON_KEY}
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array>${(j::)LOCALIZATIONS}</array>
    <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
    <key>LSApplicationCategoryType</key><string>${CATEGORY}</string>
    ${AGENT_KEY}
    <key>NSHumanReadableCopyright</key><string>${COPYRIGHT}</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    ${INFO_PLIST_EXTRA}
</dict>
</plist>
PLIST

plutil -lint -s "$APP/Contents/Info.plist"
codesign --force --sign "$SIGN_IDENTITY" "$APP" >/dev/null
echo "Done: $PWD/$APP ($BUNDLE_ID, signed: $SIGN_IDENTITY)"
