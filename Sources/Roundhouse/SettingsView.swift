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
        }
        .formStyle(.grouped)
        .frame(width: 480)
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

enum SMAppServiceSettings {
    static func open() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }
}
