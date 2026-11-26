// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import AppKit
import RoundhouseCore
import UniformTypeIdentifiers

/// Carries out a `LaunchPlan`: opens the URL, starts the client or hands it a temporary .rdp file.
@MainActor
enum Launcher {
    /// false when the connection could not be opened (an alert was shown).
    @discardableResult
    static func open(_ connection: Connection, credential: VaultCredential? = nil) -> Bool {
        var client = connection.client
        if client == nil, connection.kind == .ssh {
            client = Preferences.sshTerminal
        }
        // A missing terminal falls back to Terminal, which is always there.
        if connection.kind == .ssh, let wanted = client, appURL(wanted) == nil {
            client = KnownClient.terminal
        }

        let plan: LaunchPlan
        do {
            plan = try LaunchPlan.make(for: connection, client: client, credential: credential)
        } catch {
            Alerts.show(String(localized: "“\(connection.name)” cannot be opened."), detail: message(for: error))
            return false
        }

        switch plan {
        case .openURL(let url, let app):
            if let app {
                guard let appURL = appURL(app) else { return missingApp(app, connection) }
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: activating()) { _, error in
                    if let error { Task { @MainActor in failed(connection, error) } }
                }
            } else {
                NSWorkspace.shared.open(url)
            }
        case .launchApp(let app, let arguments):
            guard let appURL = appURL(app) else { return missingApp(app, connection) }
            let configuration = activating()
            configuration.arguments = arguments
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error { Task { @MainActor in failed(connection, error) } }
            }
        case .rdpFile(let contents, let app):
            do {
                let file = try writeRDPFile(contents, name: connection.name)
                let appURL = app.flatMap(appURL) ?? NSWorkspace.shared.urlForApplication(toOpen: file)
                guard let appURL else { return missingApp(app ?? ".rdp", connection) }
                NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: activating()) { _, error in
                    if let error { Task { @MainActor in failed(connection, error) } }
                }
                // The client reads the file when it opens it; don't leave it lying around.
                Task {
                    try? await Task.sleep(for: .seconds(60))
                    try? FileManager.default.removeItem(at: file)
                }
            } catch {
                failed(connection, error)
                return false
            }
        }
        return true
    }

    static func appURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Display name of an installed app ("Ghostty"), the bundle ID when it is not installed.
    static func appName(_ bundleID: String) -> String {
        guard let url = appURL(bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Apps that can open entries of `kind`, for the "Open with" picker (bundle IDs, without duplicates).
    static func clients(for kind: Connection.Kind) -> [String] {
        let urls: [URL]
        switch kind {
        case .ssh:
            return KnownClient.terminals.filter { appURL($0) != nil }
        case .winbox:
            return [KnownClient.winBox]
        case .rdp:
            urls = UTType(filenameExtension: "rdp").map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []
        case .vnc:
            urls = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "vnc://example.com")!)
        case .web:
            urls = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)
        }
        var seen = Set<String>()
        return urls.compactMap { Bundle(url: $0)?.bundleIdentifier }.filter { seen.insert($0).inserted }
    }

    private static func activating() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return configuration
    }

    private static func writeRDPFile(_ contents: String, name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Roundhouse-RDP")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let safeName = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        let file = folder.appending(path: (safeName.isEmpty ? "connection" : safeName) + ".rdp")
        try Data(contents.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    private static func missingApp(_ app: String, _ connection: Connection) -> Bool {
        Alerts.show(
            String(localized: "“\(connection.name)” cannot be opened."),
            detail: String(localized: "The app \(app) is not installed. Choose another app in the entry."))
        return false
    }

    private static func failed(_ connection: Connection, _ error: Error) {
        Alerts.show(String(localized: "“\(connection.name)” cannot be opened."), detail: error.localizedDescription)
    }

    private static func message(for error: LaunchPlan.Problem) -> String {
        switch error {
        case .missingHost: String(localized: "The entry has no host.")
        case .invalidHost: String(localized: "The host contains characters that are not allowed (space, /, @ or a leading -).")
        case .invalidURL: String(localized: "The URL is not a valid http or https address.")
        }
    }
}

@MainActor
enum Alerts {
    static func show(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }
}
