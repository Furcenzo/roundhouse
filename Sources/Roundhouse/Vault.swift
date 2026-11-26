// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import AppKit
import Observation
import RoundhouseCore

/// The Bitwarden vault through the `bw` CLI. The session key lives only in this object (memory) and is forgotten
/// after `Preferences.vaultLockMinutes` without use, when the Mac sleeps, the screen locks or the app quits.
/// The master password is never stored: it goes from the secure field straight into the environment of `bw unlock`.
@MainActor @Observable
final class Vault {
    enum State: Equatable {
        case unknown
        case notInstalled
        case notLoggedIn
        case locked
        case unlocked
    }

    private(set) var state: State = .unknown
    private(set) var server: String?
    private(set) var account: String?
    /// When the vault was last downloaded from the server (by Roundhouse or `bw sync`).
    private(set) var lastSync: Date?

    @ObservationIgnored private var session: String?
    @ObservationIgnored private var lockTask: Task<Void, Never>?
    @ObservationIgnored private var syncer: VaultSyncer?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private let demoFolder: URL?

    /// `demoFolder`: use the stub `bw` with sample data of that folder (screenshots), never the user's own.
    init(demoFolder: URL? = nil) {
        self.demoFolder = demoFolder
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            }))
        }
        observers.append((distributed, distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            }))
    }

    var cli: BitwardenCLI? {
        if let demoFolder { return BitwardenCLI(executable: demoFolder.appending(path: "bw")) }
        return BitwardenCLI.locate(override: Preferences.bwPath)
    }

    var isUnlocked: Bool { session != nil }

    /// Asks `bw status` (installed? logged in?).
    func refresh() async {
        guard let cli else {
            state = .notInstalled
            return
        }
        do {
            let status = try await cli.status(session: session)
            server = status.serverUrl
            account = status.userEmail
            if let date = status.lastSync, date > (lastSync ?? .distantPast) { lastSync = date }
            switch status.status {
            case .unauthenticated: forget(); state = .notLoggedIn
            case .locked: forget(); state = .locked
            case .unlocked: state = session == nil ? .locked : .unlocked
            }
        } catch .notInstalled {
            state = .notInstalled
        } catch {
            state = session == nil ? .locked : .unlocked
        }
    }

    /// Unlocks with `password` (from a secure field; not kept).
    func unlock(password: String) async throws(VaultError) {
        guard let cli else { throw .notInstalled }
        let key = try await cli.unlock(password: password)
        session = key
        state = .unlocked
        touch()
        syncer = VaultSyncer(cli: cli, lastSync: lastSync)
        // Start downloading new items at once; the item picker waits for this sync. Offline is fine too.
        Task { _ = await sync() }
    }

    /// Downloads the vault if the last sync is more than a minute old (or `force`). nil when done or not needed,
    /// otherwise why it failed (the items saved on this Mac stay usable).
    func sync(force: Bool = false) async -> String? {
        guard let syncer, let key = session else { return nil }
        do {
            try await syncer.sync(session: key, force: force)
            if let date = await syncer.lastSync { lastSync = date }
            return nil
        } catch {
            if error == .locked { forget(); state = .locked }
            return Vault.message(for: error)
        }
    }

    /// Forgets the session key and locks `bw`, so the key stops working.
    func lock() {
        guard session != nil else { return }
        forget()
        state = .locked
        if let cli { Task.detached { await cli.lock() } }
    }

    /// The app quits: forget the key and lock `bw` (not waited for).
    func lockOnQuit() {
        guard session != nil else { return }
        forget()
        cli?.startLock()
    }

    private func forget() {
        session = nil
        syncer = nil
        lockTask?.cancel()
        lockTask = nil
    }

    /// Restarts the countdown to the automatic lock.
    private func touch() {
        lockTask?.cancel()
        let minutes = Preferences.vaultLockMinutes
        lockTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.lock()
        }
    }

    // MARK: - Using the vault

    /// Unlocks if needed (asks for the master password); false when the user cancelled or it failed (alert shown).
    /// `purpose`: name of the entry whose password is needed, nil for unlocking in general.
    func ensureUnlocked(for purpose: String?) async -> Bool {
        if session != nil { return true }
        await refresh()
        switch state {
        case .unlocked: return true
        case .notInstalled, .notLoggedIn, .unknown:
            showSetupAlert()
            return false
        case .locked:
            break
        }
        var problem: String?
        while let password = UnlockPrompt.run(purpose: purpose, problem: problem) {
            do {
                try await unlock(password: password)
                return true
            } catch .wrongPassword {
                problem = String(localized: "The master password is not correct.")
            } catch {
                Alerts.show(String(localized: "The vault could not be unlocked."), detail: Self.message(for: error))
                return false
            }
        }
        return false
    }

    func credential(itemID: String, purpose: String) async throws(VaultError) -> VaultCredential? {
        guard await ensureUnlocked(for: purpose), let cli, let key = session else { return nil }
        do {
            let credential = try await cli.credential(id: itemID, session: key)
            touch()
            return credential
        } catch .locked {
            // Locked outside Roundhouse (bw lock in Terminal): ask again once.
            forget()
            state = .locked
            guard await ensureUnlocked(for: purpose), let key = session else { return nil }
            return try await cli.credential(id: itemID, session: key)
        }
    }

    func loginItems() async throws(VaultError) -> [VaultItemSummary] {
        guard let cli, let key = session else { throw .locked }
        do {
            let items = try await cli.loginItems(session: key)
            touch()
            return items
        } catch .locked {
            forget()
            state = .locked
            throw .locked
        }
    }

    /// Copies the password of `connection`'s item (concealed, cleared after 30 s). false when there is none.
    @discardableResult
    func copyPassword(of connection: Connection) async -> Bool {
        guard let itemID = connection.vaultItemID, connection.hasVaultItem else { return false }
        do {
            guard let credential = try await credential(itemID: itemID, purpose: connection.name) else { return false }
            SecretClipboard.copy(credential.password)
            return true
        } catch {
            Alerts.show(String(localized: "The password of “\(connection.name)” is not available."),
                        detail: Self.message(for: error))
            return false
        }
    }

    private func showSetupAlert() {
        let detail = state == .notInstalled
            ? String(localized: "Install the Bitwarden CLI and log in once in Terminal; see Settings → Bitwarden.")
            : String(localized: "Log in once in Terminal with “bw login”; see Settings → Bitwarden.")
        Alerts.show(String(localized: "Bitwarden is not set up."), detail: detail)
    }

    static func message(for error: VaultError) -> String {
        switch error {
        case .notInstalled: String(localized: "The Bitwarden CLI (bw) was not found.")
        case .notLoggedIn: String(localized: "The Bitwarden CLI is not logged in. Run “bw login” in Terminal.")
        case .locked: String(localized: "The vault is locked.")
        case .wrongPassword: String(localized: "The master password is not correct.")
        case .itemNotFound: String(localized: "The Bitwarden item was not found. Choose it again in the entry.")
        case .noPassword: String(localized: "The Bitwarden item has no password.")
        case .invalidItemID: String(localized: "The entry refers to an invalid Bitwarden item. Choose it again.")
        case .timedOut: String(localized: "The Bitwarden CLI did not answer in time.")
        case .failed(let message): message
        }
    }
}

