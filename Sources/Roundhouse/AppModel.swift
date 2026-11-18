// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import AppKit
import Observation
import RoundhouseCore

/// The connection list, its storage and the reachability dots. Shared by the main window and the search panel.
@MainActor @Observable
final class AppModel {
    private(set) var library = Library()
    /// Entries of ~/.ssh/config (re-read whenever a window or the panel opens).
    private(set) var imported: [Connection] = []
    private(set) var reachability: [UUID: Reachability] = [:]
    /// Selected rows of the main window.
    var selection: Set<UUID> = []
    /// The entry just added in the main window, whose name field takes focus.
    var justAdded: UUID?

    private let store: LibraryStore
    private let sshConfigURL: URL
    /// The file could not be read: nothing is saved over it, so the user's data is not lost.
    private(set) var loadError: String?

    init(
        store: LibraryStore = LibraryStore(fileURL: LibraryStore.defaultURL(folder: AppModel.dataFolder)),
        sshConfigURL: URL = AppModel.sshConfigURL
    ) {
        self.store = store
        self.sshConfigURL = sshConfigURL
        do {
            library = try store.load()
        } catch {
            loadError = error.localizedDescription
        }
        reloadSSHConfig()
    }

    /// Development builds keep their own list, so trying things out never touches the real one.
    /// `--args -dataFolder <name>` picks another folder (screenshots with sample data).
    nonisolated static var dataFolder: String {
        if let folder = UserDefaults.standard.string(forKey: "dataFolder"), !folder.isEmpty { return folder }
        return (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev") ? "Roundhouse Dev" : "Roundhouse"
    }

    /// `~/.ssh/config`; `--args -sshConfigPath <file>` reads another file (screenshots with sample data).
    nonisolated static var sshConfigURL: URL {
        if let path = UserDefaults.standard.string(forKey: "sshConfigPath"), !path.isEmpty {
            return URL(filePath: (path as NSString).expandingTildeInPath)
        }
        return URL.homeDirectory.appending(path: ".ssh/config")
    }

    var dataFileURL: URL { store.fileURL }

    /// Manual entries followed by the imported ones.
    var connections: [Connection] { library.connections + imported }

    func connection(id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }

    /// Folder names in use, sorted.
    var folders: [String] {
        Array(Set(connections.compactMap(\.folder))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func reloadSSHConfig() {
        let fresh = SSHConfig(file: sshConfigURL).connections
        if fresh != imported { imported = fresh }
    }

    // MARK: - Editing

    @discardableResult
    func add(_ connection: Connection) -> Connection {
        library.connections.append(connection)
        save()
        return connection
    }

    /// A new empty entry in the folder of the selected one, selected for editing.
    func addNew(kind: Connection.Kind) {
        let folder = selection.first.flatMap(connection(id:)).flatMap { $0.isImported ? nil : $0.folder }
        let connection = add(Connection(name: "", kind: kind, host: "", group: folder))
        justAdded = connection.id
        selection = [connection.id]
    }

    func duplicate(_ original: Connection) {
        var copy = original
        copy.id = UUID()
        copy.name = String(localized: "\(original.name) copy")
        copy.source = .manual
        copy.proxy = nil
        add(copy)
        selection = [copy.id]
    }

    func update(_ connection: Connection) {
        guard !connection.isImported,
              let index = library.connections.firstIndex(where: { $0.id == connection.id }),
              library.connections[index] != connection
        else { return }
        let addressChanged = library.connections[index].reachabilityHost != connection.reachabilityHost
            || library.connections[index].effectivePort != connection.effectivePort
        library.connections[index] = connection
        if addressChanged { reachability[connection.id] = nil }
        save()
    }

    func delete(ids: Set<UUID>) {
        let removed = library.connections.filter { ids.contains($0.id) }.map(\.stableKey)
        library.connections.removeAll { ids.contains($0.id) }
        library.recents.removeAll { removed.contains($0) }
        save()
    }

    private func save() {
        guard loadError == nil else { return }
        do {
            try store.save(library)
        } catch {
            Alerts.show(String(localized: "The connection list could not be saved."), detail: error.localizedDescription)
        }
    }

    // MARK: - Connecting

    func connect(_ connection: Connection) {
        guard Launcher.open(connection) else { return }
        library.markUsed(connection)
        save()
    }

    // MARK: - Reachability

    /// Who needs the dots right now (main window, panel); checks run only while this is not empty.
    private var watchers: Set<String> = []
    private var monitorTask: Task<Void, Never>?

    func startWatching(_ watcher: String) {
        watchers.insert(watcher)
        reloadSSHConfig()
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAll()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stopWatching(_ watcher: String) {
        watchers.remove(watcher)
        if watchers.isEmpty {
            monitorTask?.cancel()
            monitorTask = nil
        }
    }

    /// Checks every entry, at most 4 connections at a time; entries sharing host and port are checked once.
    private func checkAll() async {
        var targets: [String: (host: String, port: Int, ids: [UUID])] = [:]
        for connection in connections {
            guard connection.proxy == nil else {
                reachability[connection.id] = .unknown
                continue
            }
            let key = "\(connection.reachabilityHost.lowercased()) \(connection.effectivePort)"
            targets[key, default: (connection.reachabilityHost, connection.effectivePort, [])].ids.append(connection.id)
        }
        let list = Array(targets.values)
        await withTaskGroup(of: (Int, Reachability).self) { group in
            var next = 0
            func addNext() {
                guard next < list.count else { return }
                let index = next
                let target = list[index]
                group.addTask { (index, await Reachability.check(host: target.host, port: target.port)) }
                next += 1
            }
            for _ in 0..<4 { addNext() }
            for await (index, result) in group {
                for id in list[index].ids { reachability[id] = result }
                if Task.isCancelled { group.cancelAll() } else { addNext() }
            }
        }
    }
}
