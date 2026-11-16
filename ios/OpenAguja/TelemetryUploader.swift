import Foundation
import Network

#if canImport(UIKit)
    import UIKit // beginBackgroundTask (iOS uniquement)
#endif

/// File d'attente + expédition des événements `TelemetryEvent` JSON vers
/// `WebhookConfig.telemetryUploadURL` (Bearer optionnel + en-têtes
/// personnalisés — le jeton n'est jamais journalisé). URL vide = envoi
/// désactivé, les événements restent en file.
///
/// - Persistance JSONL dans Application Support : les événements capturés
///   pendant un réveil BLE en arrière-plan survivent à la suspension.
/// - Flush déclenché par : enqueue (debounce 1,5 s), retour réseau
///   (`NWPathMonitor`), appel explicite (reconnexion BLE, retour au premier
///   plan) et à la fin de chaque drain si du reste est en file.
/// - POST séquentiel, un document par requête. HTTP 2xx = livré ; les
///   rejets définitifs (400/404/410/422) abandonnent l'événement et
///   continuent ; erreurs réseau, timeouts, 401/403/408/429 et 5xx
///   interrompent le flush en gardant le reste de la file (livraison
///   « au moins une fois » : un crash entre envoi et persistance peut
///   renvoyer un doublon).
@MainActor
final class TelemetryUploader: ObservableObject {
    /// JSONL persisté : un document `TelemetryEvent` complet par ligne.
    private static let queueFileName = "zetime-telemetry-queue.jsonl"
    /// Au-delà, les plus vieux événements sont abandonnés — flux temps réel :
    /// la donnée récente compte plus que l'historique.
    private static let maxQueued = 5000
    private static let flushDebounce: TimeInterval = 1.5

    /// Événements en attente d'envoi.
    @Published private(set) var queuedCount = 0
    /// Dernier résultat de flush, affiché dans les réglages.
    @Published private(set) var lastFlush: String?
    /// Dernier code HTTP reçu lors d'un envoi de télémétrie (nil si réseau).
    @Published private(set) var lastHTTPStatus: Int?
    /// Date du dernier envoi accepté (réponse 2xx).
    @Published private(set) var lastSuccessAt: Date?

    private let log: LogStore
    private let config: () -> WebhookConfig
    private let token: () -> String?

    private var queue: [String] = []
    private var flushing = false
    private var flushWork: DispatchWorkItem?
    private var persistWork: DispatchWorkItem?
    private let persistQueue = DispatchQueue(label: "telemetry.persist")
    private var pathMonitor: NWPathMonitor?

    init(log: LogStore, config: @escaping () -> WebhookConfig, token: @escaping () -> String?) {
        self.log = log
        self.config = config
        self.token = token
        load()
        queuedCount = queue.count
        startPathMonitor()
    }

    /// Ajoute un document JSON d'événement à la file (validé : objet JSON
    /// complet, rien d'autre n'est accepté).
    func enqueue(_ json: String) {
        let doc = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard doc.hasPrefix("{"), doc.hasSuffix("}") else { return }
        queue.append(doc)
        if queue.count > Self.maxQueued {
            queue.removeFirst(queue.count - Self.maxQueued)
        }
        queuedCount = queue.count
        schedulePersist()
        scheduleFlush(after: Self.flushDebounce)
    }

    /// Tente d'expédier la file (no-op si déjà en cours, file vide ou
    /// URL d'upload non configurée — les événements restent en attente).
    /// Le jeton Bearer est optionnel.
    func flush() {
        guard !flushing, !queue.isEmpty else { return }
        let cfg = config()
        let urlString = cfg.telemetryUploadURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return }
        flushing = true
        lastFlush = "Sending \(queue.count) event(s)…"
        Task { await drain(url: url, config: cfg, token: token()) }
    }

    /// Vide la file (réglages) — les événements déjà capturés sont perdus.
    func clear() {
        queue.removeAll()
        queuedCount = 0
        persist()
        lastFlush = "Queue cleared"
    }

    /// Écriture immédiate de la file sur disque (retour en arrière-plan).
    func persist() {
        persistWork?.cancel()
        persistWork = nil
        writeQueue()
    }

    // MARK: - File persistée (JSONL)

    private var queueFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.queueFileName)
    }

    private func load() {
        guard let data = try? Data(contentsOf: queueFileURL),
              let text = String(data: data, encoding: .utf8)
        else { return }
        queue = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    /// Snapshot de la file → écriture atomique sur une file série (les
    /// appels rapides sont ordonnés, le dernier écrit gagne).
    private func writeQueue() {
        let body = queue.joined(separator: "\n")
        let data = Data((body.isEmpty ? "" : body + "\n").utf8)
        let url = queueFileURL
        persistQueue.async { try? data.write(to: url, options: .atomic) }
    }

    private func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeQueue() }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: - Flush

    private func scheduleFlush(after delay: TimeInterval) {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private enum PostResult {
        case sent
        /// Rejet définitif du document (payload invalide pour le serveur).
        case drop
        /// Erreur transitoire : on arrête le drain, le reste reste en file.
        case retry
    }

    private func drain(url: URL, config: WebhookConfig, token: String?) async {
        #if canImport(UIKit)
            // Laisse finir les POST en cours quand le flush part d'un
            // événement BLE en arrière-plan.
            let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "telemetry-upload")
        #endif
        defer {
            #if canImport(UIKit)
                UIApplication.shared.endBackgroundTask(backgroundTask)
            #endif
            flushing = false
            persist()
            if !queue.isEmpty {
                lastFlush = "\(queue.count) pending (network?)"
                scheduleFlush(after: 30)
            }
        }
        var sent = 0
        var sincePersist = 0
        drainLoop: while let doc = queue.first {
            switch await post(doc, url: url, config: config, token: token) {
            case .sent:
                queue.removeFirst()
                sent += 1
                lastSuccessAt = Date()
            case .drop:
                queue.removeFirst()
                sent += 1
                log.add(.http, "Telemetry: event rejected by server — dropped")
            case .retry:
                break drainLoop
            }
            queuedCount = queue.count
            // Persistance par paquets de 50 : borne la fenêtre de doublons
            // en cas de crash sans réécrire le fichier à chaque POST.
            sincePersist += 1
            if sincePersist >= 50 {
                sincePersist = 0
                writeQueue()
            }
        }
        queuedCount = queue.count
        if queue.isEmpty {
            lastFlush = "\(sent) processed"
        }
    }

    private func post(_ doc: String, url: URL, config: WebhookConfig, token: String?) async -> PostResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ios", forHTTPHeaderField: "X-OpenAguja-Client")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in config.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = Data(doc.utf8)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastHTTPStatus = status
            switch status {
            case 200...299: return .sent
            case 400, 404, 410, 422: return .drop
            default: return .retry
            }
        } catch {
            return .retry
        }
    }

    // MARK: - Réseau

    /// Retour du réseau → flush immédiat de la file.
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.flush() }
        }
        monitor.start(queue: DispatchQueue(label: "telemetry.monitor"))
        pathMonitor = monitor
    }
}
