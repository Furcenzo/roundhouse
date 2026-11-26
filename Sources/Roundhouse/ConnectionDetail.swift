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
    @State private var choosingItem = false
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

            PasswordSection(model: model, draft: $draft, choosingItem: $choosingItem)

            Section("Notes") {
                TextEditor(text: optional($draft.notes))
                    .frame(minHeight: 60)
                    .font(.body)
            }

            Section {
                HStack {
                    Spacer()
                    if draft.hasVaultItem {
                        Button("Copy Password") { Task { await model.vault.copyPassword(of: draft) } }
                    }
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
        .sheet(isPresented: $choosingItem) {
            VaultItemPicker(vault: model.vault, host: draft.reachabilityHost) { item in
                draft.vaultItemID = item.id
                draft.vaultItemName = item.name
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

/// The Bitwarden item of the entry and, for WinBox, "Connect at once".
private struct PasswordSection: View {
    let model: AppModel
    @Binding var draft: Connection
    @Binding var choosingItem: Bool

    var body: some View {
        Section {
            LabeledContent("Bitwarden item") {
                HStack {
                    if draft.vaultItemID != nil {
                        Text(verbatim: draft.vaultItemName ?? draft.vaultItemID ?? "")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Change…") { choosingItem = true }
                        Button("Remove") {
                            draft.vaultItemID = nil
                            draft.vaultItemName = nil
                            draft.loginAtOnce = nil
                        }
                    } else {
                        Button("Choose…") { choosingItem = true }
                    }
                }
            }
            if draft.kind == .winbox, draft.vaultItemID != nil {
                Toggle("Connect at once (password from Bitwarden)", isOn: Binding {
                    draft.loginAtOnce == true
                } set: {
                    draft.loginAtOnce = $0 ? true : nil
                })
                Label(
                    "WinBox gets the password as a command-line argument: other processes on this Mac can see it in the process list while WinBox runs.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(draft.loginAtOnce == true ? .orange : .secondary)
            }
        } header: {
            Text("Password")
        } footer: {
            Group {
                if draft.vaultItemID == nil {
                    Text("Roundhouse stores only a reference to the Bitwarden item, never the password.")
                } else if draft.logsInAtOnce {
                    Text("On connect, WinBox gets the user and the password and logs in at once.")
                } else {
                    Text("On connect, the password is copied to the clipboard and cleared after 30 seconds.")
                }
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Picks a login item of the vault. Shows names, users and addresses only – passwords are never read here.
private struct VaultItemPicker: View {
    let vault: Vault
    /// Items whose address contains the entry's host come first.
    let host: String
    let choose: (VaultItemSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [VaultItemSummary]?
    @State private var problem: String?
    /// The last sync failed (offline): the list comes from the copy saved on this Mac.
    @State private var syncProblem: String?
    @State private var syncing = false
    @State private var query = ""
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Choose a Bitwarden Item")
                    .font(.headline)
                Spacer()
                if syncing {
                    ProgressView().controlSize(.small)
                } else if let date = vault.lastSync {
                    Text("Synced \(date, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Sync") { Task { await reload(force: true) } }
                    .disabled(syncing || problem != nil)
            }
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
            Group {
                if let problem {
                    ContentUnavailableView {
                        Label("The vault is not available", systemImage: "lock")
                    } description: {
                        Text(verbatim: problem)
                    }
                } else if let items {
                    if let syncProblem {
                        Label("Could not sync: \(syncProblem) Showing the items saved on this Mac.",
                              systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    List(filtered(items), selection: $selection) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: item.name)
                            let detail = [item.username, item.uri].compactMap { $0 }.joined(separator: " · ")
                            if !detail.isEmpty {
                                Text(verbatim: detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(item.id)
                    }
                    .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { _ in finish() }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding()
        .frame(width: 480, height: 420)
        .task { await load() }
    }

    private func filtered(_ items: [VaultItemSummary]) -> [VaultItemSummary] {
        let words = query.lowercased().split(separator: " ")
        let matching = items.filter { item in
            let text = [item.name, item.username ?? "", item.uri ?? ""].joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        let host = host.lowercased()
        guard !host.isEmpty else { return matching }
        return matching.filter { $0.uri?.lowercased().contains(host) == true }
            + matching.filter { $0.uri?.lowercased().contains(host) != true }
    }

    private func load() async {
        guard await vault.ensureUnlocked(for: nil) else {
            dismiss()
            return
        }
        await reload(force: false)
        selection = items.flatMap { filtered($0).first { !host.isEmpty && $0.uri?.lowercased().contains(host.lowercased()) == true }?.id }
    }

    /// Syncs first (when the last sync is over a minute old, or `force`), then lists the items.
    private func reload(force: Bool) async {
        syncing = true
        syncProblem = await vault.sync(force: force)
        syncing = false
        do {
            items = try await vault.loginItems()
            problem = nil
        } catch {
            problem = Vault.message(for: error)
        }
    }

    private func finish() {
        guard let id = selection, let item = items?.first(where: { $0.id == id }) else { return }
        choose(item)
        dismiss()
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
                    .multilineTextAlignment(.leading)
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
