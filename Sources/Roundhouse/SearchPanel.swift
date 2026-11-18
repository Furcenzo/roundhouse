// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import AppKit
import RoundhouseCore
import SwiftUI

/// What the panel shows: the query and the highlighted result.
@MainActor @Observable
final class PanelState {
    var query = "" {
        didSet { selected = 0 }
    }
    var selected = 0
    /// Bumped whenever the panel opens, so the search field takes focus again.
    var openCount = 0

    let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    var results: [Connection] {
        Array(Search.rank(model.connections, query: query, recents: model.library.recents).prefix(50))
    }
}

/// A borderless panel that can take keyboard input without activating the app (like Spotlight).
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The floating search panel on the global hotkey.
@MainActor
final class SearchPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let state: PanelState
    private let openMainWindow: () -> Void
    private var keyMonitor: Any?

    private lazy var panel: NSPanel = {
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: SearchPanelView(state: state, connect: { [weak self] in
            self?.connect($0)
        }))
        return panel
    }()

    init(model: AppModel, openMainWindow: @escaping () -> Void) {
        self.model = model
        self.state = PanelState(model: model)
        self.openMainWindow = openMainWindow
    }

    var isVisible: Bool { panel.isVisible }
    var window: NSWindow { panel }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show(query: String = "") {
        state.query = query
        state.openCount += 1
        // Upper third of the screen with the mouse pointer.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + visible.height * 0.72 - size.height / 2))
        }
        model.startWatching("panel")
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.stopWatching("panel")
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func connect(_ connection: Connection) {
        hide()
        model.connect(connection)
    }

    /// Arrows, Return, ⌘Return, ⌘O and Escape – handled here, because the search field would take them.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let results = state.results
        let command = event.modifierFlags.contains(.command)
        switch event.specialKey {
        case .downArrow?:
            if !results.isEmpty { state.selected = min(state.selected + 1, results.count - 1) }
            return true
        case .upArrow?:
            state.selected = max(state.selected - 1, 0)
            return true
        case .carriageReturn?, .enter?:
            guard results.indices.contains(state.selected) else { return true }
            let connection = results[state.selected]
            if command {
                copyAddress(connection)
            } else {
                connect(connection)
            }
            return true
        default:
            break
        }
        if event.keyCode == 53 {   // Escape
            if state.query.isEmpty { hide() } else { state.query = "" }
            return true
        }
        if command, event.charactersIgnoringModifiers == "o" || event.charactersIgnoringModifiers == "," {
            hide()
            openMainWindow()
            return true
        }
        return false
    }

    private func copyAddress(_ connection: Connection) {
        let text = connection.kind == .web ? connection.address : connection.host
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        hide()
    }
}

private struct SearchPanelView: View {
    let state: PanelState
    let connect: (Connection) -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var state = state
        let results = state.results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                TextField("Search connections", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($fieldFocused)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            if results.isEmpty {
                VStack(spacing: 6) {
                    Spacer()
                    if state.model.connections.isEmpty {
                        Text("No connections yet.")
                        Text("Press ⌘O to open the list and add some.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No matches")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, connection in
                                ResultRow(
                                    connection: connection, reachability: state.model.reachability[connection.id],
                                    isSelected: index == state.selected
                                )
                                .id(connection.id)
                                .contentShape(Rectangle())
                                .onTapGesture { connect(connection) }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: state.selected) { _, index in
                        guard results.indices.contains(index) else { return }
                        proxy.scrollTo(results[index].id)
                    }
                }
            }

            Divider()
            HStack(spacing: 16) {
                Text("↩ Connect")
                Text("⌘↩ Copy address")
                Spacer()
                Text("⌘O Edit list")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 620, height: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onChange(of: state.openCount, initial: true) { fieldFocused = true }
    }
}

private struct ResultRow: View {
    let connection: Connection
    let reachability: Reachability?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            ReachabilityDot(state: reachability, proxy: connection.proxy)
            KindIcon(kind: connection.kind)
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: connection.name)
                    .font(.body.weight(.medium))
                Text(verbatim: connection.address)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
            Spacer()
            if let folder = connection.folder {
                Text(verbatim: folder)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
