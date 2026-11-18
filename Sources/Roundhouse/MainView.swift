// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import AppKit
import RoundhouseCore
import SwiftUI

/// The main window: the list grouped by folder on the left, the selected entry on the right.
struct MainView: View {
    @Bindable var model: AppModel
    @State private var query = ""
    @State private var pendingDelete: Set<UUID> = []

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                if query.isEmpty {
                    ForEach(sections, id: \.title) { section in
                        Section {
                            ForEach(section.connections) { row($0) }
                        } header: {
                            if let title = section.title { Text(verbatim: title) }
                        }
                    }
                } else {
                    ForEach(Search.rank(model.connections, query: query, recents: model.library.recents)) { row($0) }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: Text("Search"))
            .contextMenu(forSelectionType: UUID.self) { ids in
                if ids.count == 1, let connection = ids.first.flatMap(model.connection(id:)) {
                    Button("Connect") { model.connect(connection) }
                    if !connection.isImported {
                        Button("Duplicate") { model.duplicate(connection) }
                    }
                }
                let deletable = ids.filter { model.connection(id: $0)?.isImported == false }
                if !deletable.isEmpty {
                    Divider()
                    Button("Delete…", role: .destructive) { pendingDelete = Set(deletable) }
                }
            } primaryAction: { ids in
                for id in ids { if let connection = model.connection(id: id) { model.connect(connection) } }
            }
            .onDeleteCommand {
                pendingDelete = model.selection.filter { model.connection(id: $0)?.isImported == false }
            }
            .overlay {
                if model.connections.isEmpty {
                    ContentUnavailableView {
                        Label("No connections", systemImage: "server.rack")
                    } description: {
                        Text("Add a connection with the + button. Hosts from ~/.ssh/config appear here automatically.")
                        Text("Then press \(Preferences.hotKey.displayName) anywhere to search and connect.")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            .toolbar {
                ToolbarItem {
                    Menu {
                        ForEach(Connection.Kind.allCases, id: \.self) { kind in
                            Button(kind.label) { model.addNew(kind: kind) }
                        }
                    } label: {
                        Label("Add Connection", systemImage: "plus")
                    } primaryAction: {
                        model.addNew(kind: .ssh)
                    }
                    .help("Add a connection (⌘N)")
                }
            }
        } detail: {
            if model.selection.count == 1, let id = model.selection.first, let connection = model.connection(id: id) {
                ConnectionDetail(model: model, connection: connection)
                    .id(id)
            } else if model.selection.count > 1 {
                ContentUnavailableView("Connections selected: \(model.selection.count)", systemImage: "square.stack")
            } else if model.showWelcome {
                WelcomeView(model: model)
            } else {
                ContentUnavailableView(
                    "No connection selected", systemImage: "network",
                    description: Text("Double-click a connection to open it."))
            }
        }
        .confirmationDialog(
            deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
        ) {
            Button("Delete", role: .destructive) {
                model.delete(ids: pendingDelete)
                pendingDelete = []
            }
        }
        .onAppear { model.startWatching("main") }
        .onDisappear { model.stopWatching("main") }
        .frame(minWidth: 680, minHeight: 400)
    }

    private var deleteTitle: String {
        if pendingDelete.count == 1, let name = pendingDelete.first.flatMap(model.connection(id:))?.name {
            return String(localized: "Delete “\(name)”?")
        }
        return String(localized: "Delete the selected connections (\(pendingDelete.count))?")
    }

    private func row(_ connection: Connection) -> some View {
        HStack(spacing: 8) {
            ReachabilityDot(state: model.reachability[connection.id], proxy: connection.proxy)
            KindIcon(kind: connection.kind)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: connection.name.isEmpty ? "–" : connection.name)
                Text(verbatim: connection.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .tag(connection.id)
    }

    /// Entries without a folder first, then folders alphabetically, ~/.ssh/config last.
    private var sections: [(title: String?, connections: [Connection])] {
        let sorted = model.connections.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let grouped = Dictionary(grouping: sorted) { $0.isImported ? "~/.ssh/config" : $0.folder ?? "" }
        let titles = grouped.keys.sorted { lhs, rhs in
            func rank(_ title: String) -> Int { title.isEmpty ? 0 : title == "~/.ssh/config" ? 2 : 1 }
            if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return titles.map { (title: $0.isEmpty ? nil : $0, connections: grouped[$0] ?? []) }
    }
}

/// Shown on the first launch: how to reach Roundhouse, which has no Dock icon.
private struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Welcome to Roundhouse")
                .font(.title.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                Label("Press \(Preferences.hotKey.displayName) in any app to search your connections and connect.",
                      systemImage: "magnifyingglass")
                Label("Roundhouse has no Dock icon: open it again, or press ⌘O in the search panel, to come back to this list.",
                      systemImage: "dock.rectangle")
                Label("Hosts from ~/.ssh/config appear automatically.", systemImage: "terminal")
            }
            .frame(maxWidth: 420, alignment: .leading)
            HStack {
                Button("Settings…") {
                    NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil)
                }
                Button("Add Connection") {
                    model.showWelcome = false
                    model.addNew(kind: .ssh)
                }
                Button("Got It") { model.showWelcome = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Green = answers, red = no answer, grey = not checked yet or behind a jump host.
struct ReachabilityDot: View {
    let state: Reachability?
    var proxy: String?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(help)
    }

    private var color: Color {
        switch state {
        case .reachable?: .green
        case .unreachable?: .red
        default: .gray.opacity(0.5)
        }
    }

    private var help: Text {
        if let proxy { return Text("Behind \(proxy) – not checked") }
        switch state {
        case .reachable?: return Text("Reachable")
        case .unreachable?: return Text("Not reachable")
        default: return Text("Not checked yet")
        }
    }
}

struct KindIcon: View {
    let kind: Connection.Kind

    var body: some View {
        Image(systemName: Self.symbol(kind))
            .help(Text(verbatim: kind.label))
    }

    static func symbol(_ kind: Connection.Kind) -> String {
        switch kind {
        case .ssh: "terminal"
        case .rdp: "pc"
        case .vnc: "display"
        case .web: "globe"
        case .winbox: "network"
        }
    }
}
