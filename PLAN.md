# Roundhouse – plan

A connection launcher for macOS: one list of servers and devices, a Spotlight-like search panel on a global hotkey,
and the right external tool opens for each connection. Not a terminal, not an RDP client.

The user's real connection list lives only on their Mac (`~/Library/Application Support/Roundhouse/`). Tests,
previews and screenshots use sample data only (`example.com`, `192.0.2.0/24` and other documentation ranges).

## Data model (`RoundhouseCore`)

```swift
struct Connection: Codable, Identifiable {
    var id: UUID
    var name: String            // "pve-01", what the search matches
    var kind: Kind              // .ssh, .sftp, .rdp, .vnc, .web, .winbox
    var host: String
    var port: Int?              // nil = default of the kind
    var user: String?
    var url: String?            // .web only (full URL, may differ from host)
    var group: String?          // one level of folders, e.g. "Homelab"
    var tags: [String]
    var vaultItemID: String?    // reference to a Bitwarden item, never the secret itself
    var client: String?         // bundle ID override, nil = default client of the kind
    var source: Source          // .manual or .sshConfig(alias:) – imported entries are read-only
    var notes: String?
}
```

Stored as one JSON file, written atomically. `~/.ssh/config` (and `Include`d files such as `config.d/*`) is parsed
on launch and on file change; every `Host` alias without wildcards becomes an SSH entry that connects with
`ssh <alias>`, so all settings of the config (keys, ProxyJump, ports) keep working. The parser is pure Swift in
Core and tested.

## Launching

| Kind | Default client | How |
| --- | --- | --- |
| SSH | Ghostty | `open -na Ghostty --args -e ssh <alias or user@host -p port>`; Terminal/iTerm via `ssh://` URL |
| RDP | Windows App | temporary `.rdp` file (address, user, screen settings) opened with the client, deleted afterwards; any app that opens `.rdp` can be chosen |
| VNC | Screen Sharing | `vnc://user@host:port` |
| Web | default browser | the URL; a browser can be chosen per entry |
| WinBox | WinBox | `open -na WinBox --args <host[:port]>` (WinBox keeps its saved login); with a user set in Roundhouse `<host[:port]> <user> ""` – WinBox 4 connects at once only with all three arguments, the password stays empty |
| SFTP | app that handles `sftp://` | `sftp://user@host:port/` – Finder cannot open SFTP without macFUSE, so the default is Cyberduck/ForkLift/Transmit if installed |

Devolutions Remote Desktop Manager is a full Royal TSX competitor, not a plain RDP client, so it is not a good
default; it can still be picked as the `.rdp` client.

Passwords are **never** passed as command-line arguments (visible in `ps`) or written to `.rdp` files – with one
opt-in exception per WinBox entry in 0.2 (see Bitwarden below).

## Search panel and hotkey

- A global hotkey (default ⌥Space, changeable) via Carbon `RegisterEventHotKey` – needs no Accessibility permission.
- A floating non-activating `NSPanel` with a search field and a result list: fuzzy match on name, host, group and
  tags; ↑↓, Enter = connect, ⌘Enter = alternative action (copy password / copy host), Esc = close.
- Recently used entries rank first.
- The main window (list, editor, settings) is the normal app window. No menu bar icon (optional later).
- The app starts at login (`SMAppService`) so the hotkey works all the time.

## Reachability

- A dot per entry: green = TCP port answers, red = no answer, grey = unknown.
- `Network.framework` TCP connect to the entry's port (22, 3389, 5900, 443, 8291…) with a 2 s timeout; no ICMP,
  no root.
- Only while the panel or the main window is visible: check on open, then every 60 s, at most a few connections in
  parallel. Nothing runs in the background otherwise.

## Bitwarden / Vaultwarden

- Uses the official `bw` CLI (`brew install bitwarden-cli`), pointed at the user's own server (`bw config server`).
- The user unlocks the vault in Roundhouse (master password typed into a secure field, passed to `bw unlock` via an
  environment variable of the child process, never stored). The session key stays only in memory and is forgotten
  after a timeout and on sleep/lock.
- On connect: `bw get item <vaultItemID>` → the password is copied to the clipboard as a concealed item
  (`org.nspasteboard.ConcealedType`) and cleared after 30 s unless the user copied something else.
- SSH: preferably keys. The Bitwarden desktop app has its own SSH agent that Roundhouse does not need to know about.
- WinBox: an option per entry, **"Connect at once (password from Bitwarden)"**, off by default (approved by the user
  for 0.2).
  - On: when connecting, Roundhouse gets the password from Bitwarden and starts WinBox with
    `<address> <user> <password>`, so it logs in at once. The password is never written to disk or to a log.
  - Next to the option a short warning: WinBox gets the password as a command-line argument, and other processes
    on the Mac can see it in the process list while WinBox runs. The user accepts this, mainly for the switch and
    the firewall.
  - Off: as in 0.1 – only the address is passed (with a user entered in Roundhouse: `<address> <user> ""`), and
    WinBox uses its own saved login.
- Development and tests use a mock `bw` and sample data only – never the user's real vault.

## MVP (0.1)

1. Model + JSON store + `ssh_config` import (Core, tested).
2. Main window: list grouped by folder, add/edit/delete, search.
3. Launchers for SSH, RDP, VNC, Web, WinBox.
4. Hotkey panel with search and recents.
5. Reachability dots.
6. Login item.

## Later

- ~~Bitwarden integration~~ – done in 0.2.
- SFTP, per-kind default client in settings, optional menu bar icon.
- Duplicate an entry, import/export JSON, credentials per group.

## Open questions

- Dock icon: an app that is always running for the hotkey – show it in the Dock, or hide it (`AGENT_APP=1`) and open
  the main window from the panel (⌘,) or by launching the app again? Recommended: hidden, with an option to show it.
