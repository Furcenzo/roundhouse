// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import Foundation

/// Ranks connections for a search query: every word of the query has to match the name, address, folder, tags or
/// kind; better matches (exact, prefix, name over host) and recently used entries come first.
public enum Search {
    public static func rank(_ connections: [Connection], query: String, recents: [String] = []) -> [Connection] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let recentIndex = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

        let scored: [(Connection, Int)] = connections.compactMap { connection in
            var total = 0
            for word in words {
                guard let score = score(word, connection) else { return nil }
                total += score
            }
            if let index = recentIndex[connection.stableKey] {
                // Without a query the recents lead; with one they only break near-ties.
                total += words.isEmpty ? 1000 - index : max(0, 25 - index)
            }
            return (connection, total)
        }
        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.name.localizedStandardCompare(rhs.0.name) == .orderedAscending
        }.map(\.0)
    }

    /// nil = the word does not match the connection.
    static func score(_ word: String, _ connection: Connection) -> Int? {
        let name = connection.name.lowercased()
        var best: Int?
        func consider(_ value: Int?) {
            if let value, value > (best ?? -1) { best = value }
        }

        if name == word {
            consider(100)
        } else if name.hasPrefix(word) {
            consider(80)
        } else if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(word) }) {
            consider(70)
        } else if name.contains(word) {
            consider(60)
        } else if isSubsequence(word, of: name) {
            consider(30)
        }

        for field in [connection.host, connection.reachabilityHost, connection.user ?? ""] {
            let field = field.lowercased()
            if field == word {
                consider(55)
            } else if field.hasPrefix(word) {
                consider(50)
            } else if field.contains(word) {
                consider(35)
            }
        }
        let others = [connection.folder ?? "", connection.kind.label] + connection.tags
        for field in others.map({ $0.lowercased() }) {
            if field == word { consider(45) } else if field.hasPrefix(word) { consider(25) }
        }
        return best
    }

    /// "pv1" matches "pve-01": the letters appear in order.
    static func isSubsequence(_ word: String, of text: String) -> Bool {
        var remaining = word[...]
        for char in text where char == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
