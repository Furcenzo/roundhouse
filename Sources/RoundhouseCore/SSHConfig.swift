// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import CryptoKit
import Darwin
import Foundation

/// Reads `~/.ssh/config` (with its `Include`d files) and turns every `Host` alias without wildcards into an entry.
///
/// Only what the list shows and the reachability check needs is resolved (HostName, User, Port, ProxyJump,
/// ProxyCommand), following ssh's rule that the first value obtained wins. Everything else stays with ssh:
/// imported entries connect with `ssh <alias>`.
public struct SSHConfig: Sendable {
    public struct Entry: Equatable, Sendable {
        public var alias: String
        public var hostName: String
        public var user: String?
        public var port: Int?
        public var proxy: String?
    }

    struct Block {
        var patterns: [String]   // empty = settings before the first Host (apply to every host)
        var isMatch = false      // `Match` blocks depend on conditions we don't evaluate – skipped
        var options: [(key: String, value: String)] = []
    }

    public private(set) var entries: [Entry] = []
    /// Every file that was read (the config and its includes), to watch for changes.
    public private(set) var files: [URL] = []

    let sshDirectory: URL
    var blocks: [Block] = [Block(patterns: [])]
    var aliases: [String] = []

    /// Parses `file` (normally `~/.ssh/config`); a missing file gives no entries. Relative `Include` paths are
    /// resolved against `sshDirectory`, `~` against `homeDirectory`.
    public init(file: URL, sshDirectory: URL? = nil, homeDirectory: URL = .homeDirectory) {
        self.sshDirectory = sshDirectory ?? file.deletingLastPathComponent()
        read(file, home: homeDirectory, depth: 0)
        entries = resolveEntries()
    }

    /// Parses config text directly (tests); `Include` is resolved against `sshDirectory`.
    public init(text: String, sshDirectory: URL, homeDirectory: URL = .homeDirectory) {
        self.sshDirectory = sshDirectory
        parse(text, home: homeDirectory, depth: 0)
        entries = resolveEntries()
    }

    /// The imported entries as connections. IDs are derived from the alias, so they stay the same across launches.
    public var connections: [Connection] {
        entries.map { entry in
            Connection(
                id: Self.stableID(alias: entry.alias), name: entry.alias, kind: .ssh, host: entry.hostName,
                port: entry.port, user: entry.user, group: "~/.ssh/config", source: .sshConfig(alias: entry.alias),
                proxy: entry.proxy)
        }
    }

    static func stableID(alias: String) -> UUID {
        var bytes = Array(Insecure.SHA1.hash(data: Data(("ssh-config:" + alias).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5 (name-based, SHA-1)
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Reading

    private mutating func read(_ file: URL, home: URL, depth: Int) {
        guard depth < 16, let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        files.append(file)
        parse(text, home: home, depth: depth)
    }

    private mutating func parse(_ text: String, home: URL, depth: Int) {
        for rawLine in text.components(separatedBy: .newlines) {
            guard let (key, args) = Self.splitLine(rawLine) else { continue }
            switch key {
            case "host":
                blocks.append(Block(patterns: args))
                for pattern in args where Self.isPlainAlias(pattern) && !aliases.contains(pattern) {
                    aliases.append(pattern)
                }
            case "match":
                blocks.append(Block(patterns: [], isMatch: true))
            case "include":
                for path in args {
                    for url in Self.expandInclude(path, sshDirectory: sshDirectory, home: home) {
                        read(url, home: home, depth: depth + 1)
                    }
                }
            default:
                guard let value = args.first else { continue }
                blocks[blocks.count - 1].options.append((key, args.count > 1 ? args.joined(separator: " ") : value))
            }
        }
    }

    /// `Keyword value…` or `Keyword=value`; keyword lowercased, quoted arguments unquoted; nil for comments.
    static func splitLine(_ line: String) -> (String, [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        var words: [String] = []
        var current = ""
        var inQuotes = false
        var hasWord = false
        for char in trimmed {
            if char == "\"" {
                inQuotes.toggle()
                hasWord = true
            } else if !inQuotes && (char == " " || char == "\t" || (char == "=" && words.count + (hasWord ? 1 : 0) <= 1)) {
                if hasWord { words.append(current) }
                current = ""
                hasWord = false
            } else if !inQuotes && char == "#" && !hasWord {
                break   // trailing comment
            } else {
                current.append(char)
                hasWord = true
            }
        }
        if hasWord { words.append(current) }
        guard let keyword = words.first else { return nil }
        return (keyword.lowercased(), Array(words.dropFirst()))
    }

    static func isPlainAlias(_ pattern: String) -> Bool {
        !pattern.contains(where: { "*?!".contains($0) })
    }

    static func expandInclude(_ path: String, sshDirectory: URL, home: URL) -> [URL] {
        var full = path
        if full.hasPrefix("~/") {
            full = home.path + full.dropFirst()
        } else if !full.hasPrefix("/") {
            full = sshDirectory.path + "/" + full
        }
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(full, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_matchc)).compactMap { index in
            result.gl_pathv[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }.sorted { $0.path < $1.path }
    }

    // MARK: - Resolving

    private func resolveEntries() -> [Entry] {
        aliases.map { alias in
            var values: [String: String] = [:]
            for block in blocks where !block.isMatch && Self.matches(alias, patterns: block.patterns) {
                for option in block.options where values[option.key] == nil {
                    values[option.key] = option.value
                }
            }
            let hostName = values["hostname"].map { $0.replacingOccurrences(of: "%h", with: alias) } ?? alias
            var proxy = values["proxyjump"] ?? values["proxycommand"]
            if proxy?.lowercased() == "none" { proxy = nil }
            return Entry(
                alias: alias, hostName: hostName, user: values["user"], port: values["port"].flatMap(Int.init),
                proxy: proxy)
        }
    }

    /// ssh's `Host` matching: any positive pattern matches and no negated (`!`) one does.
    static func matches(_ host: String, patterns: [String]) -> Bool {
        if patterns.isEmpty { return true }
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if fnmatch(String(pattern.dropFirst()).lowercased(), host.lowercased(), 0) == 0 { return false }
            } else if fnmatch(pattern.lowercased(), host.lowercased(), 0) == 0 {
                matched = true
            }
        }
        return matched
    }
}
