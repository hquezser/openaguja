import Foundation

/// Mode contextuel de routage : un profil nommé (importé, voir
/// `Profile.swift`) applique une combinaison de cibles et d'effets de
/// bord à toutes les actions de la montre. Les modes sont des données
/// persistées en `router.modes` (JSON) — aucun mode n'est codé en dur ;
/// l'utilisateur importe un profil (Réglages → Profil) ou partage le
/// sien. Le mode actif est mémorisé par son `id` ; toute retouche
/// manuelle repasse en « personnalisé ».
struct RouteMode: Codable, Identifiable, Hashable {
    var id: String
    var label: String
    /// Nom de symbole SF Symbol affiché dans l'UI.
    var symbol: String
    /// Cibles par id d'action ; les actions absentes de la table gardent
    /// leur cible par défaut (`ActionRouter.defaultTarget`).
    var targets: [String: ActionRouter.Target] = [:]
    var bindings = Bindings()

    init(id: String, label: String, symbol: String,
         targets: [String: ActionRouter.Target] = [:], bindings: Bindings = .init()) {
        self.id = id
        self.label = label
        self.symbol = symbol
        self.targets = targets
        self.bindings = bindings
    }

    /// `targets` arrive en `{actionId: cible}` — les valeurs sont
    /// validées ici pour nommer les cibles inconnues à l'import.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        symbol = try container.decode(String.self, forKey: .symbol)
        targets = try container.decodeTargetMap(forKey: .targets)
        bindings = try container.decodeIfPresent(Bindings.self, forKey: .bindings) ?? .init()
    }

    /// Effets de bord d'un mode : hooks à l'activation, remap des
    /// boutons physiques (0x2E) et traduction des actions en commandes
    /// daemon propres au mode.
    struct Bindings: Codable, Equatable, Hashable {
        /// Commandes daemon `/cmd/<nom>` exécutées à l'activation, dans l'ordre.
        var onActivate: [String] = []
        /// Commandes daemon à plage horaire, évaluées à l'activation :
        /// la première dont `contains(heure locale)` gagne. `onActivate`
        /// (sans condition) part toujours en plus.
        var onActivateTimed: [TimedCommand] = []
        /// Intervalle de mesure cardio forcé à l'activation (minutes,
        /// nil = inchangé). La montre n'accepte que 5/10/15/30/60.
        var heartRateMinutes: Int? = nil
        /// actionId → nom de commande daemon : quand l'action est routée
        /// « Mac (HTTP local) », c'est ce nom (pas l'actionId) qui part
        /// en `POST /cmd/<nom>` — permet des commandes propres au mode
        /// (`camera` → `dictation` dans un mode, → `mute` dans un autre…).
        var daemonCommands: [String: String] = [:]
        /// actionId → commande daemon envoyée quand la rafale d'événements
        /// se termine (l'écran find-phone se ferme → plus de 0xD2). Sert
        /// aux actions « start/stop » : `find_phone` → `dictation_start`
        /// à l'ouverture, `dictation_stop` à la fermeture.
        var daemonEndCommands: [String: String] = [:]
        /// Bouton physique (ids 0x2E : 1 haut, 2 bas, 3 couronne court,
        /// 4 couronne long) → fonction, poussé sur la montre à
        /// l'activation. Seules les fonctions 4 (musique), 6 (appareil
        /// photo) et 16 (trouver le téléphone) émettent des événements
        /// routables ; les autres agissent localement sur la montre.
        /// JSON : objet à clés texte, ex. `"buttons": {"3": 6, "4": 16}`.
        var buttons: [UInt8: UInt8] = [:]
        /// Les actions musique ignorent la source choisie sur la montre
        /// et passent par MediaRemote (Deezer et autres lecteurs).
        var musicViaNowPlaying = false

        /// Codable est entièrement manuel (clés de `buttons` texte,
        /// champs vides omis) — la synthèse ne fournit pas CodingKeys.
        enum CodingKeys: String, CodingKey {
            case onActivate, onActivateTimed, heartRateMinutes
            case daemonCommands, daemonEndCommands, buttons, musicViaNowPlaying
        }

        init() {}

        init(onActivate: [String] = [], onActivateTimed: [TimedCommand] = [],
             heartRateMinutes: Int? = nil, daemonCommands: [String: String] = [:],
             daemonEndCommands: [String: String] = [:], buttons: [UInt8: UInt8] = [:],
             musicViaNowPlaying: Bool = false) {
            self.onActivate = onActivate
            self.onActivateTimed = onActivateTimed
            self.heartRateMinutes = heartRateMinutes
            self.daemonCommands = daemonCommands
            self.daemonEndCommands = daemonEndCommands
            self.buttons = buttons
            self.musicViaNowPlaying = musicViaNowPlaying
        }

        /// Tous les champs sont optionnels à la lecture : un JSON de
        /// bindings partiel garde les valeurs par défaut pour le reste.
        /// `buttons` exige des clés numériques ("3" → bouton 3) — une clé
        /// non numérique fait échouer le décodage en la nommant.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            onActivate = try container.decodeIfPresent([String].self, forKey: .onActivate) ?? []
            onActivateTimed = try container.decodeIfPresent([TimedCommand].self, forKey: .onActivateTimed) ?? []
            heartRateMinutes = try container.decodeIfPresent(Int.self, forKey: .heartRateMinutes)
            daemonCommands = try container.decodeIfPresent([String: String].self, forKey: .daemonCommands) ?? [:]
            daemonEndCommands = try container.decodeIfPresent([String: String].self, forKey: .daemonEndCommands) ?? [:]
            if let raw = try container.decodeIfPresent([String: UInt8].self, forKey: .buttons) {
                var map: [UInt8: UInt8] = [:]
                for (key, value) in raw {
                    guard let button = UInt8(key) else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .buttons, in: container,
                            debugDescription: "Invalid button id “\(key)” (expected integer 0-255)"
                        )
                    }
                    map[button] = value
                }
                buttons = map
            } else {
                buttons = [:]
            }
            musicViaNowPlaying = try container.decodeIfPresent(Bool.self, forKey: .musicViaNowPlaying) ?? false
        }

        /// N'écrit que les champs non vides : les profils restent lisibles.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if !onActivate.isEmpty { try container.encode(onActivate, forKey: .onActivate) }
            if !onActivateTimed.isEmpty { try container.encode(onActivateTimed, forKey: .onActivateTimed) }
            try container.encodeIfPresent(heartRateMinutes, forKey: .heartRateMinutes)
            if !daemonCommands.isEmpty { try container.encode(daemonCommands, forKey: .daemonCommands) }
            if !daemonEndCommands.isEmpty { try container.encode(daemonEndCommands, forKey: .daemonEndCommands) }
            if !buttons.isEmpty {
                let json = Dictionary(uniqueKeysWithValues: buttons.map { (String($0.key), $0.value) })
                try container.encode(json, forKey: .buttons)
            }
            if musicViaNowPlaying { try container.encode(true, forKey: .musicViaNowPlaying) }
        }

        /// Première plage horaire contenant `date` (heure locale) —
        /// nil si aucune ne correspond.
        func timedCommand(at date: Date = .now) -> TimedCommand? {
            let hour = Calendar.current.component(.hour, from: date)
            return onActivateTimed.first { $0.contains(hour) }
        }
    }

    /// Commande daemon alternative selon l'heure locale au moment de
    /// l'activation du mode.
    struct TimedCommand: Codable, Equatable, Hashable {
        /// Heure de début inclusive (0-23).
        var from: Int
        /// Heure de fin exclusive ; `to < from` = plage nocturne
        /// (ex. 22→6 couvre 22h-5h59).
        var to: Int
        /// Nom de la commande daemon `/cmd/<nom>`.
        var command: String

        func contains(_ hour: Int) -> Bool {
            to > from ? (hour >= from && hour < to) : (hour >= from || hour < to)
        }
    }

    /// Fonctions de boutons physiques (0x2E) proposées par les profils :
    /// la fonction 6 ouvre l'app caméra sur la montre ET émet 0xD1 ; la
    /// fonction 16 ouvre l'écran trouver-le-téléphone ET émet 0xD2 en
    /// boucle (~1/s tant que l'alerte est active — d'où l'anti-rebond
    /// côté MacDaemonBridge). Vérifié live (2026-11-14).
    static let crownShortCamera: UInt8 = 6
    static let crownLongFindPhone: UInt8 = 16
    static let crownShortMusic: UInt8 = 4
}

