// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import Foundation
import Network
import Testing
@testable import RoundhouseCore

@Suite struct LibraryTests {
    @Test func roundTripsAndSkipsImported() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "RoundhouseTests-\(UUID().uuidString)/connections.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = LibraryStore(fileURL: url)
        #expect(try store.load() == Library())

        let manual = Connection(name: "pve", kind: .web, host: "192.0.2.10", group: "Lab", tags: ["proxmox"])
        let imported = Connection(name: "nas", kind: .ssh, host: "192.0.2.5", source: .sshConfig(alias: "nas"))
        var library = Library(connections: [manual, imported])
        library.markUsed(imported)
        try store.save(library)

        let loaded = try store.load()
        #expect(loaded.connections == [manual])
        #expect(loaded.recents == ["ssh-config:nas"])
    }

    @Test func recentsAreLimited() {
        var library = Library()
        let connections = (0..<30).map { Connection(name: "c\($0)", kind: .ssh, host: "h\($0).example.com") }
        connections.forEach { library.markUsed($0) }
        library.markUsed(connections[5])
        #expect(library.recents.count == Library.recentsLimit)
        #expect(library.recents.first == connections[5].stableKey)
    }

    @Test func corruptFileThrows() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "RoundhouseTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{".utf8).write(to: url)
        #expect(throws: (any Error).self) { try LibraryStore(fileURL: url).load() }
    }
}

@Suite struct SearchTests {
    let connections = [
        Connection(name: "pve-01", kind: .ssh, host: "192.0.2.10", group: "Lab"),
        Connection(name: "pve-01 web", kind: .web, host: "192.0.2.10", group: "Lab"),
        Connection(name: "pbs", kind: .web, host: "backup.example.com", tags: ["backup"]),
        Connection(name: "router", kind: .winbox, host: "192.0.2.1"),
        Connection(name: "office-pc", kind: .rdp, host: "pc.example.net"),
    ]

    @Test func prefixBeatsSubstring() {
        let names = Search.rank(connections, query: "pve").map(\.name)
        #expect(names == ["pve-01", "pve-01 web"])
    }

    @Test func everyWordMustMatch() {
        #expect(Search.rank(connections, query: "pve web").map(\.name) == ["pve-01 web"])
        #expect(Search.rank(connections, query: "pve rdp").isEmpty)
    }

    @Test func matchesHostTagsAndSubsequence() {
        #expect(Search.rank(connections, query: "backup").map(\.name) == ["pbs"])
        #expect(Search.rank(connections, query: "192.0.2.1").first?.name == "router")
        #expect(Search.rank(connections, query: "opc").map(\.name) == ["office-pc"])
        #expect(Search.rank(connections, query: "pc").first?.name == "office-pc")
    }

    @Test func recentsFirstWithoutQuery() {
        let ranked = Search.rank(connections, query: "", recents: [connections[3].stableKey, connections[2].stableKey])
        #expect(ranked.map(\.name) == ["router", "pbs", "office-pc", "pve-01", "pve-01 web"])
    }
}

@Suite struct ReachabilityTests {
    @Test func closedPortIsUnreachable() async {
        // Port 1 on localhost is normally closed: the connection is refused at once.
        #expect(await Reachability.check(host: "127.0.0.1", port: 1, timeout: 2) == .unreachable)
    }

    @Test func invalidInputIsUnknown() async {
        #expect(await Reachability.check(host: "", port: 22) == .unknown)
        #expect(await Reachability.check(host: "127.0.0.1", port: 0) == .unknown)
    }
}

@Suite struct ReachabilityListenerTests {
    @Test func openPortIsReachable() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port?.rawValue { continuation.yield(port) }
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var iterator = ready.makeAsyncIterator()
        let port = try #require(await iterator.next())
        #expect(await Reachability.check(host: "127.0.0.1", port: Int(port)) == .reachable)
    }
}
