// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import Foundation
import Testing
@testable import RoundhouseCore

@Suite struct LaunchPlanTests {
    @Test func sshInGhostty() throws {
        let manual = Connection(name: "pve", kind: .ssh, host: "192.0.2.10", port: 2222, user: "root")
        #expect(try LaunchPlan.make(for: manual) == .launchApp(
            KnownClient.ghostty, arguments: ["-e", "ssh", "-p", "2222", "-l", "root", "--", "192.0.2.10"]))

        let defaultPort = Connection(name: "pve", kind: .ssh, host: "pve.example.com", port: 22)
        #expect(try LaunchPlan.make(for: defaultPort) == .launchApp(
            KnownClient.ghostty, arguments: ["-e", "ssh", "--", "pve.example.com"]))

        let imported = SSHConfig(text: "Host nas\n HostName 192.0.2.5\n Port 2022", sshDirectory: URL(filePath: "/x"))
            .connections[0]
        #expect(try LaunchPlan.make(for: imported) == .launchApp(KnownClient.ghostty, arguments: ["-e", "ssh", "--", "nas"]))
    }

    @Test func sshInOtherTerminalsUsesURL() throws {
        let manual = Connection(name: "pve", kind: .ssh, host: "192.0.2.10", port: 2222, user: "root")
        #expect(try LaunchPlan.make(for: manual, client: KnownClient.terminal)
            == .openURL(URL(string: "ssh://root@192.0.2.10:2222")!, app: KnownClient.terminal))
    }

    @Test func rejectsHostsThatLookLikeOptions() {
        for host in ["-oProxyCommand=evil", "a b", "", "user@host"] {
            #expect(throws: LaunchPlan.Problem.self) {
                try LaunchPlan.make(for: Connection(name: "x", kind: .ssh, host: host))
            }
        }
    }

    @Test func rdpFileHasNoPassword() throws {
        let rdp = Connection(name: "win", kind: .rdp, host: "192.0.2.20", port: 3390, user: "EXAMPLE\\admin")
        guard case .rdpFile(let contents, let app) = try LaunchPlan.make(for: rdp) else {
            Issue.record("expected an .rdp file")
            return
        }
        #expect(app == KnownClient.windowsApp)
        #expect(contents.hasPrefix("full address:s:192.0.2.20:3390\r\nusername:s:EXAMPLE\\admin\r\n"))
        #expect(!contents.lowercased().contains("password"))
    }

    @Test func vncWebWinBox() throws {
        #expect(try LaunchPlan.make(for: Connection(name: "mac", kind: .vnc, host: "mac.example.com", user: "me"))
            == .openURL(URL(string: "vnc://me@mac.example.com")!, app: KnownClient.screenSharing))

        let web = Connection(name: "pve", kind: .web, host: "192.0.2.10", url: "192.0.2.10:8006")
        #expect(try LaunchPlan.make(for: web) == .openURL(URL(string: "https://192.0.2.10:8006")!, app: nil))
        #expect(web.effectivePort == 8006)
        #expect(web.reachabilityHost == "192.0.2.10")
        let webNoURL = Connection(name: "router", kind: .web, host: "router.example.com", client: "com.apple.Safari")
        #expect(try LaunchPlan.make(for: webNoURL) == .openURL(URL(string: "https://router.example.com")!, app: "com.apple.Safari"))
        #expect(throws: LaunchPlan.Problem.invalidURL) {
            try LaunchPlan.make(for: Connection(name: "x", kind: .web, host: "", url: "javascript:alert(1)"))
        }

        #expect(try LaunchPlan.make(for: Connection(name: "mt", kind: .winbox, host: "192.0.2.1", user: "admin"))
            == .launchApp(KnownClient.winBox, arguments: ["192.0.2.1", "admin", ""]))
        #expect(try LaunchPlan.make(for: Connection(name: "mt", kind: .winbox, host: "2001:db8::1", port: 8292))
            == .launchApp(KnownClient.winBox, arguments: ["[2001:db8::1]:8292"]))
        #expect(try LaunchPlan.make(for: Connection(name: "mt", kind: .winbox, host: "192.0.2.1", user: "ops"))
            == .launchApp(KnownClient.winBox, arguments: ["192.0.2.1", "ops", ""]))
    }
}

@Suite struct VaultLaunchTests {
    let itemID = "6f1c2b3a-0d4e-4f50-9a61-7b8c9d0e1f21"
    let credential = VaultCredential(username: "admin", password: "sample-switch-password")

    @Test func winBoxLogsInAtOnceOnlyWhenTurnedOn() throws {
        var entry = Connection(name: "sw", kind: .winbox, host: "192.0.2.2", vaultItemID: itemID)
        // Off by default: the password never goes on the command line.
        #expect(try LaunchPlan.make(for: entry, credential: credential)
            == .launchApp(KnownClient.winBox, arguments: ["192.0.2.2"]))

        entry.loginAtOnce = true
        #expect(try LaunchPlan.make(for: entry, credential: credential)
            == .launchApp(KnownClient.winBox, arguments: ["192.0.2.2", "admin", "sample-switch-password"]))
        // The user of the entry wins over the one of the item.
        entry.user = "ops"
        #expect(try LaunchPlan.make(for: entry, credential: credential)
            == .launchApp(KnownClient.winBox, arguments: ["192.0.2.2", "ops", "sample-switch-password"]))
        // Without a credential (vault locked, cancelled) as in 0.1.
        #expect(try LaunchPlan.make(for: entry) == .launchApp(KnownClient.winBox, arguments: ["192.0.2.2", "ops", ""]))
    }

    @Test func winBoxWithoutAnyUserPassesOnlyTheAddress() throws {
        let entry = Connection(name: "sw", kind: .winbox, host: "192.0.2.2", vaultItemID: itemID, loginAtOnce: true)
        #expect(try LaunchPlan.make(for: entry, credential: VaultCredential(username: nil, password: "x"))
            == .launchApp(KnownClient.winBox, arguments: ["192.0.2.2"]))
    }

    @Test func atOnceNeedsAValidItem() {
        let noItem = Connection(name: "sw", kind: .winbox, host: "192.0.2.2", loginAtOnce: true)
        #expect(!noItem.logsInAtOnce)
        let badItem = Connection(name: "sw", kind: .winbox, host: "192.0.2.2", vaultItemID: "-x", loginAtOnce: true)
        #expect(!badItem.logsInAtOnce)
    }

    @Test func otherKindsNeverGetThePassword() throws {
        for kind in [Connection.Kind.ssh, .rdp, .vnc, .web] {
            let entry = Connection(name: "x", kind: kind, host: "192.0.2.5", user: "admin",
                                   url: "https://192.0.2.5", vaultItemID: itemID, loginAtOnce: true)
            let plan = try LaunchPlan.make(for: entry, credential: credential)
            #expect(!String(describing: plan).contains("sample-switch-password"))
        }
    }

    @Test func oldFilesDecode() throws {
        let json = #"{"id":"86A3A420-8437-59B4-BA4F-C18F230F891D","kind":"winbox","name":"r","host":"192.0.2.1","tags":[],"source":{"manual":{}}}"#
        let entry = try JSONDecoder().decode(Connection.self, from: Data(json.utf8))
        #expect(entry.loginAtOnce == nil && entry.vaultItemID == nil && !entry.logsInAtOnce)
    }
}
