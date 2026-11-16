import Foundation
import OSLog

/// Journal structuré de l'app (trames BLE, événements montre, appels HTTP,
/// erreurs) : consultable, filtrable, copiable et exportable. Persisté dans
/// Application Support pour survivre aux relances en arrière-plan.
final class LogStore: ObservableObject {
    enum Category: String, Codable, CaseIterable, Identifiable {
        case tx, rx, event, http, info, error

        var id: String { rawValue }

        var label: String {
            switch self {
            case .tx: return String(localized: "Sent")
            case .rx: return String(localized: "Received")
            case .event: return String(localized: "Watch")
            case .http: return String(localized: "HTTP")
            case .info: return String(localized: "Info")
            case .error: return String(localized: "Error")
            }
        }

        var symbol: String {
            switch self {
            case .tx: return "arrow.up.circle"
            case .rx: return "arrow.down.circle"
            case .event: return "applewatch"
            case .http: return "network"
            case .info: return "info.circle"
            case .error: return "exclamationmark.triangle"
            }
        }

        /// Les journaux persistés avec une catégorie inconnue (ancienne
        /// ou future version) décodent en `.info` plutôt que de perdre
        /// l'entrée.
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            self = Category(rawValue: raw) ?? .info
        }
    }

    struct Entry: Identifiable, Codable, Equatable {
        var id = UUID()
        var date = Date()
        let category: Category
        let text: String
        /// Trame brute en hexadécimal, quand l'entrée en porte une.
        var hex: String?

        /// Ligne texte pour la copie / l'export.
        var line: String {
            let time = Self.formatter.string(from: date)
            let base = "\(time) [\(category.rawValue)] \(text)"
            return hex.map { "\(base) | \($0)" } ?? base
        }

        static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            return f
        }()
    }

    /// Antichronologique (le plus récent en tête).
    @Published private(set) var entries: [Entry] = []

    static let maxEntries = 2000

    private let osLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "OpenAguja",
        category: "log"
    )
    private let fileURL: URL?
    private var saveScheduled = false

    init(fileURL: URL? = LogStore.defaultFileURL()) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data)
        {
            entries = saved
        }
    }

    static func defaultFileURL() -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("zetime-log.json")
    }

    func add(_ category: Category, _ text: String, hex: String? = nil) {
        let entry = Entry(category: category, text: text, hex: hex)
        osLog.log("[\(category.rawValue, privacy: .public)] \(text, privacy: .public) \(hex ?? "", privacy: .public)")
        if Thread.isMainThread {
            insert(entry)
        } else {
            DispatchQueue.main.async { self.insert(entry) }
        }
    }

    func clear() {
        entries.removeAll()
        scheduleSave()
    }

    /// Texte chronologique des entrées données (ordre d'affichage inversé).
    static func text(of entries: [Entry]) -> String {
        entries.reversed().map(\.line).joined(separator: "\n")
    }

    /// Fichier texte temporaire pour la feuille de partage.
    func exportFile(_ entries: [Entry]) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zetime-journal-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try Self.text(of: entries).write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private func insert(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        scheduleSave()
    }

    /// Écriture groupée (au plus une toutes les 2 s) : le journal BLE peut
    /// produire des dizaines d'entrées par seconde pendant une synchro.
    private func scheduleSave() {
        guard !saveScheduled, fileURL != nil else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let fileURL = self.fileURL else { return }
            self.saveScheduled = false
            if let data = try? JSONEncoder().encode(self.entries) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}
