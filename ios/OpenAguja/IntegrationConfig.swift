import Foundation

/// Configuration du endpoint webhook HTTP : toutes les actions de la
/// montre routées « Webhook » arrivent en `POST <actionURL>` avec un
/// corps JSON `{action, value?, text?, timestamp}` ; la télémétrie brute
/// part sur `telemetryUploadURL` et l'historique se lit sur
/// `telemetryHistoryURL`. Persistée en JSON dans UserDefaults — les
/// secrets (jetons) restent dans le trousseau, jamais ici.
struct WebhookConfig: Codable, Equatable {
    /// Nom affiché dans l'UI et utilisé comme titre de l'écran Musique
    /// de la montre pour la source par défaut (source 0).
    var name: String = "Webhook"
    /// URL complète recevant un POST par action de la montre.
    var actionURL: String = ""
    /// En-têtes HTTP additionnels (ex. `X-Mon-Client: watch`) — peuvent
    /// remplacer les en-têtes par défaut.
    var headers: [String: String] = [:]
    /// URL de dépôt de la télémétrie (JSONL) ; vide = envoi désactivé.
    var telemetryUploadURL: String = ""
    /// URL GET des synthèses quotidiennes (`?days=N` ajouté à l'appel,
    /// `&` si l'URL contient déjà une query) ; vide = historique masqué.
    var telemetryHistoryURL: String = ""

    static let defaultsKey = "webhook.config"

    init() {}

    init(name: String, actionURL: String, headers: [String: String] = [:],
         telemetryUploadURL: String = "", telemetryHistoryURL: String = "") {
        self.name = name
        self.actionURL = actionURL
        self.headers = headers
        self.telemetryUploadURL = telemetryUploadURL
        self.telemetryHistoryURL = telemetryHistoryURL
    }

    /// Champs absents d'un JSON importé gardent leur valeur par défaut.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Webhook"
        actionURL = try c.decodeIfPresent(String.self, forKey: .actionURL) ?? ""
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        telemetryUploadURL = try c.decodeIfPresent(String.self, forKey: .telemetryUploadURL) ?? ""
        telemetryHistoryURL = try c.decodeIfPresent(String.self, forKey: .telemetryHistoryURL) ?? ""
    }

    static func load(from defaults: UserDefaults = .standard) -> WebhookConfig {
        guard let data = defaults.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(WebhookConfig.self, from: data)
        else { return WebhookConfig() }
        return config
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
