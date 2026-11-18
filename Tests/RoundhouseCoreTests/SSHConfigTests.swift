// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import Foundation
import Testing
@testable import RoundhouseCore

@Suite struct SSHConfigTests {
    let sample = """
        # Sample config – documentation addresses only
        User admin

        Host pve-01 pve
            HostName 192.0.2.10
            Port 2222

        Host backup
          HostName=backup.example.com
          User "root"
          ProxyJump pve-01

        Host *.example.org !skip.example.org
            Port 2200

        Host web.example.org
            User deploy

        Host *
            User fallback
            ServerAliveInterval 30

        Match host nas
            User ignored
        """

    @Test func importsPlainAliasesOnly() throws {
        let config = SSHConfig(text: sample, sshDirectory: URL(filePath: "/nonexistent"))
        #expect(config.entries.map(\.alias) == ["pve-01", "pve", "backup", "web.example.org"])
    }

    @Test func firstValueWins() throws {
        let config = SSHConfig(text: sample, sshDirectory: URL(filePath: "/nonexistent"))
        let byAlias = Dictionary(uniqueKeysWithValues: config.entries.map { ($0.alias, $0) })
        #expect(byAlias["pve-01"] == .init(alias: "pve-01", hostName: "192.0.2.10", user: "admin", port: 2222))
        #expect(byAlias["pve"]?.hostName == "192.0.2.10")
        #expect(byAlias["backup"] == .init(
            alias: "backup", hostName: "backup.example.com", user: "admin", port: nil, proxy: "pve-01"))
        // Global "User admin" comes before the host block, so it wins over "User deploy".
        #expect(byAlias["web.example.org"] == .init(
            alias: "web.example.org", hostName: "web.example.org", user: "admin", port: 2200))
    }

    @Test func wildcardsAndNegation() {
        #expect(SSHConfig.matches("a.example.org", patterns: ["*.example.org"]))
        #expect(!SSHConfig.matches("skip.example.org", patterns: ["*.example.org", "!skip.example.org"]))
        #expect(SSHConfig.matches("PVE", patterns: ["pve"]))
        #expect(!SSHConfig.matches("nas", patterns: ["pve?"]))
    }

    @Test func splitsLines() {
        #expect(SSHConfig.splitLine("  HostName = host.example.com") ?? ("", []) == ("hostname", ["host.example.com"]))
        #expect(SSHConfig.splitLine("IdentityFile \"~/My Keys/id\"")! == ("identityfile", ["~/My Keys/id"]))
        #expect(SSHConfig.splitLine("Host a b # comment")! == ("host", ["a", "b"]))
        #expect(SSHConfig.splitLine("   # only a comment") == nil)
        #expect(SSHConfig.splitLine("") == nil)
    }

    @Test func followsIncludesAndPercentH() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "RoundhouseTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: "config.d"), withIntermediateDirectories: true)
        try "Include config.d/*\nHost main\n  HostName %h.example.com\n"
            .write(to: dir.appending(path: "config"), atomically: true, encoding: .utf8)
        try "Host b-host\n  HostName 198.51.100.2\n"
            .write(to: dir.appending(path: "config.d/b"), atomically: true, encoding: .utf8)
        try "Host a-host\n  User alice\n"
            .write(to: dir.appending(path: "config.d/a"), atomically: true, encoding: .utf8)

        let config = SSHConfig(file: dir.appending(path: "config"))
        #expect(config.entries.map(\.alias) == ["a-host", "b-host", "main"])
        #expect(config.entries.last?.hostName == "main.example.com")
        #expect(config.files.count == 3)

        let connections = config.connections
        #expect(connections.allSatisfy { $0.kind == .ssh && $0.isImported })
        #expect(connections.first?.source == .sshConfig(alias: "a-host"))
        // IDs stay the same across reads.
        #expect(SSHConfig(file: dir.appending(path: "config")).connections.map(\.id) == connections.map(\.id))
    }

    @Test func missingFileGivesNothing() {
        let config = SSHConfig(file: URL(filePath: "/nonexistent/config"))
        #expect(config.entries.isEmpty && config.files.isEmpty)
    }
}
