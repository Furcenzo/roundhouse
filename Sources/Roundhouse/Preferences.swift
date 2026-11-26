// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import AppKit
import Carbon.HIToolbox
import RoundhouseCore
import ServiceManagement

/// Settings stored in UserDefaults.
@MainActor
enum Preferences {
    private static var defaults: UserDefaults { .standard }

    static var showInDock: Bool {
        get { defaults.bool(forKey: "showInDock") }
        set { defaults.set(newValue, forKey: "showInDock") }
    }

    /// The introduction in the main window was dismissed.
    static var welcomeShown: Bool {
        get { defaults.bool(forKey: "welcomeShown") }
        set { defaults.set(newValue, forKey: "welcomeShown") }
    }

    /// Terminal for SSH entries that don't choose their own.
    static var sshTerminal: String {
        get { defaults.string(forKey: "sshTerminal") ?? KnownClient.ghostty }
        set { defaults.set(newValue, forKey: "sshTerminal") }
    }

    /// The Bitwarden vault locks after this many minutes without use.
    static var vaultLockMinutes: Int {
        get { (defaults.object(forKey: "vaultLockMinutes") as? Int) ?? 15 }
        set { defaults.set(newValue, forKey: "vaultLockMinutes") }
    }

    static let vaultLockChoices = [5, 15, 30, 60]

    /// Path of the `bw` executable when it is not in a usual place (`defaults write … bwPath <path>`).
    static var bwPath: String? {
        defaults.string(forKey: "bwPath")
    }

    static var hotKey: HotKey {
        get {
            guard let data = defaults.data(forKey: "hotKey"), let key = try? JSONDecoder().decode(HotKey.self, from: data)
            else { return .default }
            return key
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "hotKey") }
    }
}

/// A global keyboard shortcut: virtual key code + Carbon modifier flags.
struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// The key as shown ("Space", "K"), captured when the shortcut was recorded.
    var keyName: String

    static let `default` = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), keyName: "Space")

    var displayName: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyName
    }

    /// nil when the event has no ⌘, ⌥ or ⌃ (a shortcut of plain letters would block typing everywhere).
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        guard modifiers != 0 else { return nil }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyName: Self.name(of: event))
    }

    init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    private static func name(of event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            break
        }
        if let index = functionKeyCodes.firstIndex(of: Int(event.keyCode)) {
            return "F\(index + 1)"
        }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }

    private static let functionKeyCodes = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
        kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
}

/// Registers one global hotkey with Carbon's RegisterEventHotKey – works without the Accessibility permission.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var action: (() -> Void)?
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// false when the shortcut is taken by another app or the system.
    @discardableResult
    func register(_ key: HotKey) -> Bool {
        unregister()
        installHandler()
        let id = EventHotKeyID(signature: OSType(0x524E_4448), id: 1)   // "RNDH"
        let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &reference)
        return status == noErr
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    private func installHandler() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { HotKeyCenter.shared.action?() }
            return noErr
        }, 1, &type, nil, &handler)
    }
}

/// Start at login (SMAppService), so the hotkey works all the time.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// The user has to allow it in System Settings → General → Login Items.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Alerts.show(String(localized: "Starting at login could not be changed."), detail: error.localizedDescription)
        }
    }
}
