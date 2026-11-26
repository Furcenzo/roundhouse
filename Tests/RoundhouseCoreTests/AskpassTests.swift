// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import Foundation
import Testing
@testable import RoundhouseCore

@Suite struct AskpassPromptTests {
    @Test func passwordPromptsOfTheHostOnly() {
        #expect(Askpass.isPasswordPrompt("demo@test.example.com's password: ", host: "test.example.com"))
        #expect(Askpass.isPasswordPrompt("(demo@Test.Example.com) Password: ", host: "test.example.com"))
        #expect(Askpass.isPasswordPrompt("root@192.0.2.10's password: ", host: "192.0.2.10"))
        // A jump host, another host with the same suffix, a key passphrase, a 2FA code, a host key question.
        #expect(!Askpass.isPasswordPrompt("ops@jump.example.com's password: ", host: "test.example.com"))
        #expect(!Askpass.isPasswordPrompt("root@192.0.2.100's password: ", host: "192.0.2.10"))
        #expect(!Askpass.isPasswordPrompt("Enter passphrase for key '/x/id_ed25519': ", host: "test.example.com"))
        #expect(!Askpass.isPasswordPrompt("(demo@test.example.com) Verification code: ", host: "test.example.com"))
        #expect(!Askpass.isPasswordPrompt(
            "Are you sure you want to continue connecting (yes/no/[fingerprint])? ", host: "test.example.com"))
        #expect(Askpass.isConfirmation("Are you sure you want to continue connecting (yes/no/[fingerprint])? "))
        #expect(!Askpass.isPasswordPrompt("x@'s password: ", host: ""))
    }

    @Test func environmentForSSH() {
        let environment = Askpass.environment(helper: "/A.app/Contents/MacOS/A", socket: "/t/s", token: "abc")
        #expect(environment["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(environment["SSH_ASKPASS"] == "/A.app/Contents/MacOS/A")
        #expect(!environment.values.contains { $0.contains("password") })
    }
}

@Suite struct AskpassServerTests {
    func makeServer() throws -> AskpassServer {
        // sockaddr_un has room for 104 bytes; the test temp folder is short enough.
        let path = FileManager.default.temporaryDirectory.appending(path: "rh-\(UUID().uuidString.prefix(8))/s.sock").path
        return try AskpassServer(socketPath: path, allowedPeer: nil)
    }

    @Test func givesThePasswordOnceForTheRightPrompt() throws {
        let server = try makeServer()
        defer { server.stop() }
        let token = server.register(password: "sample-password", host: "test.example.com")
        #expect(token.count == 64)
        let socket = server.socketPath
        // A jump host or a passphrase does not use up the token.
        #expect(AskpassClient.request(socketPath: socket, token: token, prompt: "x@jump.example.com's password: ") == nil)
        #expect(AskpassClient.request(socketPath: socket, token: token, prompt: "Enter passphrase for key 'k': ") == nil)
        #expect(AskpassClient.request(socketPath: socket, token: token, prompt: "demo@test.example.com's password: ")
            == "sample-password")
        // Used up: a second try is asked in the terminal.
        #expect(AskpassClient.request(socketPath: socket, token: token, prompt: "demo@test.example.com's password: ") == nil)
        #expect(server.pendingCount == 0)
    }

    @Test func unknownAndExpiredTokens() throws {
        let server = try makeServer()
        defer { server.stop() }
        let prompt = "demo@test.example.com's password: "
        #expect(AskpassClient.request(socketPath: server.socketPath, token: "nope", prompt: prompt) == nil)
        let token = server.register(password: "p", host: "test.example.com", lifetime: -1)
        #expect(AskpassClient.request(socketPath: server.socketPath, token: token, prompt: prompt) == nil)
        #expect(AskpassClient.request(socketPath: "/nonexistent/s.sock", token: token, prompt: prompt) == nil)
    }

    @Test func socketIsPrivate() throws {
        let server = try makeServer()
        defer { server.stop() }
        let file = try FileManager.default.attributesOfItem(atPath: server.socketPath)
        let folder = try FileManager.default.attributesOfItem(atPath: (server.socketPath as NSString).deletingLastPathComponent)
        #expect((file[.posixPermissions] as? Int) == 0o600)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
    }

    @Test func onlyTheAllowedExecutableMayAsk() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "rh-\(UUID().uuidString.prefix(8))/s.sock").path
        let server = try AskpassServer(socketPath: path, allowedPeer: "/usr/bin/true")
        defer { server.stop() }
        let token = server.register(password: "p", host: "h.example.com")
        // The test runner is not /usr/bin/true.
        #expect(AskpassClient.request(socketPath: path, token: token, prompt: "u@h.example.com's password: ") == nil)
        #expect(server.pendingCount == 1)
    }
}

/// End to end with the real ssh and the app's executable as the helper, against Rebex's public test server
/// (published demo account). Needs the network and `swift build`: `RH_ASKPASS_E2E=1 swift test --filter AskpassEndToEnd`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RH_ASKPASS_E2E"] == "1"))
struct AskpassEndToEndTests {
    @Test func sshLogsInWithThePasswordFromRoundhouse() async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = root.appending(path: ".build/debug/Roundhouse").resolvingSymlinksInPath().path
        let folder = FileManager.default.temporaryDirectory.appending(path: "rh-\(UUID().uuidString.prefix(8))")
        let server = try AskpassServer(socketPath: folder.appending(path: "s.sock").path, allowedPeer: helper)
        defer { server.stop(); try? FileManager.default.removeItem(at: folder) }
        let token = server.register(password: "password", host: "test.rebex.net")

        var environment = ProcessInfo.processInfo.environment
        environment.merge(Askpass.environment(helper: helper, socket: server.socketPath, token: token)) { $1 }
        let result = try await ProcessResult.run(
            URL(filePath: "/usr/bin/ssh"),
            arguments: ["-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=\(folder.path)/known_hosts",
                        "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1",
                        "-l", "demo", "--", "test.rebex.net", "ls"],
            environment: environment, timeout: 30)
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self).contains("readme.txt"))
        #expect(server.pendingCount == 0)
    }
}
