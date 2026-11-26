// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import AppKit
import RoundhouseCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    /// Called after "Show in Dock" changes.
    let dockChanged: () -> Void

    @State private var hotKey = Preferences.hotKey
    @State private var recording = false
    @State private var hotKeyTaken = false
    @State private var recorder: Any?
    @State private var startAtLogin = LoginItem.isEnabled
    @State private var needsApproval = LoginItem.needsApproval
    @State private var showInDock = Preferences.showInDock
    @State private var sshTerminal = Preferences.sshTerminal
    @State private var lockMinutes = Preferences.vaultLockMinutes

    var body: some View {
        Form {
            Section {
                LabeledContent("Search panel shortcut") {
                    HStack {
                        if recording {
                            Text("Press the new shortcut…")
                                .foregroundStyle(.secondary)
                            Button("Cancel") { stopRecording() }
                        } else {
                            Text(verbatim: hotKey.displayName)
                                .font(.body.monospaced())
                            Button("Change…") { startRecording() }
                            if hotKey != .default {
                                Button("Reset") { apply(.default) }
                            }
                        }
                    }
                }
                if hotKeyTaken {
                    Text("This shortcut is used by another app. Choose a different one.")
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("The shortcut opens the search panel from any app. Use ⌘, ⌥ or ⌃ with a key.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Toggle("Start at login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { _, enabled in
                        LoginItem.set(enabled)
                        startAtLogin = LoginItem.isEnabled || LoginItem.needsApproval
                        needsApproval = LoginItem.needsApproval
                    }
                if needsApproval {
                    HStack {
                        Text("Allow Roundhouse in System Settings → General → Login Items.")
                            .foregroundStyle(.secondary)
                        Button("Open") { SMAppServiceSettings.open() }
                    }
                }
                Toggle("Show icon in the Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, show in
                        Preferences.showInDock = show
                        dockChanged()
                    }
            } footer: {
                Text("Without the Dock icon, open the connection list from the search panel (⌘O) or by opening Roundhouse again.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Picker("Terminal for SSH", selection: $sshTerminal) {
                    ForEach(terminals, id: \.self) { bundleID in
                        Text(verbatim: Launcher.appName(bundleID)).tag(bundleID)
                    }
                }
                .onChange(of: sshTerminal) { _, terminal in Preferences.sshTerminal = terminal }
                LabeledContent("Connection list") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.dataFileURL])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: model.dataFileURL.path))
                }
            }

            BitwardenSettings(vault: model.vault, lockMinutes: $lockMinutes)
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { stopRecording() }
    }

    private var terminals: [String] {
        var list = Launcher.clients(for: .ssh)
        if !list.contains(sshTerminal) { list.insert(sshTerminal, at: 0) }
        return list
    }

    private func startRecording() {
        recording = true
        hotKeyTaken = false
        // The current shortcut would open the panel instead of being recorded.
        HotKeyCenter.shared.unregister()
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                stopRecording()
                return nil
            }
            guard let key = HotKey(event: event) else { return nil }
            apply(key)
            return nil
        }
    }

    private func stopRecording() {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        if recording {
            recording = false
            HotKeyCenter.shared.register(hotKey)
        }
    }

    private func apply(_ key: HotKey) {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        recording = false
        if HotKeyCenter.shared.register(key) {
            hotKey = key
            Preferences.hotKey = key
            hotKeyTaken = false
        } else {
            hotKeyTaken = true
            HotKeyCenter.shared.register(hotKey)
        }
    }
}

/// Status of the Bitwarden CLI, unlock/lock, the automatic lock, and how to set `bw` up.
private struct BitwardenSettings: View {
    let vault: Vault
    @Binding var lockMinutes: Int

    var body: some View {
        Section {
            LabeledContent("Vault") {
                HStack {
                    status
                    switch vault.state {
                    case .locked:
                        Button("Unlock…") { Task { _ = await vault.ensureUnlocked(for: nil) } }
                    case .unlocked:
                        Button("Lock") { vault.lock() }
                    case .notInstalled, .notLoggedIn:
                        Button("Check Again") { Task { await vault.refresh() } }
                    case .unknown:
                        EmptyView()
                    }
                }
            }
            if let server = vault.server, vault.state != .notInstalled {
                LabeledContent("Server") { Text(verbatim: server).textSelection(.enabled) }
            }
            if let account = vault.account, vault.state == .locked || vault.state == .unlocked {
                LabeledContent("Account") { Text(verbatim: account).textSelection(.enabled) }
            }
            Picker("Lock after", selection: $lockMinutes) {
                ForEach(Preferences.vaultLockChoices, id: \.self) { minutes in
                    Text("\(minutes) min without use").tag(minutes)
                }
            }
            .onChange(of: lockMinutes) { _, minutes in Preferences.vaultLockMinutes = minutes }
        } header: {
            Text(verbatim: "Bitwarden")
        } footer: {
            footer
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .task { await vault.refresh() }
    }

    @ViewBuilder private var status: some View {
        switch vault.state {
        case .unknown: Text("Checking…").foregroundStyle(.secondary)
        case .notInstalled: Text("Bitwarden CLI not found").foregroundStyle(.secondary)
        case .notLoggedIn: Text("Not logged in").foregroundStyle(.secondary)
        case .locked: Label("Locked", systemImage: "lock.fill")
        case .unlocked: Label("Unlocked", systemImage: "lock.open.fill").foregroundStyle(.green)
        }
    }

    @ViewBuilder private var footer: some View {
        switch vault.state {
        case .notInstalled:
            Text("Passwords come from Bitwarden or Vaultwarden through the official Bitwarden CLI. Install it with “brew install bitwarden-cli”, then run “bw config server <your server>” and “bw login” in Terminal.")
        case .notLoggedIn:
            Text("Run “bw config server <your server>” and “bw login” in Terminal once, then click Check Again.")
        default:
            Text("The master password is never stored. The vault also locks when the Mac sleeps or the screen locks.")
        }
    }
}

enum SMAppServiceSettings {
    static func open() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}