/// Motif du retour haptique « au poignet » après une action routée vers
/// le webhook ou le daemon.
enum HapticPattern: String, CaseIterable, Identifiable {
    case short, double, long

    var id: String { rawValue }

    var label: String {
        switch self {
        case .short: return String(localized: "Short")
        case .double: return String(localized: "Double")
        case .long: return String(localized: "Long")
        }
    }

    var symbol: String {
        switch self {
        case .short: return "waveform.path"
        case .double: return "waveform.path.ecg"
        case .long: return "waveform"
        }
    }

    /// Séquences (délai en s, actif) jouées via `findDevice` start/stop —
    /// la montre vibre tant que `start` est vrai.
    var buzzEvents: [(delay: TimeInterval, on: Bool)] {
        switch self {
        case .short: return [(0, true), (0.4, false)]
        case .double: return [(0, true), (0.35, false), (0.6, true), (0.95, false)]
        case .long: return [(0, true), (1.2, false)]
        }
    }
}

/// Où envoyer chaque action de la montre (boutons musique, molette,
/// trouver le téléphone…). Configurable par action, mémorisé localement.
final class ActionRouter: ObservableObject {
    enum Target: String, CaseIterable, Identifiable, Codable {
        /// POST JSON vers l'URL webhook configurée (Réglages → Webhook
        /// HTTP) : corps `{action, value?, text?, timestamp}`.
        case webhook
        /// Lecteur Apple Music du téléphone (MPMusicPlayerController).
        case appleMusic
        /// Alarme sur le téléphone (ignore le mode silencieux, lampe
        /// torche, arrêt auto après 60 s).
        case ringPhone
        /// Photo avec l'appareil de l'iPhone (app au premier plan ; sinon
        /// notification invitant à l'ouvrir).
        case phoneCamera
        /// Raccourci iOS nommé (lancé seulement app au premier plan).
        case shortcut
        /// Micro-daemon HTTP sur le Mac (`openaguja-macd`, même Wi-Fi) :
        /// POST /cmd/<action> avec Bearer — fonctionne app verrouillée.
        case macDaemon
        case ignore

