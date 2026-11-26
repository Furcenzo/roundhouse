// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import Foundation
import Testing
@testable import RoundhouseCore

/// Runs against `Assets/screenshots/sample/bw`, a shell script with made-up data – never a real vault.
@Suite struct BitwardenTests {
    static let stub = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Assets/screenshots/sample/bw")
    static let switchID = "6f1c2b3a-0d4e-4f50-9a61-7b8c9d0e1f21"
    let cli = BitwardenCLI(executable: stub, timeout: 10)

    @Test func statusFollowsTheSession() async throws {
        #expect(try await cli.status(session: nil).status == .locked)
        let unlocked = try await cli.status(session: "sample-session-key")
        #expect(unlocked == VaultStatus(status: .unlocked, serverUrl: "https://vault.example.com",
                                        userEmail: "user@example.com", lastSync: Date(timeIntervalSince1970: 1_767_225_600)))
    }

    @Test func unlockKeepsThePasswordOffTheCommandLine() async throws {
        let log = FileManager.default.temporaryDirectory.appending(path: "RoundhouseTests-bw-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        // The real code passes only a fixed list of variables, so a wrapper script sets BW_STUB_LOG.
        let logging = LoggingCLI(base: cli, log: log)

        #expect(try await logging.unlock(password: "sample-password") == "sample-session-key")
        await #expect(throws: VaultError.wrongPassword) { try await logging.unlock(password: "wrong") }
        let calls = try String(contentsOf: log, encoding: .utf8)
        #expect(calls.contains("unlock --passwordenv \(BitwardenCLI.passwordVariable) --raw"))
        #expect(!calls.contains("sample-password"))
        #expect(!calls.contains("wrong"))
    }

    @Test func childEnvironmentIsMinimal() {
        let environment = cli.environment(session: "key", extra: ["X": "y"])
        #expect(environment["BW_SESSION"] == "key")
        #expect(environment["BW_NOINTERACTION"] == "true")
        #expect(environment["X"] == "y")
        #expect(environment["PATH"]?.hasPrefix(Self.stub.deletingLastPathComponent().path + ":") == true)
        #expect(cli.environment(session: nil, extra: [:])["BW_SESSION"] == nil)
        let allowed: Set = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "BITWARDENCLI_APPDATA_DIR",
                            "NODE_EXTRA_CA_CERTS", "PATH", "BW_NOINTERACTION"]
        #expect(Set(cli.environment(session: nil, extra: [:]).keys).isSubset(of: allowed))
    }

    @Test func listsLoginItemsWithoutPasswords() async throws {
        let items = try await cli.loginItems(session: "sample-session-key")
        #expect(items.map(\.name) == ["Core switch", "Firewall", "Proxmox root"])
        #expect(items[0] == VaultItemSummary(id: Self.switchID, name: "Core switch", username: "admin", uri: "https://192.0.2.2"))
        #expect(items[1].uri == nil)
        #expect(!String(describing: items).contains("password"))
        await #expect(throws: VaultError.locked) { try await cli.loginItems(session: "expired") }
    }

    @Test func credential() async throws {
        let credential = try await cli.credential(id: Self.switchID, session: "sample-session-key")
        #expect(credential == VaultCredential(username: "admin", password: "sample-switch-password"))
        #expect(!String(describing: credential).contains("sample-switch-password"))
        await #expect(throws: VaultError.noPassword) {
            try await cli.credential(id: "11111111-2222-4333-8444-555555555555", session: "sample-session-key")
        }
        await #expect(throws: VaultError.itemNotFound) {
            try await cli.credential(id: "00000000-0000-4000-8000-000000000001", session: "sample-session-key")
        }
        await #expect(throws: VaultError.invalidItemID) {
            try await cli.credential(id: "--help", session: "sample-session-key")
        }
    }

    @Test func notLoggedIn() async throws {
        let environment = LoggingCLI(base: cli, log: nil, state: "unauthenticated")
        #expect(try await environment.status().status == .unauthenticated)
        await #expect(throws: VaultError.notLoggedIn) { try await environment.unlock(password: "sample-password") }
    }

    @Test func missingExecutable() async {
        let missing = BitwardenCLI(executable: URL(filePath: "/nonexistent/bw"))
        await #expect(throws: VaultError.notInstalled) { try await missing.status(session: nil) }
        #expect(BitwardenCLI.locate(override: "/nonexistent/bw") == nil)
        #expect(BitwardenCLI.locate(override: Self.stub.path)?.executable == Self.stub)
    }

    @Test func timesOut() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RoundhouseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let slow = folder.appending(path: "bw")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: slow)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        await #expect(throws: VaultError.timedOut) {
            try await BitwardenCLI(executable: slow, timeout: 0.5).status(session: nil)
        }
    }
}

