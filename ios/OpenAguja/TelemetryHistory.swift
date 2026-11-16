import Foundation

/// Synthèses quotidiennes lues depuis `WebhookConfig.telemetryHistoryURL`
/// (`GET <url>?days=N` — `&days=N` si l'URL contient déjà une query) —
/// même configuration que `TelemetryUploader` (jeton optionnel,
/// jamais journalisé). Alimente `TelemetryHistoryView` (graphes Swift
/// Charts). URL vide = fonctionnalité désactivée.
@MainActor
final class TelemetryHistoryStore: ObservableObject {
    /// Une ligne de `daily_summaries` ; les champs absents arrivent en
    /// `null` côté JSON et décodent en `nil`.
    struct Day: Decodable, Identifiable {
        /// "YYYY-MM-DD" — jour local du serveur.
        let date: String
        let sleepMinutes: Int?
        let sleepHours: Double?
        /// Répartition par phase (minutes) — NULL pour les journées
        /// résumées avant l'ajout des colonnes côté serveur.
        let deepMinutes: Int?
        let lightMinutes: Int?
        let remMinutes: Int?
        let awakeMinutes: Int?
        /// "HH:MM" local — coucher / réveil déduits des trames de sommeil.
        let bedtime: String?
        let wake: String?
        let restingHr: Int?
        let avgHr: Int?
        let maxHr: Int?
        let totalSteps: Int?
        let batteryMin: Int?
        let eventsCount: Int?

        var id: String { date }

        /// Jour calendaire pour l'axe X des graphiques.
        var dayDate: Date? { Self.dayFormatter.date(from: date) }

        /// « 23:42 » → minutes depuis minuit (axe Y du graphique rythme).
        var bedtimeMinutes: Double? { Self.hhmm(bedtime) }
        var wakeMinutes: Double? { Self.hhmm(wake) }

        private static let dayFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f
        }()

        private static func hhmm(_ s: String?) -> Double? {
            guard let s else { return nil }
            let parts = s.split(separator: ":")
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
                  (0...23).contains(h), (0...59).contains(m)
            else { return nil }
            return Double(h * 60 + m)
        }
    }

    /// Fenêtre demandée au serveur (bornée 1..400 côté API).
    @Published var periodDays = 30
    /// Synthèses chronologiques (plus ancien → plus récent), comme le JSON.
    @Published private(set) var days: [Day] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var lastRefresh: Date?

    private let config: () -> WebhookConfig
    private let token: () -> String?

    init(config: @escaping () -> WebhookConfig, token: @escaping () -> String?) {
        self.config = config
        self.token = token
    }

    /// Charge les `periodDays` derniers jours ; une fenêtre vide ou une
    /// URL non configurée remontent une erreur lisible, jamais de crash.
    /// Le jeton Bearer est optionnel.
    func refresh() async {
        let cfg = config()
        let base = cfg.telemetryHistoryURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !base.isEmpty,
              var components = URLComponents(string: base)
        else {
            error = String(localized: "History URL not configured")
            days = []
            return
        }
        let separator = components.query == nil ? "?" : "&"
        components.query = (components.query.map { $0 + separator } ?? "")
            + "days=\(periodDays)"
        guard let url = components.url else {
            error = String(localized: "Invalid history URL")
            days = []
            return
        }
        loading = true
        error = nil
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ios", forHTTPHeaderField: "X-OpenAguja-Client")
        if let token = token(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in cfg.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                error = status == 401 ? "Token rejected (401)" : "HTTP \(status)"
                return
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            days = try decoder.decode([Day].self, from: data)
            lastRefresh = Date()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
