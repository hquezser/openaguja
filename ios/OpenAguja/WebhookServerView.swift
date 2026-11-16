import SwiftUI
import OpenAgujaCore

/// Feuille « Serveur Webhook » : connexion (nom, URL, jeton masqué,
/// en-têtes, URLs de télémétrie, test) + file hors-ligne de
/// télémétrie (compteur, dernier envoi, flush, vidage).
/// Les actions webhook ne sont PAS mises en file — seul l'upload de
/// télémétrie l'est (voir le footer).
struct WebhookServerView: View {
    @EnvironmentObject private var bridge: WebhookBridge
    @EnvironmentObject private var telemetry: TelemetryUploader
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var actionURL = ""
    @State private var uploadURL = ""
    @State private var historyURL = ""
    @State private var token = ""
    @State private var currentToken = ""
    @State private var reveal = false
    @State private var headers: [HeaderRow] = []
    @State private var testing = false
    @State private var testResult: String?
    @State private var confirmClear = false
    @State private var saved = false

    struct HeaderRow: Identifiable {
        var id = UUID()
        var key = ""
        var value = ""
    }

    var body: some View {
        Form {
            connectionSection
            queueSection
            footerSection
        }
        .navigationTitle("Webhook server")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.fontWeight(.semibold)
            }
        }
        .onAppear(perform: load)
        .confirmationDialog("Clear the offline queue?",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear queue", role: .destructive) {
                telemetry.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(telemetry.queuedCount) unsent telemetry event(s) will be permanently deleted.")
        }
    }

    // MARK: - Connexion

    private var connectionSection: some View {
        Section("Connection") {
            TextField("Name", text: $name)
            TextField("Action URL", text: $actionURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            tokenRow
            headersEditor
            TextField("Telemetry upload URL", text: $uploadURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Telemetry history URL", text: $historyURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            testRow
        }
    }

    private var tokenRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SecureField("New token (empty = unchanged)", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Text(currentToken.isEmpty ? "No token" : (reveal ? currentToken : Self.mask(currentToken)))
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(reveal ? "Hide" : "Reveal") { reveal.toggle() }
                    .font(.footnote)
                Button("Copy") {
                    UIPasteboard.general.string = currentToken
                }
                .font(.footnote)
                .disabled(currentToken.isEmpty)
            }
        }
    }

    private var headersEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($headers) { $row in
                HStack {
                    TextField("Header", text: $row.key)
                        .font(.footnote.monospaced())
                    TextField("Value", text: $row.value)
                        .font(.footnote.monospaced())
                }
            }
            Button {
                headers.append(HeaderRow())
            } label: {
                Label("Add header", systemImage: "plus")
                    .font(.footnote)
            }
        }
    }

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                Task { await runTest() }
            } label: {
                HStack {
                    if testing { ProgressView().controlSize(.small) }
                    Text("Test webhook")
                    Spacer()
                }
            }
            .disabled(testing || actionURL.trimmingCharacters(in: .whitespaces).isEmpty)
            if let testResult {
                Text(testResult)
                    .font(.footnote)
                    .foregroundStyle(testColor())
            }
            if let result = bridge.lastResult {
                Text(result).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// Couleur dérivée du statut HTTP (`lastTestStatus`), jamais du
    /// texte localisé : 401/403 = jeton refusé, 0 = injoignable.
    private func testColor() -> Color {
        guard let status = bridge.lastTestStatus else { return ZTColor.warning }
        if status == 401 || status == 403 { return ZTColor.danger }
        if status == 0 { return ZTColor.warning }
        return ZTColor.success
    }

    private func runTest() async {
        // Sauvegarde d'abord pour tester la config courante.
        save()
        testing = true
        testResult = await bridge.testConnection()
        testing = false
    }

    // MARK: - File hors-ligne (télémétrie)

    private var queueSection: some View {
        Section {
            HStack {
                Text("Pending")
                Spacer()
                ZTPill(tone: telemetry.queuedCount > 0 ? .warn : .ok,
                      text: "\(telemetry.queuedCount)")
            }
            LabeledContent("Last successful send") {
                Text(telemetry.lastSuccessAt?.relative ?? "—")
            }
            LabeledContent("Last HTTP status") {
                Text(telemetry.lastHTTPStatus.map { "HTTP \($0)" } ?? "—")
            }
            Button {
                telemetry.flush()
            } label: {
                Label("Send now", systemImage: "paperplane.fill")
            }
            .disabled(telemetry.queuedCount == 0)
            Button("Clear queue", role: .destructive) {
                confirmClear = true
            }
            .disabled(telemetry.queuedCount == 0)
        } header: {
            Text("Offline queue")
        } footer: {
            Text("Only telemetry uploads are queued while offline. Webhook actions are sent immediately and are not queued.")
        }
    }

    private var footerSection: some View {
        Section {
            EmptyView()
        }
    }

    // MARK: - Chargement / sauvegarde

    private func load() {
        let c = bridge.config
        name = c.name
        actionURL = c.actionURL
        uploadURL = c.telemetryUploadURL
        historyURL = c.telemetryHistoryURL
        headers = c.headers.map { HeaderRow(key: $0.key, value: $0.value) }
        reloadToken()
    }

    private func save() {
        var c = WebhookConfig()
        c.name = name.trimmingCharacters(in: .whitespaces)
        c.actionURL = actionURL.trimmingCharacters(in: .whitespaces)
        c.telemetryUploadURL = uploadURL.trimmingCharacters(in: .whitespaces)
        c.telemetryHistoryURL = historyURL.trimmingCharacters(in: .whitespaces)
        var h: [String: String] = [:]
        for row in headers where !row.key.trimmingCharacters(in: .whitespaces).isEmpty {
            h[row.key.trimmingCharacters(in: .whitespaces)] = row.value
        }
        c.headers = h
        bridge.save(c)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            Keychain.setToken(trimmedToken)
        }
        token = ""
        reloadToken()
        saved = true
    }

    private func reloadToken() {
        currentToken = Keychain.token() ?? ""
    }

    private static func mask(_ token: String) -> String {
        guard token.count > 12 else { return String(repeating: "•", count: max(token.count, 4)) }
        return "\(token.prefix(7))…\(token.suffix(4))"
    }
}