        var id: String { rawValue }

        var label: String {
            switch self {
            case .webhook: return String(localized: "Webhook HTTP")
            case .appleMusic: return String(localized: "Apple Music")
            case .ringPhone: return String(localized: "Ring iPhone")
            case .phoneCamera: return "iPhone camera"
            case .shortcut: return "iOS Shortcut"
            case .macDaemon: return String(localized: "Mac (local HTTP)")
            case .ignore: return String(localized: "Ignore")
            }
        }
    }

    struct WatchActionInfo: Identifiable {
        let id: String
        let label: String
        let symbol: String
        let targets: [Target]
    }

    /// Actions émises par la montre, dans l'ordre d'affichage.
    /// `.macDaemon` est proposé partout : le daemon nomme ses commandes
    /// d'après ces ids (`/cmd/play`, `/cmd/find_phone`…).
    static let actions: [WatchActionInfo] = [
        .init(id: "play", label: String(localized: "Play"), symbol: "play.fill", targets: [.webhook, .appleMusic, .macDaemon, .shortcut, .ignore]),
        .init(id: "pause", label: String(localized: "Pause"), symbol: "pause.fill", targets: [.webhook, .appleMusic, .macDaemon, .shortcut, .ignore]),
        .init(id: "previous", label: String(localized: "Previous"), symbol: "backward.fill", targets: [.webhook, .appleMusic, .macDaemon, .shortcut, .ignore]),
        .init(id: "next", label: String(localized: "Next"), symbol: "forward.fill", targets: [.webhook, .appleMusic, .macDaemon, .shortcut, .ignore]),
        .init(id: "volume_up", label: String(localized: "Volume +"), symbol: "speaker.plus.fill", targets: [.webhook, .macDaemon, .shortcut, .ignore]),
        .init(id: "volume_down", label: String(localized: "Volume −"), symbol: "speaker.minus.fill", targets: [.webhook, .macDaemon, .shortcut, .ignore]),
        .init(id: "find_phone", label: String(localized: "Find phone"), symbol: "iphone.radiowaves.left.and.right", targets: [.ringPhone, .webhook, .macDaemon, .shortcut, .ignore]),
        .init(id: "camera", label: String(localized: "Camera"), symbol: "camera.fill", targets: [.phoneCamera, .webhook, .macDaemon, .shortcut, .ignore]),
        .init(id: "call_rejected", label: String(localized: "Call rejected"), symbol: "phone.down.fill", targets: [.webhook, .macDaemon, .shortcut, .ignore]),
        .init(id: "sos", label: "SOS", symbol: "sos", targets: [.webhook, .ringPhone, .macDaemon, .shortcut, .ignore]),
        .init(id: "quick_reply", label: String(localized: "Quick reply"), symbol: "text.bubble.fill", targets: [.webhook, .macDaemon, .shortcut, .ignore]),
    ] + remoteActions

