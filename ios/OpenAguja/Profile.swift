import Foundation

/// Erreurs d'import/export de profil : chaque message nomme ce qui
/// n'a pas pu être appliqué — jamais de perte silencieuse.
enum ProfileError: LocalizedError, Equatable {
    /// `version` du JSON différente de 1.
    case unsupportedVersion(Int)
    /// Valeur de cible (`ActionRouter.Target`) inconnue dans un
    /// `targets` — la liste nomme les chaînes refusées.
    case unknownTargets([String])
    /// Identifiant d'action inconnu dans un `targets`.
    case unknownActions([String])
    /// `hapticPattern` qui n'est pas un `HapticPattern` connu.
    case invalidHapticPattern(String)
    /// Deux modes partagent le même `id`.
    case duplicateModeIDs([String])

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return String(localized: "Unsupported profile version: \(version) (expected: 1)")
        case .unknownTargets(let names):
            return String(localized: "Unknown target(s): \(names.joined(separator: ", "))")
        case .unknownActions(let names):
            return String(localized: "Unknown action(s): \(names.joined(separator: ", "))")
        case .invalidHapticPattern(let pattern):
            return String(localized: "Unknown vibration pattern: “\(pattern)”")
        case .duplicateModeIDs(let ids):
            return String(localized: "Duplicate mode id(s): \(ids.joined(separator: ", "))")
        }
    }
}

/// Profil d'installation exportable/importable (JSON) : configuration
/// webhook, URL du daemon Mac, réglages de routage et modes contextuels.
/// L'export ne contient JAMAIS de jeton — les secrets restent dans le
/// trousseau. À l'import, seules les sections présentes sont remplacées ;
/// toute valeur inconnue fait échouer le profil en la nommant.
struct AppProfile: Codable, Equatable {
    var version: Int = 1
    var webhook: WebhookConfig?
    var macDaemonURL: String?
    var routing: Routing?
    var modes: [RouteMode]?

    init(version: Int = 1, webhook: WebhookConfig? = nil, macDaemonURL: String? = nil,
         routing: Routing? = nil, modes: [RouteMode]? = nil) {
        self.version = version
        self.webhook = webhook
        self.macDaemonURL = macDaemonURL
        self.routing = routing
        self.modes = modes
    }

