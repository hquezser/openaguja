import Foundation

#if canImport(UIKit)
    import UIKit // beginBackgroundTask (iOS uniquement)
#endif

/// Relais vers le endpoint webhook HTTP configuré (`WebhookConfig`) :
/// chaque action de la montre devient un `POST <actionURL>` avec un corps
/// JSON `{action, value?, text?, timestamp}`. Le récepteur répond 2xx en
/// cas de succès — il peut utiliser `message` dans sa réponse JSON pour
/// un détail affiché à l'utilisateur. Le jeton Bearer (optionnel) reste
/// dans le trousseau et n'est jamais journalisé.
final class WebhookBridge: ObservableObject {
    /// Configuration courante (persistée en `webhook.config`).
    @Published private(set) var config: WebhookConfig

    @Published private(set) var lastResult: String?
    /// Code HTTP du dernier POST d'action (0 = pas de réponse HTTP :
    /// réseau, timeout…). `nil` = jamais envoyé.
    @Published private(set) var lastHTTPStatus: Int?
    /// Code HTTP du dernier « Tester la connexion » (réglages).
    @Published private(set) var lastTestStatus: Int?

    /// Appelé sur le main thread après chaque résultat d'envoi
    /// (`true` = HTTP 2xx) — pilote le retour haptique « au poignet ».
    var onSendResult: ((Bool) -> Void)?

    private let log: LogStore

    init(log: LogStore) {
        self.log = log
        config = WebhookConfig.load()
    }

    /// Enregistre une nouvelle configuration et notifie les observateurs
    /// (nom affiché sur l'écran Musique de la montre, URLs de télémétrie).
    func save(_ config: WebhookConfig) {
        self.config = config
        config.save()
        NotificationCenter.default.post(name: .webhookConfigDidChange, object: nil)
    }

    /// Relit la configuration persistée — après l'application d'un
    /// profil importé.
    func reload() {
        config = WebhookConfig.load()
        NotificationCenter.default.post(name: .webhookConfigDidChange, object: nil)
    }

    /// Corps JSON commun aux POST : `action` toujours présent, `value`
    /// et `text` omis quand nil, `timestamp` en ISO-8601 avec fuseau.
    private struct ActionPayload: Encodable {
        let action: String
        let value: Int?
        let text: String?
        let timestamp: String
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// En-têtes communs : identification client, puis les en-têtes
    /// personnalisés de la config (qui peuvent tout remplacer).
    /// Le jeton n'est ajouté que s'il est renseigné.
    private func applyHeaders(to request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ios", forHTTPHeaderField: "X-OpenAguja-Client")
        if let token = Keychain.token(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    /// Action montre (id déjà résolu : play, next, volume_up…) → POST
    /// vers `config.actionURL`. Ne journalise jamais le jeton.
    /// `value` : niveau absolu de la molette.
    func send(actionId: String, value: Int? = nil, text: String? = nil) {
        let clean = config.actionURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !clean.isEmpty, let url = URL(string: clean) else {
            publish(String(localized: "Webhook HTTP not configured (settings)"))
            publishResult(success: false, status: nil)
            return
        }
        log.add(.http, "→ \(actionId)")
        let payload = ActionPayload(
            action: actionId,
            value: value,
            text: text,
            timestamp: Self.timestampFormatter.string(from: Date())
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        applyHeaders(to: &request)
        request.httpBody = try? JSONEncoder().encode(payload)

        // La tâche de fond laisse à la requête le temps de finir quand la
        // relance vient d'un événement BLE en arrière-plan.
        #if canImport(UIKit)
            let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "webhook-event")
        #endif
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            #if canImport(UIKit)
                defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
            #endif
            self?.handle(data: data, response: response, error: error)
        }.resume()
    }

    /// Vérifie l'URL d'action par un POST `{"action":"test"}` — les
    /// récepteurs devraient idéalement répondre 2xx à `test`, mais tout
    /// code HTTP prouve déjà que le serveur est joignable et que le
    /// jeton n'est pas refusé (sauf 401/403).
    func testConnection() async -> String {
        let clean = config.actionURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !clean.isEmpty, let url = URL(string: clean) else {
            await MainActor.run { self.lastTestStatus = nil }
            return String(localized: "Webhook not configured")
        }
        let payload = ActionPayload(
            action: "test",
            value: nil,
            text: nil,
            timestamp: Self.timestampFormatter.string(from: Date())
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try? JSONEncoder().encode(payload)
        applyHeaders(to: &request)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            await MainActor.run { self.lastTestStatus = status }
            if status == 401 || status == 403 {
                return String(localized: "Token rejected (HTTP \(status))")
            }
            return String(localized: "Server reachable, token accepted (HTTP \(status))")
        } catch {
            await MainActor.run { self.lastTestStatus = 0 }
            let nsError = error as NSError
            return "\(String(localized: "Unreachable: \(error.localizedDescription)")) [\(nsError.domain) \(nsError.code)]"
        }
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?) {
        if let error {
            publish(String(localized: "Network error: \(error.localizedDescription)"))
            publishResult(success: false, status: 0)
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let message = body?["message"] as? String
        publishResult(success: (200...299).contains(status), status: status)
        if (200...299).contains(status) {
            publish(message ?? "OK")
        } else if status == 401 {
            publish(String(localized: "Token rejected"))
        } else {
            publish("HTTP \(status)" + (message.map { " : \($0)" } ?? ""))
        }
    }

    /// Statut HTTP + notification du résultat (retour haptique), sur le
    /// main thread comme `publish`.
    private func publishResult(success: Bool, status: Int?) {
        if Thread.isMainThread {
            applyResult(success: success, status: status)
        } else {
            DispatchQueue.main.async { self.applyResult(success: success, status: status) }
        }
    }

    private func applyResult(success: Bool, status: Int?) {
        lastHTTPStatus = status
        onSendResult?(success)
    }

    private func publish(_ text: String) {
        log.add(.http, text)
        if Thread.isMainThread {
            lastResult = text
        } else {
            DispatchQueue.main.async { self.lastResult = text }
        }
    }
}

extension Notification.Name {
    /// Publié quand la configuration webhook change (réglages, import
    /// de profil) — la montre réaffiche le nom de la source par défaut.
    static let webhookConfigDidChange = Notification.Name("webhook.config.didChange")
}
