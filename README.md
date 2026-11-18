# Roundhouse

<img src="Assets/AppIcon.png" alt="Roundhouse icon" width="128" align="right">

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

A connection launcher for macOS: one list of your servers and devices, a Spotlight-like search panel on a global
shortcut (⌥Space by default), and the right app opens for each connection. Roundhouse is not a terminal or an RDP
client – it starts the tools you already have:

| Type | Opens in |
| --- | --- |
| SSH | Ghostty (or iTerm2, Terminal) |
| RDP | Windows App, via a temporary `.rdp` file (address and user only, never a password) |
| VNC | Screen Sharing |
| Web | your browser (or a browser chosen per entry) |
| WinBox | MikroTik WinBox |

- Hosts from `~/.ssh/config` (including `Include`d files) appear automatically and connect with `ssh <alias>`, so
  keys, ProxyJump and every other setting keep working.
- A dot next to each entry shows whether it answers (a short TCP connection to its port, only while a Roundhouse
  window or the panel is open).
- Starts at login if you want, and stays out of the Dock and the menu bar unless you turn the Dock icon on.

Your connection list stays on your Mac (`~/Library/Application Support/Roundhouse/connections.json`).

Available in English and Slovak (follows the macOS language setting).

## Download

Install it with [Homebrew](https://brew.sh): `brew install --cask furcenzo/tap/roundhouse`, or download the zip
from [Releases](https://github.com/Furcenzo/roundhouse/releases). The app is not notarized by Apple: on the first launch
open **System Settings → Privacy & Security** and click **Open Anyway**.

Requires macOS 15 or later.

## Building

Requires Xcode (or the Swift 6 toolchain).

```sh
swift build && swift test
./scripts/build-app.sh      # build/Roundhouse.app ("Roundhouse Dev")
./scripts/run.sh [sk|en]    # build and start it
```

`scripts/` comes from [mac-app-kit](https://github.com/Furcenzo/mac-app-kit), the shared scripts of the
author's Mac apps; the settings of this app are in `app.conf`.

## License

GPL-3.0-or-later – see [LICENSE](LICENSE). Copyright (C) 2026 Furcenzo.
