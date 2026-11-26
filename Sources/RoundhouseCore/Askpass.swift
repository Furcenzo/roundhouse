// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import Darwin
import Foundation

/// Entering an SSH password from Bitwarden without the clipboard, through `SSH_ASKPASS`.
///
/// Roundhouse starts ssh with `SSH_ASKPASS` pointing at its own executable, `SSH_ASKPASS_REQUIRE=force` and a one-time
/// token. When ssh needs a password it runs that executable (the helper mode), which hands the token and ssh's prompt
/// to the running app over a Unix socket only the user can open. The app answers once, only for a password prompt of
/// the entry's own host, and only to a client that is its own executable run by the same user. No password ever goes
/// on a command line or to disk. Any other prompt (host key yes/no, a key passphrase, a 2FA code, a second try) is
/// asked in the terminal as usual.
public enum Askpass {
    public static let tokenVariable = "ROUNDHOUSE_ASKPASS_TOKEN"
    public static let socketVariable = "ROUNDHOUSE_ASKPASS_SOCKET"

    /// Environment for ssh (passed to the terminal app, which hands it on to ssh).
    public static func environment(helper: String, socket: String, token: String) -> [String: String] {
        ["SSH_ASKPASS": helper, "SSH_ASKPASS_REQUIRE": "force", tokenVariable: token, socketVariable: socket]
    }

    /// True when ssh asks for the login password of `host` – not a key passphrase, not a code, not a jump host.
    /// ssh's prompts: "user@host's password: " and, for keyboard-interactive, "(user@host) Password: ".
    public static func isPasswordPrompt(_ prompt: String, host: String) -> Bool {
        let prompt = prompt.lowercased()
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty, prompt.contains("password"), !prompt.contains("passphrase") else { return false }
        return prompt.contains("@\(host)'s password") || prompt.contains("@\(host)) password")
    }

    /// Prompts that are answered with the text visible (ssh's host key question).
    public static func isConfirmation(_ prompt: String) -> Bool {
        prompt.lowercased().contains("(yes/no")
    }
}

/// The app's side: hands out passwords for registered one-time tokens.
public final class AskpassServer: @unchecked Sendable {
    public let socketPath: String
    /// The only executable allowed to ask (the app itself); nil = any process of the same user (tests).
    private let allowedPeer: String?
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private let listener: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "Roundhouse.Askpass")

    private struct Pending {
        var password: String
        var host: String
        var expires: Date
    }

    public enum Failure: Error {
        case socket(String)
    }

    /// Listens on `socketPath` (its folder is created with mode 0700; an old socket there is replaced).
    public init(socketPath: String, allowedPeer: String?) throws {
        self.socketPath = socketPath
        self.allowedPeer = allowedPeer.map { URL(filePath: $0).resolvingSymlinksInPath().path }
        let folder = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(folder, 0o700)
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket("socket") }
        var address = try Self.address(socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw Failure.socket("bind")
        }
        listener = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        stop()
    }

    public func stop() {
        source.cancel()
        unlink(socketPath)
        lock.withLock { pending.removeAll() }
    }

    /// A one-time token that gives `password` to the first password prompt for `host` within `lifetime` seconds.
    public func register(password: String, host: String, lifetime: TimeInterval = 120) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            removeExpired()
            pending[token] = Pending(password: password, host: host, expires: Date().addingTimeInterval(lifetime))
        }
        return token
    }

    /// The answer for a request; consumes the token when it gives the password.
    func answer(token: String, prompt: String) -> String? {
        lock.withLock {
            removeExpired()
            guard let entry = pending[token], Askpass.isPasswordPrompt(prompt, host: entry.host) else { return nil }
            pending[token] = nil
            return entry.password
        }
    }

    var pendingCount: Int { lock.withLock { pending.count } }

    private func removeExpired() {
        let now = Date()
        pending = pending.filter { $0.value.expires > now }
    }

    private func acceptOne() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard peerAllowed(client) else { return }

        guard let data = Self.readAll(client, limit: 16_384),
              let request = try? JSONDecoder().decode(AskpassRequest.self, from: data)
        else { return }
        let reply = answer(token: request.token, prompt: request.prompt).map { "OK\n" + $0 } ?? "NO"
        Self.writeAll(client, Data(reply.utf8))
    }

    /// Same user, and (in the app) the app's own executable.
    private func peerAllowed(_ client: Int32) -> Bool {
        var uid = uid_t()
        var gid = gid_t()
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return false }
        guard let allowedPeer else { return true }
        var pid = pid_t()
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = URL(filePath: String(decoding: buffer.prefix(Int(length)), as: UTF8.self)).resolvingSymlinksInPath().path
        return path == allowedPeer
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw Failure.socket("path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    static func readAll(_ fd: Int32, limit: Int) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= limit {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 { return nil }
            data.append(buffer, count: count)
        }
        return nil
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }
    }
}

struct AskpassRequest: Codable {
    var token: String
    var prompt: String
}

/// The helper's side: asks the app for the password.
public enum AskpassClient {
    /// The password, or nil when the app does not give it (wrong prompt, used or expired token, app not running).
    public static func request(socketPath: String, token: String, prompt: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard var address = try? AskpassServer.address(socketPath) else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, let body = try? JSONEncoder().encode(AskpassRequest(token: token, prompt: prompt))
        else { return nil }
        AskpassServer.writeAll(fd, body)
        shutdown(fd, SHUT_WR)
        guard let reply = AskpassServer.readAll(fd, limit: 16_384).map({ String(decoding: $0, as: UTF8.self) }),
              reply.hasPrefix("OK\n")
        else { return nil }
        return String(reply.dropFirst(3))
    }
}

/// The askpass mode of the app's executable (`SSH_ASKPASS`): prints the answer for ssh on stdout.
public enum AskpassHelper {
    /// Exit status for ssh: 0 = answered.
    public static func run(arguments: [String], environment: [String: String]) -> Int32 {
        let prompt = arguments.dropFirst().first ?? ""
        if environment["SSH_ASKPASS_PROMPT"] == nil,
           let token = environment[Askpass.tokenVariable], let socket = environment[Askpass.socketVariable],
           let password = AskpassClient.request(socketPath: socket, token: token, prompt: prompt) {
            FileHandle.standardOutput.write(Data((password + "\n").utf8))
            return 0
        }
        // Everything else is asked in the terminal, as ssh would without SSH_ASKPASS.
        guard let answer = askTerminal(prompt, echo: Askpass.isConfirmation(prompt)) else { return 1 }
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        return 0
    }

    private static func askTerminal(_ prompt: String, echo: Bool) -> String? {
        let tty = open("/dev/tty", O_RDWR)
        guard tty >= 0 else { return nil }
        defer { close(tty) }
        AskpassServer.writeAll(tty, Data(prompt.utf8))
        var saved = termios()
        let hasTerminal = tcgetattr(tty, &saved) == 0
        if hasTerminal, !echo {
            var silent = saved
            silent.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(tty, TCSAFLUSH, &silent)
        }
        defer {
            if hasTerminal, !echo {
                tcsetattr(tty, TCSAFLUSH, &saved)
                AskpassServer.writeAll(tty, Data("\n".utf8))
            }
        }
        var line = Data()
        var byte: UInt8 = 0
        while read(tty, &byte, 1) == 1 {
            if byte == 10 || byte == 13 { return String(decoding: line, as: UTF8.self) }
            line.append(byte)
        }
        return nil
    }
}
