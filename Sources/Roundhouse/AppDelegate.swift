// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import AppKit
import RoundhouseCore
import SwiftUI

@main
@MainActor
enum RoundhouseMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

/// Runs all the time for the hotkey. Without the Dock icon (the default) the app is an accessory app and
/// becomes a regular one only while one of its windows is open, so the menu bar and ⌘Tab work there.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private lazy var panel = SearchPanelController(model: model) { [weak self] in self?.showMainWindow() }
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make(delegate: self)
        let launchedAtLogin = Self.launchedAsLoginItem()
        updateActivationPolicy()

        HotKeyCenter.shared.action = { [weak self] in self?.panel.toggle() }
        let registered = HotKeyCenter.shared.register(Preferences.hotKey)

        if !launchedAtLogin { showMainWindow() }
        if let error = model.loadError {
            Alerts.show(
                String(localized: "The connection list could not be read."),
                detail: String(localized: "Roundhouse will not save changes, so the file stays as it is. \(error)"))
        }
        if let folder = UserDefaults.standard.string(forKey: "snapshotFolder") {
            Task { await saveSnapshots(to: URL(filePath: folder)) }
        }
        if !registered {
            Alerts.show(
                String(localized: "The shortcut \(Preferences.hotKey.displayName) is used by another app."),
                detail: String(localized: "Choose a different shortcut in Settings."))
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Windows

    @objc func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Roundhouse"
            window.contentViewController = NSHostingController(rootView: MainView(model: model))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("MainWindow")
            mainWindow = window
        }
        present(mainWindow!)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = String(localized: "Roundhouse Settings")
            window.contentViewController = NSHostingController(
                rootView: SettingsView(model: model) { [weak self] in self?.updateActivationPolicy() })
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        present(settingsWindow!)
    }

    @objc func showSearchPanel() {
        panel.show()
    }

    @objc func newConnection(_ sender: Any?) {
        showMainWindow()
        model.addNew(kind: .ssh)
    }

    private func present(_ window: NSWindow) {
        panel.hide()
        NSApp.setActivationPolicy(.regular)
        // macOS may refuse to activate an app that has just turned from an accessory into a regular one (at launch,
        // when it was opened again from Finder or Spotlight), and the window would stay behind the others. So the
        // window is brought to the front even when the app is not active, and activation is tried again once the
        // new policy has taken effect.
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
        DispatchQueue.main.async {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Wait until the window is really gone before checking which ones are still open.
        DispatchQueue.main.async { self.updateActivationPolicy() }
    }

    private func updateActivationPolicy() {
        let windowOpen = [mainWindow, settingsWindow].contains { $0?.isVisible == true }
        let policy: NSApplication.ActivationPolicy = Preferences.showInDock || windowOpen ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    /// `--args -snapshotFolder <dir>` (with `-demo`): draws the main window, the search panel and the settings into
    /// PNG files and quits. The views draw themselves, so no screen recording permission is needed and nothing else
    /// of the screen (desktop, Dock, menu bar) gets into the images.
    private func saveSnapshots(to folder: URL) async {
        func save(_ window: NSWindow?, _ name: String) async {
            try? await Task.sleep(for: .seconds(2))
            guard let view = window?.contentView?.superview ?? window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: name + ".png"))
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        showMainWindow()
        mainWindow?.setContentSize(NSSize(width: 900, height: 720))
        let selected = UserDefaults.standard.string(forKey: "snapshotSelect")
        model.selection = model.connections.first { $0.name == selected }.map { [$0.id] } ?? []
        await save(mainWindow, "main")
        panel.show(query: UserDefaults.standard.string(forKey: "snapshotQuery") ?? "")
        await save(panel.window, "panel")
        panel.hide()
        showSettings()
        await save(settingsWindow, "settings")
        NSApp.terminate(nil)
    }

    /// Started by macOS at login (then no window opens, the app just waits for the hotkey).
    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

/// The menu bar of the app (built in code, the app has no storyboard).
@MainActor
enum MainMenu {
    static func make(delegate: AppDelegate) -> NSMenu {
        let name = "Roundhouse"
        let menu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About \(name)"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item(String(localized: "Settings…"), #selector(AppDelegate.showSettings), ",", delegate))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide \(name)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: String(localized: "Show All"),
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit \(name)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: name, to: menu)

        let fileMenu = NSMenu(title: String(localized: "File"))
        fileMenu.addItem(item(String(localized: "New Connection"), #selector(AppDelegate.newConnection(_:)), "n", delegate))
        fileMenu.addItem(item(String(localized: "Search Panel"), #selector(AppDelegate.showSearchPanel), "f", delegate))
        fileMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(fileMenu, to: menu)

        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(editMenu, to: menu)

        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(item(String(localized: "Connections"), #selector(AppDelegate.showMainWindow), "0", delegate))
        add(windowMenu, to: menu)
        NSApp.windowsMenu = windowMenu
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private static func add(_ submenu: NSMenu, title: String? = nil, to menu: NSMenu) {
        let item = NSMenuItem(title: title ?? submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }
}