    /// Boutons 1-6 de l'app « Remote » ajoutée par le patch firmware
    /// communautaire `page4` (0xE8, zetime.artificialred.nl) — une montre
    /// au firmware d'origine ne les émet jamais. Ids `remote_<n>` alignés
    /// sur `watchActionId` côté Rust.
    static let remoteActions: [WatchActionInfo] = (1...6).map { n in
        .init(id: "remote_\(n)", label: String(localized: "Remote button \(n)"),
              symbol: "\(n).circle.fill", targets: [.webhook, .macDaemon, .shortcut, .ignore])
    }

    static func isRemoteAction(_ id: String) -> Bool { id.hasPrefix("remote_") }

    @Published private(set) var targets: [String: Target]
    @Published private(set) var shortcuts: [String: String]
    /// Modes de routage importés (profils) — voir `Profile.swift`.
    @Published private(set) var modes: [RouteMode]
    /// Mode contextuel appliqué (nil = cibles personnalisées).
    @Published private(set) var activeMode: RouteMode?
    /// Appelé après chaque `apply(mode:)` — l'app exécute les hooks du
    /// mode (commandes daemon, intervalle cardio, remap des boutons).
    var onActivate: ((RouteMode) -> Void)?
    /// Retour haptique « au poignet » après un résultat webhook.
    @Published var hapticOnSuccess: Bool {
        didSet { defaults.set(hapticOnSuccess, forKey: Self.hapticSuccessKey) }
    }
    @Published var hapticOnFailure: Bool {
        didSet { defaults.set(hapticOnFailure, forKey: Self.hapticFailureKey) }
    }
    @Published var hapticPattern: HapticPattern {
        didSet { defaults.set(hapticPattern.rawValue, forKey: Self.hapticPatternKey) }
    }

