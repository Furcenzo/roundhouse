// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import Foundation

/// The state of the vault as `bw status` reports it.
public struct VaultStatus: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable {
        case unauthenticated, locked, unlocked
    }

    public var status: State
    public var serverUrl: String?
    public var userEmail: String?

    public init(status: State, serverUrl: String? = nil, userEmail: String? = nil) {
        self.status = status
        self.serverUrl = serverUrl
        self.userEmail = userEmail
    }
}

/// An item of the vault as the picker shows it. Decoding reads only these fields – never the password.
public struct VaultItemSummary: Decodable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var username: String?
    public var uri: String?

    public init(id: String, name: String, username: String? = nil, uri: String? = nil) {
        self.id = id
        self.name = name
        self.username = username
        self.uri = uri
    }

    private enum CodingKeys: String, CodingKey { case id, name, login }
    private enum LoginKeys: String, CodingKey { case username, uris }
    private struct URI: Decodable { var uri: String? }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        if let login = try? container.nestedContainer(keyedBy: LoginKeys.self, forKey: .login) {
            username = try login.decodeIfPresent(String.self, forKey: .username)
            uri = try login.decodeIfPresent([URI].self, forKey: .uris)?.compactMap(\.uri).first
        }
    }
}

/// User name and password of one item. Kept only as long as it is needed; never printed.
public struct VaultCredential: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var username: String?
    public var password: String

    public init(username: String?, password: String) {
        self.username = username
        self.password = password
    }

    public var description: String { "VaultCredential(username: \(username ?? "nil"), password: <hidden>)" }
    public var debugDescription: String { description }
}

public enum VaultError: Error, Equatable, Sendable {
    /// No `bw` executable was found.
    case notInstalled
    /// `bw login` has not been run (or the login expired).
    case notLoggedIn
    /// The vault is locked, or the session key is no longer valid.
    case locked
    case wrongPassword
    case itemNotFound
    /// The item has no password.
    case noPassword
    /// Not a valid item ID (Bitwarden IDs are UUIDs).
    case invalidItemID
    case timedOut
    /// Anything else, with the message of `bw` (never contains a secret).
    case failed(String)
}

/// Talks to the official Bitwarden CLI (`bw`), which works with Bitwarden and Vaultwarden servers alike.
///
/// Secrets never go on a command line: the master password is handed to `bw unlock --passwordenv` in an environment
/// variable of the child process, and the session key to the other commands in `BW_SESSION`.
public struct BitwardenCLI: Sendable {
    public let executable: URL
    public var timeout: TimeInterval

    /// Name of the environment variable that carries the master password to `bw unlock`.
    public static let passwordVariable = "ROUNDHOUSE_BW_PASSWORD"

    public init(executable: URL, timeout: TimeInterval = 60) {
        self.executable = executable
        self.timeout = timeout
    }

    /// Where Homebrew and npm put `bw`. Apps started from Finder don't get the shell's PATH, so it is searched here.
    public static let searchPaths = [
        "/opt/homebrew/bin/bw", "/usr/local/bin/bw", "~/.npm-global/bin/bw", "~/.local/bin/bw",
    ]

