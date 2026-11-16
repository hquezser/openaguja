import Foundation

#if canImport(UIKit)
    import UIKit // beginBackgroundTask (iOS uniquement)
#endif

/// Relais direct vers un micro-daemon HTTP local (même Wi-Fi, ex.
/// `openaguja-macd` sur un Mac) : `POST {baseURL}/cmd/<action>` avec
/// Bearer. Latence locale, pas de dépendance à Internet ni à un serveur
/// tiers — fonctionne iPhone verrouillé tant que les deux appareils sont
/// sur le même réseau.
final class MacDaemonBridge: ObservableObject {
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Self.baseURLKey) }
    }

    @Published private(set) var lastResult: String?
    /// Code HTTP du dernier POST /cmd/* (0 = pas de réponse HTTP).
    @Published private(set) var lastHTTPStatus: Int?
    /// Code HTTP du dernier test de connexion (GET /cmd).
    @Published private(set) var lastTestStatus: Int?

    /// Appelé sur le main thread après chaque résultat d'envoi — pilote
    /// le retour haptique « au poignet » comme pour le webhook.
    var onSendResult: ((Bool) -> Void)?

    /// Clé UserDefaults — interne pour `Profile.swift` (export/apply).
    static let baseURLKey = "macd.baseURL"
    /// URL par défaut : vide — l'utilisateur renseigne la sienne dans
    /// les réglages (ou via un profil importé).
    static let defaultBaseURL = ""
    /// Exemple affiché en placeholder dans les réglages.
    static let urlPlaceholder = "http://my-mac.local:9876"
    /// Version affichable pour les textes d'aide.
    static var defaultURLDisplay: String { urlPlaceholder }

    private let log: LogStore

    init(log: LogStore) {
        self.log = log
        baseURL = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL
    }

    /// Relit l'URL persistée — après l'application d'un profil importé.
    func reload() {
        baseURL = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL
    }

    /// Enregistre l'URL (épurée, sans « / » final) et le jeton — un jeton
    /// vide conserve l'existant. Jamais journalisé.
    func save(baseURL: String, token: String) {
        self.baseURL = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        if !token.isEmpty {
            Keychain.setMacdToken(token)
        }
    }

    /// Anti-rebond par rafale : la montre émet les 0xD2 find-phone une
    /// fois toutes les ~2 s (mesuré live 2026-11-15, jitter jusqu'à
    /// ~2.6 s) tant que son écran reste ouvert. Une rafale = événements
    /// espacés de moins de `burstGap` ; tant qu'elle dure on n'envoie
    /// qu'une fois, et une nouvelle activation ne repart qu'après
    /// `burstGap` de silence. `minInterval` borne le débit quoi qu'il
    /// arrive (les toggles type dictée/coupure micro casseraient si la
    /// commande repartait en cours d'écran).
    private static let burstGap: TimeInterval = 4
    private static let minInterval: TimeInterval = 2
    private var lastEventAt: [String: Date] = [:]
    private var lastSentAt: [String: Date] = [:]

    /// Action montre (id : play, find_phone, sos…) → POST
    /// `{baseURL}/cmd/<id>` ; `value` = niveau absolu de la molette.
    func send(actionId: String, value: Int? = nil, text: String? = nil) {
        send(command: actionId, value: value, text: text)
    }

    /// Commande libre → POST `{baseURL}/cmd/<command>`. Utilisé par le
    /// routage quand un mode traduit une action en commande propre.
    func send(command: String, value: Int? = nil, text: String? = nil) {
        // Anti-rebond : même commande à valeur identique dans la même
        // rafale est ignorée ; une rafale = événements à < burstGap
        // d'intervalle (l'écran montre émet ~1/s tant qu'il est ouvert).
        let key = "\(command)|\(value.map(String.init) ?? "-")|\(text ?? "-")"
        let now = Date()
        let continuingBurst = lastEventAt[key].map { now.timeIntervalSince($0) < Self.burstGap } ?? false
        lastEventAt[key] = now
        if continuingBurst { return }
        if let last = lastSentAt[key], now.timeIntervalSince(last) < Self.minInterval { return }
        lastSentAt[key] = now
        let clean = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !clean.isEmpty, let url = URL(string: "\(clean)/cmd/\(command)") else {
            publish(String(localized: "Mac daemon not configured (settings)"))
            publishResult(success: false, status: nil)
            return
        }
        guard let token = Keychain.macdToken(), !token.isEmpty else {
            publish(String(localized: "Daemon token missing (settings)"))
            publishResult(success: false, status: nil)
            return
        }
        log.add(.http, "→ macd \(command)")
        var payload: [String: Any] = ["action": command]
        if let value { payload["value"] = value }
        if let text { payload["text"] = text }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("ios", forHTTPHeaderField: "X-OpenAguja-Client")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        // La tâche de fond laisse à la requête le temps de finir quand la
        // relance vient d'un événement BLE en arrière-plan.
        #if canImport(UIKit)
            let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "macd-cmd")
        #endif
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            #if canImport(UIKit)
                defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
            #endif
            self?.handle(data: data, response: response, error: error, actionId: command)
        }.resume()
    }

    /// Vérifie l'URL + le jeton contre `GET /cmd` (liste des commandes
    /// configurées côté daemon — endpoint authentifié).
    func testConnection() async -> String {
        let clean = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !clean.isEmpty, let url = URL(string: "\(clean)/cmd") else {
            await MainActor.run { self.lastTestStatus = nil }
            return String(localized: "Daemon not configured")
        }
        guard let token = Keychain.macdToken(), !token.isEmpty else {
            await MainActor.run { self.lastTestStatus = nil }
            return String(localized: "Missing token")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            await MainActor.run { self.lastTestStatus = status }
            if status == 401 {
                return String(localized: "Token rejected (401)")
            }
            if (200...299).contains(status) {
                let base = String(localized: "Connection OK")
                if let commands = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["commands"] as? [String] {
                    return "\(base) (\(commands.count))"
                }
                return base
            }
            return String(localized: "HTTP \(status)")
        } catch {
            await MainActor.run { self.lastTestStatus = 0 }
            return error.localizedDescription
        }
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?, actionId: String) {
        if let error {
            publish(String(localized: "Network error: \(error.localizedDescription)"))
            publishResult(success: false, status: 0)
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        // Le daemon répond 200 même si la commande shell échoue
        // (`{"ok":false,"exit":1}`) : le champ `ok` pilote le succès.
        let commandOK = body?["ok"] as? Bool ?? true
        publishResult(success: (200...299).contains(status) && commandOK, status: status)
        if (200...299).contains(status) {
            let detail = body?["stderr"] as? String
            publish(detail?.isEmpty == false ? detail! : (commandOK ? "OK" : "Command failed (exit \(body?["exit"] ?? "?"))"))
        } else if status == 401 {
            publish(String(localized: "Token rejected"))
        } else if status == 404 {
            publish(String(localized: "Command “\(actionId)” unknown to daemon"))
        } else {
            publish(String(localized: "HTTP \(status)"))
        }
    }

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
        log.add(.http, "macd : \(text)")
        if Thread.isMainThread {
            lastResult = text
        } else {
            DispatchQueue.main.async { self.lastResult = text }
        }
    }
}