    /// Tous les champs sont optionnels à la lecture : un JSON partiel
    /// reste valide (sections absentes = inchangées à l'application).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        webhook = try container.decodeIfPresent(WebhookConfig.self, forKey: .webhook)
        macDaemonURL = try container.decodeIfPresent(String.self, forKey: .macDaemonURL)
        routing = try container.decodeIfPresent(Routing.self, forKey: .routing)
        modes = try container.decodeIfPresent([RouteMode].self, forKey: .modes)
    }

    /// Réglages de routage persistés par `ActionRouter` ; chaque champ
    /// absent du JSON = inchangé à l'import.
    struct Routing: Codable, Equatable {
        /// actionId → cible (rawValue `ActionRouter.Target`).
        var targets: [String: ActionRouter.Target]?
        /// actionId → nom de raccourci iOS.
        var shortcuts: [String: String]?
        var hapticOnSuccess: Bool?
        var hapticOnFailure: Bool?
        /// rawValue `HapticPattern` ("short" / "double" / "long").
        var hapticPattern: String?

        init(targets: [String: ActionRouter.Target]? = nil,
             shortcuts: [String: String]? = nil,
             hapticOnSuccess: Bool? = nil, hapticOnFailure: Bool? = nil,
             hapticPattern: String? = nil) {
            self.targets = targets
            self.shortcuts = shortcuts
            self.hapticOnSuccess = hapticOnSuccess
            self.hapticOnFailure = hapticOnFailure
            self.hapticPattern = hapticPattern
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            targets = try container.decodeTargetMapIfPresent(forKey: .targets)
            shortcuts = try container.decodeIfPresent([String: String].self, forKey: .shortcuts)
            hapticOnSuccess = try container.decodeIfPresent(Bool.self, forKey: .hapticOnSuccess)
            hapticOnFailure = try container.decodeIfPresent(Bool.self, forKey: .hapticOnFailure)
            hapticPattern = try container.decodeIfPresent(String.self, forKey: .hapticPattern)
        }
    }

    // MARK: - (Dé)sérialisation

    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// Décode un profil JSON et le valide intégralement — une valeur
    /// inconnue fait échouer ici, avant toute écriture.
    static func decode(_ data: Data) throws -> AppProfile {
        let profile = try decoder.decode(AppProfile.self, from: data)
        try profile.validate()
        return profile
    }

    /// JSON exporté : joliment indenté, clés triées, JAMAIS de jeton
    /// (les secrets vivent dans le trousseau, hors `WebhookConfig`).
    func jsonData() throws -> Data {
        try Self.encoder.encode(self)
    }

    /// Validation complète : version, actions de `targets` connues,
    /// motif haptique, ids de modes uniques. Les valeurs de cibles sont
    /// déjà vérifiées au décodage (`decodeTargetMap`). Appelée par
    /// `decode` et `apply` — idempotente.
    func validate() throws {
        guard version == 1 else { throw ProfileError.unsupportedVersion(version) }
        var badActions = Set<String>()
        let knownActions = Set(ActionRouter.actions.map(\.id))
        func check(targets: [String: ActionRouter.Target]?) {
            for (action, _) in targets ?? [:] where !knownActions.contains(action) {
                badActions.insert(action)
            }
        }
        check(targets: routing?.targets)
        for mode in modes ?? [] {
            check(targets: mode.targets)
        }
        if !badActions.isEmpty { throw ProfileError.unknownActions(badActions.sorted()) }
        if let pattern = routing?.hapticPattern, HapticPattern(rawValue: pattern) == nil {
            throw ProfileError.invalidHapticPattern(pattern)
        }
        let ids = (modes ?? []).map(\.id)
        let dupes = Set(ids.filter { id in ids.filter { $0 == id }.count > 1 })
        if !dupes.isEmpty { throw ProfileError.duplicateModeIDs(dupes.sorted()) }
    }

    // MARK: - Export / application

    /// Instantané de la configuration courante — lit les clés
    /// UserDefaults dans lesquelles les objets live persistente déjà
    /// (WebhookConfig, MacDaemonBridge, ActionRouter). Sections vides
    /// omises : à l'import elles ne touche à rien.
    static func export(defaults: UserDefaults = .standard) -> AppProfile {
        var profile = AppProfile()
        let webhook = WebhookConfig.load(from: defaults)
        if !webhook.actionURL.isEmpty || !webhook.telemetryUploadURL.isEmpty
            || !webhook.telemetryHistoryURL.isEmpty
        {
            profile.webhook = webhook
        }
        if let url = defaults.string(forKey: MacDaemonBridge.baseURLKey), !url.isEmpty {
            profile.macDaemonURL = url
        }
        var routing = Routing()
        if let targets = defaults.dictionary(forKey: ActionRouter.targetsKey) as? [String: String],
           !targets.isEmpty
        {
            routing.targets = targets.compactMapValues(ActionRouter.Target.init(rawValue:))
        }
        if let shortcuts = defaults.dictionary(forKey: ActionRouter.shortcutsKey) as? [String: String],
           !shortcuts.isEmpty
        {
            routing.shortcuts = shortcuts
        }
        if defaults.object(forKey: ActionRouter.hapticSuccessKey) != nil {
            routing.hapticOnSuccess = defaults.object(forKey: ActionRouter.hapticSuccessKey) as? Bool
        }
        if defaults.object(forKey: ActionRouter.hapticFailureKey) != nil {
            routing.hapticOnFailure = defaults.object(forKey: ActionRouter.hapticFailureKey) as? Bool
        }
        if let pattern = defaults.string(forKey: ActionRouter.hapticPatternKey) {
            routing.hapticPattern = pattern
        }
        profile.routing = (routing.targets != nil || routing.shortcuts != nil
            || routing.hapticOnSuccess != nil || routing.hapticOnFailure != nil
            || routing.hapticPattern != nil) ? routing : nil
        if let data = defaults.data(forKey: ActionRouter.modesKey),
           let modes = try? JSONDecoder().decode([RouteMode].self, from: data),
           !modes.isEmpty
        {
            profile.modes = modes
        }
        return profile
    }

    /// Valide puis écrit les sections présentes dans `defaults`. Les
    /// objets live (WebhookBridge, MacDaemonBridge, ActionRouter) sont
    /// rechargés par l'appelant via leur `reload()`.
    func apply(to defaults: UserDefaults = .standard) throws {
        try validate()
        if let webhook {
            webhook.save(to: defaults)
        }
        if let macDaemonURL {
            let clean = macDaemonURL
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            defaults.set(clean, forKey: MacDaemonBridge.baseURLKey)
        }
        if let routing {
            if let targets = routing.targets {
                defaults.set(targets.mapValues(\.rawValue), forKey: ActionRouter.targetsKey)
                defaults.removeObject(forKey: ActionRouter.modeKey)
            }
            if let shortcuts = routing.shortcuts {
                defaults.set(shortcuts, forKey: ActionRouter.shortcutsKey)
            }
            if let hapticOnSuccess = routing.hapticOnSuccess {
                defaults.set(hapticOnSuccess, forKey: ActionRouter.hapticSuccessKey)
            }
            if let hapticOnFailure = routing.hapticOnFailure {
                defaults.set(hapticOnFailure, forKey: ActionRouter.hapticFailureKey)
            }
            if let hapticPattern = routing.hapticPattern {
                defaults.set(hapticPattern, forKey: ActionRouter.hapticPatternKey)
            }
        }
        if let modes {
            if let data = try? JSONEncoder().encode(modes) {
                defaults.set(data, forKey: ActionRouter.modesKey)
            }
        }
    }
}

extension KeyedDecodingContainer {
    /// `decodeTargetMap` optionnel : clé absente → nil.
    func decodeTargetMapIfPresent(forKey key: Key) throws -> [String: ActionRouter.Target]? {
        guard contains(key) else { return nil }
        return try decodeTargetMap(forKey: key)
    }
}
