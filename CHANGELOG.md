# Changelog

User-facing changes in each release. `scripts/release.sh <version> --publish` copies the section of that
version into the GitHub Release notes, so add a section before publishing.

## Unreleased

## 0.3.0

- **SSH: Enter the password into ssh** (per entry with a Bitwarden item, off by default). In Ghostty, ssh asks
  Roundhouse for the password through `SSH_ASKPASS` and logs in without pasting; the password never goes on a command
  line, to disk or to the clipboard. Only the password prompt of the entry's own host is answered, once; a new host
  key, a key passphrase, a code or a second try are asked in the terminal as before.

## 0.2.0

- **Passwords from Bitwarden or Vaultwarden** through the official Bitwarden CLI (`bw`). An entry refers to an item of
  your vault; on connect Roundhouse unlocks the vault if needed (the master password is never stored) and copies the
  password to the clipboard, hidden from clipboard managers and cleared after 30 seconds. The vault locks again after
  15 minutes without use (changeable), when the Mac sleeps or the screen locks.
- The item picker downloads new items from the server first (at most once a minute; **Sync** forces it) and shows
  when the vault was last synced; offline it shows the items saved on the Mac.
- **Copy Password** in the entry and its context menu; ⌘↩ in the search panel copies the password of entries with a
  Bitwarden item.
- **WinBox: Connect at once (password from Bitwarden)**, off by default: WinBox gets the password on its command line
  and logs in immediately. Other processes can see it in the process list while WinBox runs.
- **Copy Address** in the context menu of the connection list.

## 0.1.2

- Roundhouse is now signed with a permanent certificate, so macOS recognizes every update as the same app.

## 0.1.1

- The connection list now always comes to the front when you open Roundhouse; before, it could stay hidden behind
  other windows, so the first launch seemed to do nothing.
- A short welcome on the first launch explains the ⌥Space search panel and how to get back to the list without a
  Dock icon.

## 0.1.0

First release.

- **Search panel on a global shortcut** (⌥Space, changeable in Settings): type a few letters, press ↩ to connect,
  ⌘↩ to copy the address. Recently used connections come first.
- **Connection list** with folders, tags and notes; SSH, RDP, VNC, Web and WinBox entries, each opened in its app
  (Ghostty/iTerm2/Terminal, Windows App, Screen Sharing, your browser, WinBox), with an optional app per entry.
- **Hosts from `~/.ssh/config`** (with `Include`d files) appear automatically and connect with `ssh <alias>`.
- **Reachability dots**: green when the connection's port answers, red when not – checked only while a window or the
  panel is open.
- Start at login; no Dock icon unless you turn it on in Settings.
- English and Slovak.