    /// The `bw` executable: `override` (a path) if set, otherwise the first one of `searchPaths` that exists.
    public static func locate(override: String? = nil) -> BitwardenCLI? {
        let candidates = override.flatMap { $0.isEmpty ? nil : [$0] } ?? searchPaths
        for path in candidates {
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return BitwardenCLI(executable: URL(filePath: expanded))
            }
        }
        return nil
    }

    // MARK: - Commands

    public func status(session: String?) async throws(VaultError) -> VaultStatus {
        let output = try await run(["status"], session: session)
        do {
            return try JSONDecoder().decode(VaultStatus.self, from: output)
        } catch {
            throw .failed(String(localized: "Unexpected answer of bw status."))
        }
    }

    /// Unlocks the vault and returns the session key.
    public func unlock(password: String) async throws(VaultError) -> String {
        let output = try await run(
            ["unlock", "--passwordenv", Self.passwordVariable, "--raw"], session: nil,
            extra: [Self.passwordVariable: password])
        let key = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { throw .failed("bw unlock") }
        return key
    }

    /// Locks the vault: the session key stops working.
    public func lock() async {
        _ = try? await run(["lock"], session: nil)
    }

    /// Starts `bw lock` without waiting for it (when the app quits).
    public func startLock() {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["lock", "--nointeraction"]
        process.environment = environment(session: nil, extra: [:])
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Downloads the vault from the server (new items appear in the picker).
    public func sync(session: String) async throws(VaultError) {
        _ = try await run(["sync"], session: session)
    }

    /// Login items of the vault, sorted by name.
    public func loginItems(session: String) async throws(VaultError) -> [VaultItemSummary] {
        let output = try await run(["list", "items"], session: session)
        struct Typed: Decodable { var type: Int? }
        do {
            let types = try JSONDecoder().decode([Typed].self, from: output)
            let items = try JSONDecoder().decode([VaultItemSummary].self, from: output)
            return zip(types, items).filter { $0.0.type == 1 }.map(\.1)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            throw .failed(String(localized: "Unexpected answer of bw list."))
        }
    }

    /// User name and password of the item `id`.
    public func credential(id: String, session: String) async throws(VaultError) -> VaultCredential {
        guard Self.isValidItemID(id) else { throw .invalidItemID }
        let output = try await run(["get", "item", id], session: session)
        struct Item: Decodable {
            struct Login: Decodable { var username: String?; var password: String? }
            var login: Login?
        }
        guard let item = try? JSONDecoder().decode(Item.self, from: output) else {
            throw .failed(String(localized: "Unexpected answer of bw get."))
        }
        guard let password = item.login?.password, !password.isEmpty else { throw .noPassword }
        return VaultCredential(username: item.login?.username?.nilIfEmpty, password: password)
    }

    /// Bitwarden item IDs are UUIDs; anything else (e.g. text starting with "-") never reaches `bw`.
    public static func isValidItemID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    // MARK: - Running bw

    /// Environment of the child process: only what `bw` needs, never the app's own environment as a whole.
    func environment(session: String?, extra: [String: String]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "BITWARDENCLI_APPDATA_DIR", "NODE_EXTRA_CA_CERTS"] {
            environment[key] = inherited[key]
        }
        // bw is a Node.js script; its `#!/usr/bin/env node` needs node in the PATH.
        let folder = executable.deletingLastPathComponent().path
        environment["PATH"] = [folder, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        environment["BW_NOINTERACTION"] = "true"
        environment["BW_SESSION"] = session
        for (key, value) in extra { environment[key] = value }
        return environment
    }

    private func run(_ arguments: [String], session: String?, extra: [String: String] = [:])
        async throws(VaultError) -> Data
    {
        let result: ProcessResult
        do {
            result = try await ProcessResult.run(
                executable, arguments: arguments + ["--nointeraction"],
                environment: environment(session: session, extra: extra), timeout: timeout)
        } catch let error as VaultError {
            throw error
        } catch {
            throw .notInstalled
        }
        guard result.status == 0 else { throw Self.error(from: result) }
        return result.stdout
    }

    static func error(from result: ProcessResult) -> VaultError {
        // bw prints its errors to stderr (sometimes to stdout); neither carries a secret.
        let message = (String(decoding: result.stderr, as: UTF8.self) + "\n"
            + String(decoding: result.stdout.prefix(500), as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = message.lowercased()
        if lower.contains("invalid master password") { return .wrongPassword }
        if lower.contains("not logged in") { return .notLoggedIn }
        if lower.contains("vault is locked") || lower.contains("session key is invalid") { return .locked }
        if lower.contains("not found") { return .itemNotFound }
        let firstLine = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return .failed(String(firstLine.prefix(300)))
    }
}

/// Exit status and output of a finished child process.
struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data

    /// Runs `executable` (no shell) and waits for it, at most `timeout` seconds (then it is terminated).
    static func run(_ executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval)
        async throws -> ProcessResult
    {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let timedOut = TimeoutFlag()
        return try await withCheckedThrowingContinuation { continuation in
            // Read both pipes while the process runs, so a large output cannot block it.
            let group = DispatchGroup()
            let output = OutputBox()
            group.enter()
            group.enter()
            process.terminationHandler = { process in
                group.notify(queue: .global()) {
                    if timedOut.value {
                        continuation.resume(throwing: VaultError.timedOut)
                    } else {
                        let (out, err) = output.get()
                        continuation.resume(returning: ProcessResult(status: process.terminationStatus, stdout: out, stderr: err))
                    }
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            for (pipe, isError) in [(stdout, false), (stderr, true)] {
                DispatchQueue.global().async {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    output.set(data, error: isError)
                    group.leave()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning {
                    timedOut.value = true
                    process.terminate()
                }
            }
        }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func set(_ data: Data, error: Bool) {
        lock.withLock { if error { err = data } else { out = data } }
    }

    func get() -> (Data, Data) {
        lock.withLock { (out, err) }
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
