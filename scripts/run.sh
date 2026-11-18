#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Furcenzo
# Part of mac-app-kit (shared scripts of the Furcenzo Mac apps): change it there and run its sync.sh, not here.
#
# Development loop: build build/<APP_NAME>.app, quit the running app and start the new build.
#   ./scripts/run.sh          English UI (or the macOS language)
#   ./scripts/run.sh sk       force a language
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/app-config.sh

./scripts/build-app.sh
if [[ "$RUN_QUITS_INSTALLED" == "1" ]]; then
    # Every running copy: the dev build and, with the same executable name, the installed app too.
    pkill -x "$EXECUTABLE" 2>/dev/null && sleep 0.5 || true
else
    # Only the build from build/ – the installed app keeps running next to it.
    BUILT="$(print -r -- "$PWD/build/$APP_BUNDLE/Contents/MacOS/$EXECUTABLE" | sed 's/[][\\.*^$(){}?+|]/\\&/g')"
    pkill -f "^$BUILT" 2>/dev/null && sleep 0.5 || true
fi
if [[ -n "${1:-}" ]]; then
    open -n "build/$APP_BUNDLE" --args -AppleLanguages "($1)"
else
    open -n "build/$APP_BUNDLE"
fi
NAME="$APP_NAME"
[[ "$DEV_CHANNEL" == "1" ]] && NAME="$APP_NAME Dev"
if [[ "$AGENT_APP" == "1" ]]; then
    echo "$NAME is running – look for its icon in the menu bar."
else
    echo "$NAME is running."
fi
if [[ "$RUN_QUITS_INSTALLED" == "1" && -d "/Applications/$APP_BUNDLE" ]]; then
    echo "(The installed $APP_NAME was quit. Back to it: open \"/Applications/$APP_BUNDLE\")"
fi