@Suite struct VaultSyncerTests {
    let session = "sample-session-key"

    func calls(_ log: URL) -> Int {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.hasPrefix("sync") }.count
    }

    func tempLog() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "RoundhouseTests-sync-\(UUID().uuidString).log")
    }

    @Test func throttlesUnlessForced() async throws {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let clock = TestClock()
        let syncer = VaultSyncer(cli: try LoggingCLI(base: BitwardenTests().cli, log: log).cli(), minimumInterval: 60,
                                 now: { clock.now })
        #expect(try await syncer.sync(session: session))
        #expect(await syncer.lastSync == clock.now)
        clock.advance(30)
        #expect(try await !syncer.sync(session: session))
        #expect(try await syncer.sync(session: session, force: true))
        clock.advance(61)
        #expect(try await syncer.sync(session: session))
        #expect(calls(log) == 3)
    }

    @Test func respectsTheLastSyncOfBw() async throws {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let clock = TestClock()
        let syncer = VaultSyncer(cli: try LoggingCLI(base: BitwardenTests().cli, log: log).cli(),
                                 lastSync: clock.now.addingTimeInterval(-10), now: { clock.now })
        #expect(try await !syncer.sync(session: session))
        #expect(calls(log) == 0)
    }

    @Test func concurrentCallsShareOneSync() async throws {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let cli = try LoggingCLI(base: BitwardenTests().cli, log: log, extra: ["BW_STUB_SYNC_DELAY": "0.5"]).cli()
        let syncer = VaultSyncer(cli: cli)
        async let first = syncer.sync(session: session)
        async let second = syncer.sync(session: session)
        _ = try await (first, second)
        #expect(calls(log) == 1)
    }

    @Test func offlineKeepsTheOldTime() async throws {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log) }
        let before = Date(timeIntervalSince1970: 1_000)
        let cli = try LoggingCLI(base: BitwardenTests().cli, log: log, extra: ["BW_STUB_OFFLINE": "1"]).cli()
        let syncer = VaultSyncer(cli: cli, lastSync: before)
        await #expect(throws: VaultError.self) { try await syncer.sync(session: session) }
        #expect(await syncer.lastSync == before)
        // The local copy still works offline.
        #expect(try await cli.loginItems(session: session).count == 3)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 2_000_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// The stub with extra environment variables for the test (BW_STUB_LOG, BW_STUB_STATE…).
private struct LoggingCLI {
    let base: BitwardenCLI
    let log: URL?
    var state: String?
    var extra: [String: String] = [:]

    func cli() throws -> BitwardenCLI { try wrapper() }

    /// A wrapper script that sets the variables and runs the stub.
    private func wrapper() throws -> BitwardenCLI {
        let folder = FileManager.default.temporaryDirectory.appending(path: "RoundhouseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var script = "#!/bin/sh\n"
        if let log { script += "export BW_STUB_LOG='\(log.path)'\n" }
        if let state { script += "export BW_STUB_STATE='\(state)'\n" }
        for (key, value) in extra { script += "export \(key)='\(value)'\n" }
        script += "exec '\(base.executable.path)' \"$@\"\n"
        let file = folder.appending(path: "bw")
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return BitwardenCLI(executable: file, timeout: base.timeout)
    }

    func unlock(password: String) async throws -> String {
        try await wrapper().unlock(password: password)
    }

    func status() async throws -> VaultStatus {
        try await wrapper().status(session: nil)
    }
}
