// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import Foundation
import Network

public enum Reachability: Sendable, Equatable {
    case unknown
    case reachable
    case unreachable

    /// Tries a TCP connection to `host:port`; `.reachable` as soon as it is established, `.unreachable` when it
    /// fails or does not finish within `timeout` seconds. Sends no data.
    public static func check(host: String, port: Int, timeout: TimeInterval = 2) async -> Reachability {
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else {
            return .unknown
        }
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = Int(timeout.rounded(.up))
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let queue = DispatchQueue(label: "Roundhouse.Reachability")
        let result = OnceBox()

        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ value: Reachability) {
                guard result.claim() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.reachable)
                case .failed, .cancelled: finish(.unreachable)
                // "waiting" = no route / refused for now; Network would retry, we don't.
                case .waiting: finish(.unreachable)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(.unreachable) }
        }
    }
}

/// Lets exactly one of several callbacks finish a continuation.
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
