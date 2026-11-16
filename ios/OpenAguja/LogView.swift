import SwiftUI
import UIKit
import OpenAgujaCore

/// Onglet Journal : recherche, filtre par catégorie, copie et partage.
struct LogView: View {
    @EnvironmentObject private var log: LogStore
    @State private var search = ""
    @State private var categories = Set(LogStore.Category.allCases)
    @State private var showFrames = true
    @State private var copied = false
    @State private var confirmClear = false
    @State private var share: ShareItem?

    private var visible: [LogStore.Entry] {
        log.entries.filter { entry in
            categories.contains(entry.category)
                && (showFrames || (entry.category != .tx && entry.category != .rx))
                && (search.isEmpty
                    || entry.text.localizedCaseInsensitiveContains(search)
                    || (entry.hex?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(LogStore.Category.allCases) { category in
                                let on = categories.contains(category)
                                Button {
                                    if on { categories.remove(category) } else { categories.insert(category) }
                                } label: {
                                    Label(category.label, systemImage: category.symbol)
                                        .font(.caption.weight(.medium))
                                }
                                .buttonStyle(.bordered)
                                .tint(on ? .accentColor : .secondary)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
                Section("Lab") {
                    NavigationLink {
                        MemoryDumpView()
                    } label: {
                        Label("Memory dump / init (lab)", systemImage: "memorychip")
                    }
                }
                Section {
                    if visible.isEmpty {
                        Text(log.entries.isEmpty ? "Empty log" : "No entries match the filter")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visible) { entry in
                        NavigationLink {
                            LogEntryView(entry: entry)
                        } label: {
                            LogRow(entry: entry)
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = entry.line
                            } label: {
                                Label("Copy line", systemImage: "doc.on.doc")
                            }
                            if let hex = entry.hex {
                                Button {
                                    UIPasteboard.general.string = hex
                                } label: {
                                    Label("Copy frame", systemImage: "number")
                                }
                            }
                        }
                    }
                } header: {
                    Text("\(visible.count) entr(y/ies)")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Text or hexadecimal bytes")
            .navigationTitle("Log")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Toggle("BLE frames", isOn: $showFrames)
                        Button {
                            UIPasteboard.general.string = LogStore.text(of: visible)
                            copied = true
                        } label: {
                            Label("Copy visible entries", systemImage: "doc.on.doc")
                        }
                        Button {
                            share = log.exportFile(visible).map(ShareItem.init)
                        } label: {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            confirmClear = true
                        } label: {
                            Label("Clear log", systemImage: "trash")
                        }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
            .alert("Copied to clipboard", isPresented: $copied) {
                Button("OK", role: .cancel) {}
            }
            .sheet(item: $share) { item in
                ShareSheet(items: [item.url])
            }
            .confirmationDialog("Clear log?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { log.clear() }
            }
        }
    }
}

struct LogRow: View {
    let entry: LogStore.Entry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.category.symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.subheadline)
                    .lineLimit(3)
                if let hex = entry.hex {
                    Text(hex)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch entry.category {
        case .error: return .red
        case .event: return .accentColor
        case .http: return .orange
        case .tx: return .blue
        case .rx: return .teal
        case .info: return .secondary
        }
    }
}

struct LogEntryView: View {
    let entry: LogStore.Entry

    var body: some View {
        List {
            Section {
                LabeledContent("Date", value: LogStore.Entry.formatter.string(from: entry.date))
                LabeledContent("Category", value: entry.category.label)
            }
            Section("Message") {
                Text(entry.text)
                    .textSelection(.enabled)
            }
            if let hex = entry.hex {
                Section("Frame") {
                    Text(hex)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
            Section {
                Button {
                    UIPasteboard.general.string = entry.line
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
        .navigationTitle("Entry")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Fichier à partager (identifiable pour `.sheet(item:)`).
struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Feuille de partage UIKit (exports générés à la demande).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