/// The master password dialog: a secure field in an alert (also works over the search panel and other apps).
@MainActor
enum UnlockPrompt {
    /// The password, or nil when cancelled.
    static func run(purpose: String?, problem: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Unlock Bitwarden")
        var detail = purpose.map {
            String(localized: "Enter your master password to get the password for “\($0)”. Roundhouse does not store it.")
        } ?? String(localized: "Enter your master password. Roundhouse does not store it.")
        if let problem { detail = problem + "\n\n" + detail }
        alert.informativeText = detail
        alert.alertStyle = problem == nil ? .informational : .warning
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = String(localized: "Master password")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Unlock"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.activate()
        let response = alert.runModal()
        let password = field.stringValue
        field.stringValue = ""
        guard response == .alertFirstButtonReturn, !password.isEmpty else { return nil }
        return password
    }
}

/// Puts a password on the clipboard marked as concealed and transient (clipboard managers skip it) and clears it
/// after 30 seconds, unless something else was copied in the meantime.
@MainActor
enum SecretClipboard {
    static let clearAfter: Duration = .seconds(30)

    static func copy(_ secret: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(secret, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
        let count = pasteboard.changeCount
        Task {
            try? await Task.sleep(for: clearAfter)
            if pasteboard.changeCount == count { pasteboard.clearContents() }
        }
    }
}
