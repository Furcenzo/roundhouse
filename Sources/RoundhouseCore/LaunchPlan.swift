// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import Foundation

/// Bundle IDs of the clients Roundhouse knows how to drive.
public enum KnownClient {
    public static let ghostty = "com.mitchellh.ghostty"
    public static let terminal = "com.apple.Terminal"
    public static let iTerm = "com.googlecode.iterm2"
    public static let windowsApp = "com.microsoft.rdc.macos"
    public static let screenSharing = "com.apple.ScreenSharing"
    public static let winBox = "com.mikrotik.winbox"

    /// Terminals offered for SSH entries, in order of preference.
    public static let terminals = [ghostty, iTerm, terminal]

    /// Default client of a kind; nil = the system default app for the URL.
    public static func defaultClient(for kind: Connection.Kind) -> String? {
        switch kind {
        case .ssh: ghostty
        case .rdp: windowsApp
        case .vnc: screenSharing
        case .web: nil
        case .winbox: winBox
        }
    }
}

/// What has to happen to open a connection – decided here (pure, tested), carried out by the app.
public enum LaunchPlan: Equatable, Sendable {
    /// Open the URL, with `app` (bundle ID) or the system default app.
    case openURL(URL, app: String?)
    /// Start a new instance of `app` with command-line arguments (`open -na <app> --args …`).
    case launchApp(String, arguments: [String])
    /// Write `contents` to a temporary `.rdp` file and open it with `app` (or the default app for .rdp).
    case rdpFile(contents: String, app: String?)

    public enum Problem: Error, Equatable, Sendable {
        case missingHost
        case invalidHost
        case invalidURL
    }

    /// The plan for `connection` opened with `client` (bundle ID; nil = the entry's own or the kind's default).
    public static func make(for connection: Connection, client: String? = nil) throws(Problem) -> LaunchPlan {
        let client = client ?? connection.client ?? KnownClient.defaultClient(for: connection.kind)
        if connection.kind == .web {
            guard let url = connection.webURL, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host() != nil
            else { throw .invalidURL }
            return .openURL(url, app: client)
        }

        let host = connection.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw .missingHost }
        // A host starting with "-" would be read as an option by ssh and other command-line tools.
        guard !host.hasPrefix("-"), !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" })
        else { throw .invalidHost }
        let user = connection.user?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let port = connection.port.flatMap { $0 == connection.kind.defaultPort ? nil : $0 }

        switch connection.kind {
        case .ssh:
            if client == KnownClient.ghostty {
                return .launchApp(client!, arguments: ["-e"] + sshCommand(connection, host: host, user: user, port: port))
            }
            return .openURL(try url("ssh", connection: connection, host: host, user: user, port: port), app: client)
        case .vnc:
            return .openURL(try url("vnc", connection: connection, host: host, user: user, port: port), app: client)
        case .rdp:
            return .rdpFile(contents: rdpContents(host: host, user: user, port: port), app: client)
        case .winbox:
            let address = port.map { "\(bracketed(host)):\($0)" } ?? host
            return .launchApp(client ?? KnownClient.winBox, arguments: [address] + (user.map { [$0] } ?? []))
        case .web:
            fatalError("handled above")
        }
    }

    /// `ssh <alias>` for imported entries (all settings of ~/.ssh/config apply), otherwise `ssh [-p port] [-l user] host`.
    static func sshCommand(_ connection: Connection, host: String, user: String?, port: Int?) -> [String] {
        if case .sshConfig(let alias) = connection.source { return ["ssh", "--", alias] }
        var command = ["ssh"]
        if let port { command += ["-p", String(port)] }
        if let user { command += ["-l", user] }
        return command + ["--", host]
    }

    static func url(_ scheme: String, connection: Connection, host: String, user: String?, port: Int?)
        throws(Problem) -> URL
    {
        var components = URLComponents()
        components.scheme = scheme
        if case .sshConfig(let alias) = connection.source {
            components.host = alias
        } else {
            components.host = host
            components.user = user
            components.port = port
        }
        guard let url = components.url else { throw .invalidHost }
        return url
    }

    /// A minimal .rdp file: address and user name. Never a password.
    static func rdpContents(host: String, user: String?, port: Int?) -> String {
        var lines = ["full address:s:" + (port.map { "\(bracketed(host)):\($0)" } ?? host)]
        if let user { lines.append("username:s:" + user) }
        lines += ["prompt for credentials:i:1", "dynamic resolution:i:1"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// IPv6 addresses need brackets before ":port".
    static func bracketed(_ host: String) -> String {
        host.contains(":") ? "[\(host)]" : host
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
