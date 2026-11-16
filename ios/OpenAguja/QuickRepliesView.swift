import SwiftUI
import OpenAgujaCore

/// Réponses rapides stockées sur la montre (0xDA/0xDB, flash 0xA2000,
/// 10 max, texte UTF-16LE ≤ 90 caractères). Le CRC est l'identité stable :
/// les index bougent à chaque insertion/suppression — la réorganisation
/// se fait donc par suppression + réinsertion.
struct QuickRepliesView: View {
    @EnvironmentObject private var bluetooth: ZeTimeBluetoothManager
    @State private var replies: [QuickReply] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showAdd = false
    @State private var editing: QuickReply?

    var body: some View {
        List {
            Section {
                NotConnectedHint()
                if let error {
                    StatusFooter(error: error)
                }
                if replies.isEmpty, !loading {
                    Text("No quick replies on the watch")
                        .foregroundStyle(.secondary)
                }
                ForEach(replies, id: \.crc) { reply in
                    Button {
                        editing = reply
                    } label: {
                        HStack {
                            Text("\(reply.index). \(reply.text)")
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(String(format: "%04X", reply.crc))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) {
                            Task {
                                await run("Suppression") {
                                    try await bluetooth.perform(.deleteQuickReply(crc: reply.crc), label: String(localized: "Delete reply"))
                                }
                                await reload()
                            }
                        }
                    }
                }
            } footer: {
                Text("Up to 10 replies, UTF-16 text (90 chars max). Each edit rewrites the watch flash area: do not interrupt the watch during the operation.")
            }
        }
        .navigationTitle("Quick replies")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if loading {
                    ProgressView()
                } else {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(!bluetooth.isReady || replies.count >= 10)
                }
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
        .sheet(isPresented: $showAdd) {
            ReplyEditView(title: String(localized: "New reply"), initial: "") { text in
                Task {
                    await run("Add reply") {
                        try await bluetooth.perform(
                            .insertQuickReply(index: UInt8(min(replies.count + 1, 10)), text: text),
                            label: String(localized: "Add reply")
                        )
                    }
                    await reload()
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { editing != nil },
            set: { if !$0 { editing = nil } }
        )) {
            if let reply = editing {
                ReplyEditView(title: String(localized: "Edit reply"), initial: reply.text) { text in
                    Task {
                        await run("Edit reply") {
                            try await bluetooth.perform(.updateQuickReply(crc: reply.crc, text: text), label: String(localized: "Edit reply"))
                        }
                        await reload()
                    }
                }
            }
        }
    }

    @MainActor
    private func reload() async {
        guard bluetooth.isReady else { return }
        loading = true
        defer { loading = false }
        do {
            replies = try await bluetooth.readQuickReplies()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func run(_ label: String, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            error = nil
        } catch {
            self.error = "\(label) : \(error.localizedDescription)"
        }
    }
}

private struct ReplyEditView: View {
    let title: String
    let initial: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(title: String, initial: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.initial = initial
        self.onSave = onSave
        _text = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Reply text", text: $text, axis: .vertical)
                    .lineLimit(3...6)
                Text("\(text.utf16.count)/90 UTF-16 characters")
                    .font(.caption)
                    .foregroundStyle(text.utf16.count > 90 ? Color.red : Color.secondary)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(String(text.prefix(90)))
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf16.count > 90)
                }
            }
        }
    }
}
