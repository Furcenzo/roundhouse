// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Furcenzo

import AppKit
import RoundhouseCore
import SwiftUI

/// The right side of the main window: an editor for manual entries, a read-only view for imported ones.
struct ConnectionDetail: View {
    let model: AppModel
    let connection: Connection

    var body: some View {
        if connection.isImported {
            ImportedDetail(model: model, connection: connection)
        } else {
            ConnectionEditor(model: model, original: connection)
        }
    }
}

private struct ConnectionEditor: View {
    let model: AppModel
    @State private var draft: Connection
    @FocusState private var nameFocused: Bool

    init(model: AppModel, original: Connection) {
        self.model = model
        _draft = State(initialValue: original)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("e.g. Proxmox"))
                    .focused($nameFocused)
                Picker("Type", selection: $draft.kind) {
                    ForEach(Connection.Kind.allCases, id: \.self) { kind in
                        Label { Text(verbatim: kind.label) } icon: { Image(systemName: KindIcon.symbol(kind)) }
                            .tag(kind)
                    }
                }
                if draft.kind == .web {
                    TextField("URL", text: optional($draft.url), prompt: Text(verbatim: "https://192.0.2.10:8006"))
                }
                TextField(
                    draft.kind == .web ? "Host (optional)" : "Host", text: $draft.host,
                    prompt: Text("Name or IP address"))
                if draft.kind != .web {
                    TextField("Port", text: portText, prompt: Text(verbatim: String(draft.kind.defaultPort)))
                }
                if draft.kind != .web {
                    TextField("User", text: optional($draft.user), prompt: Text("Optional"))
                }
            }

            Section {
                LabeledContent("Folder") {
                    HStack(spacing: 4) {
                        TextField("Folder", text: optional($draft.group), prompt: Text("e.g. Homelab"))
                            .labelsHidden()
                        if !otherFolders.isEmpty {
                            Menu {
                                ForEach(otherFolders, id: \.self) { folder in
                                    Button(folder) { draft.group = folder }
                                }
                            } label: {
                                Image(systemName: "folder")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Choose a Folder")
                        }
                    }
                }
                TextField("Tags", text: tagsText, prompt: Text("Comma separated"))
                Picker("Open with", selection: $draft.client) {
                    Text("Default (\(defaultClientName))").tag(String?.none)
                    ForEach(clients, id: \.self) { bundleID in
                        Text(verbatim: Launcher.appName(bundleID)).tag(Optional(bundleID))
                    }
                }
            }

            Section("Notes") {
                TextEditor(text: optional($draft.notes))
                    .frame(minHeight: 60)
                    .font(.body)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Connect") { model.connect(draft) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.kind == .web ? draft.webURL == nil : draft.host.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.name.isEmpty ? String(localized: "New Connection") : draft.name)
        // Save shortly after the last change, and when leaving the entry.
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            model.update(draft)
        }
        .onDisappear { model.update(draft) }
        .onAppear {
            if model.justAdded == draft.id {
                nameFocused = true
                model.justAdded = nil
            }
        }
        .onChange(of: draft.kind) {
            // The chosen app belongs to the previous kind.
            if let client = draft.client, !Launcher.clients(for: draft.kind).contains(client) { draft.client = nil }
        }
    }

    private var clients: [String] {
        var list = Launcher.clients(for: draft.kind)
        if let client = draft.client, !list.contains(client) { list.append(client) }
        return list
    }

    private var defaultClientName: String {
        if draft.kind == .ssh { return Launcher.appName(Preferences.sshTerminal) }
        if let bundleID = KnownClient.defaultClient(for: draft.kind) { return Launcher.appName(bundleID) }
        // Web: the default browser.
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return "–" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private var otherFolders: [String] {
        model.folders.filter { $0 != draft.folder && $0 != "~/.ssh/config" }
    }

    private var portText: Binding<String> {
        Binding {
            draft.port.map(String.init) ?? ""
        } set: { text in
            let digits = text.filter(\.isNumber)
            draft.port = Int(digits).flatMap { (1...65535).contains($0) ? $0 : nil }
        }
    }

    private var tagsText: Binding<String> {
        Binding {
            draft.tags.joined(separator: ", ")
        } set: { text in
            draft.tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    /// Edits an optional text; an empty field stores nil.
    private func optional(_ binding: Binding<String?>) -> Binding<String> {
        Binding {
            binding.wrappedValue ?? ""
        } set: { text in
            binding.wrappedValue = text.isEmpty ? nil : text
        }
    }
}

private struct ImportedDetail: View {
    let model: AppModel
    let connection: Connection

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") { Text(verbatim: connection.name) }
                LabeledContent("Type") { Text(verbatim: connection.kind.label) }
                LabeledContent("Host") { Text(verbatim: connection.host).textSelection(.enabled) }
                if let port = connection.port {
                    LabeledContent("Port") { Text(verbatim: String(port)) }
                }
                if let user = connection.user {
                    LabeledContent("User") { Text(verbatim: user) }
                }
                if let proxy = connection.proxy {
                    LabeledContent("Via") { Text(verbatim: proxy) }
                }
            } footer: {
                Text("Imported from ~/.ssh/config. Change it in that file; Roundhouse connects with “ssh \(connection.name)”, so all its settings apply.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                HStack {
                    Button("Duplicate as Editable Entry") { model.duplicate(connection) }
                    Spacer()
                    Button("Connect") { model.connect(connection) }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(connection.name)
    }
}
