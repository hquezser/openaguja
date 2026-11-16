import AppIntents
import OpenAgujaCore

/// Actions Raccourcis : c'est par là que les autres apps de l'iPhone
/// (automatisations « quand j'ouvre Deezer », « quand je reçois un
/// message de… », etc.) peuvent parler à la montre.
@available(iOS 16.0, *)
enum IntentSupport {
    static var app: AppDelegate? {
        AppDelegate.shared
    }

    /// Attend que la montre soit prête (relance en arrière-plan : la
    /// reconnexion BLE prend quelques secondes).
    @MainActor
    static func readyWatch(timeout: TimeInterval = 15) async throws -> ZeTimeBluetoothManager {
        guard let app else { throw WatchError.invalid(String(localized: "App unavailable")) }
        let deadline = Date().addingTimeInterval(timeout)
        while !app.bluetooth.isReady {
            guard Date() < deadline else { throw WatchError.notConnected }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return app.bluetooth
    }
}

@available(iOS 16.0, *)
struct SendWatchNotificationIntent: AppIntent {
    static var title: LocalizedStringResource = "Send a notification to the watch"
    static var description = IntentDescription("Shows a message on the ZeTime.")

    @Parameter(title: "Title")
    var title: String

    @Parameter(title: "Message", default: "")
    var body: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send “\(\.$title)” to the watch") {
            \.$body
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let watch = try await IntentSupport.readyWatch()
        watch.sendNotification(kind: .social, title: title, body: body)
        return .result()
    }
}

@available(iOS 16.0, *)
struct RingWatchIntent: AppIntent {
    static var title: LocalizedStringResource = "Ring the watch"

    @Parameter(title: "Stop", default: false)
    var stop: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        let watch = try await IntentSupport.readyWatch()
        try await watch.perform(.findDevice(start: !stop), label: stop ? String(localized: "Stop ringtone") : String(localized: "Ring the watch"))
        return .result()
    }
}

@available(iOS 16.0, *)
struct SendWeatherIntent: AppIntent {
    static var title: LocalizedStringResource = "Send weather to watch"

    @MainActor
    func perform() async throws -> some IntentResult {
        let watch = try await IntentSupport.readyWatch()
        guard let weather = IntentSupport.app?.weather else { throw WatchError.invalid(String(localized: "App unavailable")) }
        await weather.refresh(sendTo: watch)
        if let error = weather.lastError { throw WatchError.invalid(error) }
        return .result()
    }
}

@available(iOS 16.0, *)
struct SyncWatchTimeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set the watch time"

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentSupport.readyWatch().syncTime()
        return .result()
    }
}

@available(iOS 16.0, *)
struct WatchBatteryIntent: AppIntent {
    static var title: LocalizedStringResource = "Watch battery"

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let watch = try await IntentSupport.readyWatch()
        let payload = try await watch.request(.getBattery, label: String(localized: "Battery"))
        let level = Int(payload.first ?? 0)
        return .result(value: level, dialog: "ZeTime watch: \(level)%")
    }
}

@available(iOS 16.0, *)
struct MeasureRestingHeartRateIntent: AppIntent {
    static var title: LocalizedStringResource = "Measure my resting heart rate"
    static var description = IntentDescription("Forces a quick HR reading (5-min interval during the measurement, restored after), then records it as RHR.")

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await IntentSupport.readyWatch()
        guard let app = IntentSupport.app else { throw WatchError.invalid(String(localized: "App unavailable")) }
        await app.heartRate.measureResting()
        return .result()
    }
}

@available(iOS 16.0, *)
struct HeartRateSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Watch HR (workout)"
    static var description = IntentDescription("Samples HR every ~5 min during the session; the original interval is restored on stop (90-min safety net).")

    @Parameter(title: "Enable", default: true)
    var on: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await IntentSupport.readyWatch()
        guard let app = IntentSupport.app else { throw WatchError.invalid(String(localized: "App unavailable")) }
        if on {
            try await app.heartRate.startSession()
        } else {
            await app.heartRate.stopSession()
        }
        return .result()
    }
}

/// Modes contextuels de routage exposés comme entité d'intent : Siri et
/// les Raccourcis peuvent activer un mode par la parole. La liste est
/// lue dans `router.modes` (UserDefaults) — elle suit les profils
/// importés sans code en dur.
@available(iOS 16.0, *)
struct RouteModeEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Routing mode")
    }

    var id: String
    var displayRepresentation: DisplayRepresentation

    static var defaultQuery = RouteModeQuery()

    init(mode: RouteMode) {
        id = mode.id
        displayRepresentation = DisplayRepresentation(title: "\(mode.label)")
    }
}

@available(iOS 16.0, *)
struct RouteModeQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [RouteModeEntity] {
        let modes = Self.storedModes()
        return identifiers.compactMap { id in
            modes.first { $0.id == id }.map(RouteModeEntity.init(mode:))
        }
    }

    func suggestedEntities() async throws -> [RouteModeEntity] {
        Self.storedModes().map(RouteModeEntity.init(mode:))
    }

    /// Modes persistés (`router.modes`) — lecture directe des
    /// UserDefaults pour rester disponible avant le lancement complet
    /// de l'app par un intent.
    private static func storedModes() -> [RouteMode] {
        guard let data = UserDefaults.standard.data(forKey: ActionRouter.modesKey),
              let modes = try? JSONDecoder().decode([RouteMode].self, from: data)
        else { return [] }
        return modes
    }
}

@available(iOS 16.0, *)
struct WatchRouteModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Activate a routing mode"
    static var description = IntentDescription("Applies a ZeTime mode: action targets, Mac commands and watch button remap.")

    @Parameter(title: "Mode")
    var mode: RouteModeEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Activate mode \(\.$mode)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let app = IntentSupport.app else { throw WatchError.invalid(String(localized: "App unavailable")) }
        guard let routeMode = app.router.modes.first(where: { $0.id == mode.id }) else {
            throw WatchError.invalid(String(localized: "Unknown mode “\(mode.id)”"))
        }
        app.router.apply(mode: routeMode)
        return .result(dialog: "Mode \(routeMode.label) activated")
    }
}

@available(iOS 16.0, *)
struct ZeTimeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RingWatchIntent(),
            phrases: ["Ring my watch with \(.applicationName)"]
        )
        AppShortcut(
            intent: WatchBatteryIntent(),
            phrases: ["My watch battery with \(.applicationName)"]
        )
        AppShortcut(
            intent: SendWeatherIntent(),
            phrases: ["Send weather to my watch with \(.applicationName)"]
        )
        AppShortcut(
            intent: WatchRouteModeIntent(),
            phrases: [
                "Activate \(\.$mode) mode with \(.applicationName)",
                "Switch to \(\.$mode) mode with \(.applicationName)",
            ]
        )
    }
}
