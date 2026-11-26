// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import Foundation

/// One entry of the list: a server or device and how to reach it.
public struct Connection: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case ssh, rdp, vnc, web, winbox

        /// TCP port used when the entry has none (also the port the reachability check tries).
        public var defaultPort: Int {
            switch self {
            case .ssh: 22
            case .rdp: 3389
            case .vnc: 5900
            case .web: 443
            case .winbox: 8291
            }
        }

        /// Short label shown in lists and pickers (the same in every language).
        public var label: String {
            switch self {
            case .ssh: "SSH"
            case .rdp: "RDP"
            case .vnc: "VNC"
            case .web: "Web"
            case .winbox: "WinBox"
            }
        }
    }

    public enum Source: Codable, Hashable, Sendable {
        /// Created in Roundhouse, stored in its JSON file.
        case manual
        /// A `Host` of `~/.ssh/config`; read-only, connects with `ssh <alias>`.
        case sshConfig(alias: String)
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var host: String
    /// nil = `kind.defaultPort`
    public var port: Int?
    public var user: String?
    /// `.web` only: the full URL (may differ from `host`); nil = `https://host[:port]`
    public var url: String?
    /// One level of folders, e.g. "Homelab"; nil or empty = no folder.
    public var group: String?
    public var tags: [String]
    /// Reference to a Bitwarden item (its ID), never the secret itself.
    public var vaultItemID: String?
    /// Name of that item, shown while the vault is locked (not a secret).
    public var vaultItemName: String?
    /// WinBox only: pass the password from Bitwarden on the command line, so WinBox logs in at once.
    /// Off (nil) by default – other processes can see command-line arguments.
    public var loginAtOnce: Bool?
    /// Bundle ID of the app that opens this entry; nil = default client of the kind.
    public var client: String?
    public var source: Source
    public var notes: String?
    /// Imported SSH entries: the ProxyJump/ProxyCommand host. Such an entry is not reachable directly,
    /// so the reachability check skips it.
    public var proxy: String?

    public init(
        id: UUID = UUID(), name: String, kind: Kind, host: String, port: Int? = nil, user: String? = nil,
        url: String? = nil, group: String? = nil, tags: [String] = [], vaultItemID: String? = nil,
        vaultItemName: String? = nil, loginAtOnce: Bool? = nil, client: String? = nil, source: Source = .manual, notes: String? = nil, proxy: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.user = user
        self.url = url
        self.group = group
        self.tags = tags
        self.vaultItemID = vaultItemID
        self.vaultItemName = vaultItemName
        self.loginAtOnce = loginAtOnce
        self.client = client
        self.source = source
        self.notes = notes
        self.proxy = proxy
    }

    public var isImported: Bool { source != .manual }

    /// The entry refers to a Bitwarden item.
    public var hasVaultItem: Bool { vaultItemID.map(BitwardenCLI.isValidItemID) ?? false }

    /// WinBox gets the password from Bitwarden on the command line and logs in at once.
    public var logsInAtOnce: Bool { kind == .winbox && loginAtOnce == true && hasVaultItem }

    /// The port the connection uses.
    public var effectivePort: Int {
        if let port { return port }
        if kind == .web, let url = webURL, let urlPort = url.port { return urlPort }
        if kind == .web, webURL?.scheme == "http" { return 80 }
        return kind.defaultPort
    }

    /// Host the reachability check connects to (the URL's host for web entries).
    public var reachabilityHost: String {
        if kind == .web, let host = webURL?.host(), !host.isEmpty { return host }
        return host
    }

    /// `.web`: the URL to open.
    public var webURL: URL? {
        if let url = url?.trimmingCharacters(in: .whitespaces), !url.isEmpty {
            return URL(string: url.contains("://") ? url : "https://" + url)
        }
        guard !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        return components.url
    }

    /// "user@host:port" as shown under the name.
    public var address: String {
        if kind == .web, let url = webURL { return url.absoluteString }
        var text = host
        if let user, !user.isEmpty { text = user + "@" + text }
        if let port, port != kind.defaultPort { text += ":\(port)" }
        return text
    }

    /// The folder name, nil when the entry has none.
    public var folder: String? {
        guard let group = group?.trimmingCharacters(in: .whitespaces), !group.isEmpty else { return nil }
        return group
    }
}
