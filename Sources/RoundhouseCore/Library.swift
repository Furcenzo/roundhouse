// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import Foundation

/// What Roundhouse stores: the manual entries and the recently used ones.
public struct Library: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    /// How many recently used entries are remembered.
    public static let recentsLimit = 20

    public var version: Int
    public var connections: [Connection]
    /// `Connection.stableKey` of recently used entries, most recent first.
    public var recents: [String]

    public init(connections: [Connection] = [], recents: [String] = []) {
        self.version = Self.currentVersion
        self.connections = connections
        self.recents = recents
    }

    public mutating func markUsed(_ connection: Connection) {
        recents.removeAll { $0 == connection.stableKey }
        recents.insert(connection.stableKey, at: 0)
        if recents.count > Self.recentsLimit { recents.removeLast(recents.count - Self.recentsLimit) }
    }
}

extension Connection {
    /// Identifies the entry across launches: imported entries get a new `id` every time the config is read.
    public var stableKey: String {
        switch source {
        case .manual: id.uuidString
        case .sshConfig(let alias): "ssh-config:" + alias
        }
    }
}

/// Reads and writes the library as one JSON file (written atomically).
public struct LibraryStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/<folder>/connections.json`
    public static func defaultURL(folder: String) -> URL {
        URL.applicationSupportDirectory.appending(path: folder).appending(path: "connections.json")
    }

    /// An empty library when the file does not exist yet; throws when it exists but cannot be read.
    public func load() throws -> Library {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Library() }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Library.self, from: data)
    }

    public func save(_ library: Library) throws {
        // Imported entries come from ~/.ssh/config, never from this file.
        var library = library
        library.connections.removeAll(where: \.isImported)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(library)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }
}