    /// Clés UserDefaults — internes pour `Profile.swift` (export/apply).
    static let targetsKey = "router.targets"
    static let shortcutsKey = "router.shortcuts"
    static let modeKey = "router.mode"
    static let modesKey = "router.modes"
    static let hapticSuccessKey = "router.hapticSuccess"
    static let hapticFailureKey = "router.hapticFailure"
    static let hapticPatternKey = "router.hapticPattern"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Self.targetsKey) as? [String: String] ?? [:]
        targets = saved.compactMapValues(Target.init(rawValue:))
        shortcuts = defaults.dictionary(forKey: Self.shortcutsKey) as? [String: String] ?? [:]
        modes = Self.loadModes(from: defaults)
        hapticOnSuccess = defaults.object(forKey: Self.hapticSuccessKey) as? Bool ?? true
        hapticOnFailure = defaults.object(forKey: Self.hapticFailureKey) as? Bool ?? true
        hapticPattern = HapticPattern(rawValue: defaults.string(forKey: Self.hapticPatternKey) ?? "") ?? .short
        activeMode = modes.first { $0.id == defaults.string(forKey: Self.modeKey) }
        // Le mode actif doit refléter sa table : des cibles devenues
        // invalides (ancienne version) retomblent sur les défauts du mode.
        if let activeMode { syncTargets(to: activeMode) }
    }

    /// Relit tout l'état persisté — après l'application d'un profil
    /// importé (`Profile.apply` écrit les clés directement).
    func reload() {
        let saved = defaults.dictionary(forKey: Self.targetsKey) as? [String: String] ?? [:]
        targets = saved.compactMapValues(Target.init(rawValue:))
        shortcuts = defaults.dictionary(forKey: Self.shortcutsKey) as? [String: String] ?? [:]
        modes = Self.loadModes(from: defaults)
        activeMode = modes.first { $0.id == defaults.string(forKey: Self.modeKey) }
        if let activeMode { syncTargets(to: activeMode) }
        hapticOnSuccess = defaults.object(forKey: Self.hapticSuccessKey) as? Bool ?? true
        hapticOnFailure = defaults.object(forKey: Self.hapticFailureKey) as? Bool ?? true
        hapticPattern = HapticPattern(rawValue: defaults.string(forKey: Self.hapticPatternKey) ?? "") ?? .short
    }

    private static func loadModes(from defaults: UserDefaults) -> [RouteMode] {
        guard let data = defaults.data(forKey: modesKey),
              let modes = try? JSONDecoder().decode([RouteMode].self, from: data)
        else { return [] }
        return modes
    }

    /// Cible par défaut : « trouver le téléphone » sonne, l'appareil
    /// photo passe par l'iPhone ; tout le reste part au webhook.
    static func defaultTarget(for id: String) -> Target {
        switch id {
        case "find_phone": return .ringPhone
        case "camera": return .phoneCamera
        default: return .webhook
        }
    }

    func target(for id: String) -> Target {
        targets[id] ?? Self.defaultTarget(for: id)
    }

    /// Commande daemon à envoyer pour une action routée « Mac (HTTP
    /// local) » : le nom propre au mode si défini, sinon l'actionId.
    func daemonCommand(for id: String) -> String {
        activeMode?.bindings.daemonCommands[id] ?? id
    }

    /// Commande daemon envoyée à la fin d'une rafale d'événements (nil
    /// si l'action n'en déclare pas — ex. find_phone → dictation_stop
    /// quand l'écran se ferme et que les 0xD2 cessent).
    func daemonEndCommand(for id: String) -> String? {
        activeMode?.bindings.daemonEndCommands[id]
    }

    func setTarget(_ target: Target, for id: String) {
        targets[id] = target
        defaults.set(targets.mapValues(\.rawValue), forKey: Self.targetsKey)
        // Retouche manuelle : le mode contextuel ne reflète plus la config.
        activeMode = nil
        defaults.removeObject(forKey: Self.modeKey)
    }

    /// Applique un mode contextuel à toutes les actions (cibles de la
    /// table, défauts pour le reste) puis le mémorise.
    func apply(mode: RouteMode) {
        syncTargets(to: mode)
        activeMode = mode
        defaults.set(mode.id, forKey: Self.modeKey)
        onActivate?(mode)
    }

    /// Variante par identifiant (intents, profils) : résout le mode
    /// parmi ceux importés — id inconnu = sans effet.
    func apply(modeId: String) {
        guard let mode = modes.first(where: { $0.id == modeId }) else { return }
        apply(mode: mode)
    }

    /// Remplace la liste des modes (import de profil) : le mode actif
    /// est re-résolu par son id ; les cibles reprennent sa table.
    func setModes(_ modes: [RouteMode]) {
        self.modes = modes
        if let data = try? JSONEncoder().encode(modes) {
            defaults.set(data, forKey: Self.modesKey)
        }
        let savedId = defaults.string(forKey: Self.modeKey)
        activeMode = modes.first { $0.id == savedId }
        if activeMode == nil {
            defaults.removeObject(forKey: Self.modeKey)
        } else if let activeMode {
            syncTargets(to: activeMode)
        }
    }

    /// Écrit la table de cibles du mode dans `targets` et la persiste —
    /// sans déclencher les hooks (utilisé à l'init et par `apply`).
    private func syncTargets(to mode: RouteMode) {
        for action in Self.actions {
            targets[action.id] = mode.targets[action.id] ?? Self.defaultTarget(for: action.id)
        }
        defaults.set(targets.mapValues(\.rawValue), forKey: Self.targetsKey)
    }

    func shortcut(for id: String) -> String {
        shortcuts[id] ?? ""
    }

    func setShortcut(_ name: String, for id: String) {
        shortcuts[id] = name
        defaults.set(shortcuts, forKey: Self.shortcutsKey)
    }

    /// Préréglage : boutons musique → Apple Music (le reste → webhook).
    func useAppleMusicForMedia() {
        for id in ["play", "pause", "previous", "next"] {
            setTarget(.appleMusic, for: id)
        }
    }

    func useWebhookForAll() {
        for action in Self.actions where action.targets.contains(.webhook) {
            setTarget(.webhook, for: action.id)
        }
    }

    /// URL `shortcuts://` d'un raccourci nommé, si configuré.
    func shortcutURL(for id: String) -> URL? {
        let name = shortcut(for: id).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var components = URLComponents(string: "shortcuts://run-shortcut")
        components?.queryItems = [URLQueryItem(name: "name", value: name)]
        return components?.url
    }
}

/// Décode `{actionId: "target"}` en `[String: ActionRouter.Target]` —
/// les valeurs inconnues font échouer le décodage en les nommant.
extension KeyedDecodingContainer {
    func decodeTargetMap(forKey key: Key) throws -> [String: ActionRouter.Target] {
        guard let raw = try decodeIfPresent([String: String].self, forKey: key) else { return [:] }
        var map: [String: ActionRouter.Target] = [:]
        var unknown = Set<String>()
        for (action, value) in raw {
            if let target = ActionRouter.Target(rawValue: value) {
                map[action] = target
            } else {
                unknown.insert(value)
            }
        }
        if !unknown.isEmpty {
            throw ProfileError.unknownTargets(unknown.sorted())
        }
        return map
    }
}
