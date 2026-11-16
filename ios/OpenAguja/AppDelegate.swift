import UIKit
import UserNotifications
import OpenAgujaCore

/// Le CBCentralManager est créé ici et pas dans la scène SwiftUI : sur une
/// relance en arrière-plan (BLE state restoration), iOS peut appeler
/// didFinishLaunchingWithOptions sans jamais instancier de scène.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Instance active : avec @UIApplicationDelegateAdaptor,
    /// `UIApplication.shared.delegate` est un proxy SwiftUI (Raccourcis).
    private(set) static weak var shared: AppDelegate?

    let log = LogStore()
    lazy var bridge = WebhookBridge(log: log)
    /// Micro-daemon HTTP du Mac (même Wi-Fi) — cible « Mac (HTTP local) ».
    lazy var macd = MacDaemonBridge(log: log)
    let router = ActionRouter()
    lazy var weather = WeatherService(log: log)
    lazy var activity = ActivityStore(log: log)
    let settings = WatchSettingsModel()
    let music = MusicController()
    let calls = CallMonitor()
    let volume = SystemVolume()
    /// Actions iPhone locales (caméra, alarme « trouver le téléphone »).
    let phone = PhoneActions()
    let calendar = CalendarSync()
    /// Cardio à la demande : FCR matinale + session sport via
    /// `SetHeartRateInterval` (les sauts 0x1A sont des no-op sur A2.0.55,
    /// voir issue #17).
    lazy var heartRate = HeartRateService(watch: bluetooth, activity: activity, settings: settings, log: log)

    private(set) lazy var bluetooth = ZeTimeBluetoothManager(log: log)
    /// Télémétrie brute → `telemetryUploadURL` du webhook (file persistée
    /// + renvoi au retour réseau ; même config/jeton que WebhookBridge).
    lazy var telemetryUploader = TelemetryUploader(
        log: log,
        config: { [weak self] in self?.bridge.config ?? WebhookConfig() },
        token: { Keychain.token() }
    )
    /// Traduit trames BLE + signaux de lien en TelemetryEvent JSON.
    lazy var telemetry = TelemetryService(uploader: telemetryUploader, log: log)
    /// Synthèses quotidiennes lues depuis `telemetryHistoryURL` du
    /// webhook (graphes dans Réglages → Webhook HTTP → Historique ;
    /// même config/jeton que l'uploader).
    lazy var telemetryHistory = TelemetryHistoryStore(
        config: { [weak self] in self?.bridge.config ?? WebhookConfig() },
        token: { Keychain.token() }
    )
    private var weatherTimer: Timer?

    /// Délai sans rotation avant d'envoyer l'événement volume (webhook
    /// ou daemon Mac) — les crans de la molette sont regroupés.
    private static let volumeDebounce: TimeInterval = 1.5
    private var volumeWork: DispatchWorkItem?
    private var volumeSteps = 0

    /// Synchro d'activité automatique à la connexion si la dernière est
    /// plus vieille que la cadence du profil énergétique courant.
    private static var activityAutoSyncAge: TimeInterval {
        EnergyProfile.current.autoSyncAge
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Self.shared = self
        // Force la création du manager avant toute scène (l'adaptateur appelle
        // cette méthode avant la première scène).
        wire()
        // Notifications locales : rappel « ouvrir l'app » quand la montre
        // demande une photo en arrière-plan (capture impossible hors
        // premier plan).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        return true
    }

    private func wire() {
        bluetooth.actionHandler = { [weak self] id, action in
            self?.route(id, action: action)
        }
        bluetooth.musicSourceHandler = { [weak self] source in
            self?.musicSourceChanged(source)
        }
        // Retour haptique « au poignet » : vibration de la montre après
        // chaque résultat d'action routée vers le webhook ou le daemon.
        bridge.onSendResult = { [weak self] success in
            self?.wristHaptic(success: success)
        }
        macd.onSendResult = { [weak self] success in
            self?.wristHaptic(success: success)
        }
        // Activation d'un mode contextuel : hooks daemon, intervalle
        // cardio et remap des boutons physiques sur la montre.
        router.onActivate = { [weak self] mode in
            self?.activateMode(mode)
        }
        bluetooth.onReady = { [weak self] in
            // Reconnexion : la file d'attente repart (critère « renvoi à la
            // reconnexion ») puis les synchros métier.
            Task { @MainActor in self?.telemetry.flush() }
            self?.connectionReady()
        }
        Task { @MainActor in telemetry.attach(watch: bluetooth) }
        // Retour premier plan / entrée arrière-plan : vidange + sauvegarde
        // immédiate de la file (la suspension peut survenir juste après).
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.telemetry.flush() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.telemetryUploader.persist() }
        }
        music.onChange = { [weak self] playing, title in
            guard let self, self.router.target(for: "play") == .appleMusic else { return }
            self.bluetooth.updateMusic(playing: playing, title: title)
        }
        calls.onIncoming = { [weak self] in
            self?.bluetooth.sendIncomingCall(caller: "Incoming call")
        }
        calls.onEnded = { [weak self] in
            self?.bluetooth.sendCallEnded()
        }
        weatherTimer = Timer.scheduledTimer(withTimeInterval: WeatherService.maxAge, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.weather.refresh(sendTo: self.bluetooth) }
        }
    }

    /// Action de la montre → cible choisie dans l'onglet Boutons. Les
    /// actions musique dépendent d'abord du lecteur choisi sur la montre :
    /// Deezer est piloté directement, les autres lecteurs suivent
    /// l'onglet Boutons.
    private func route(_ id: String, action: WatchAction? = nil) {
        // Texte résolu d'une réponse rapide (preset/emoji/contenu) —
        // forwardé dans le payload des cibles qui l'acceptent.
        var replyText: String?
        if case let .quickReply(_, text, _, _, _, _, _, _) = action, !text.isEmpty {
            replyText = text
        }
        let mode = router.activeMode
        if ZeTimeBluetoothManager.musicActionIds.contains(id),
           bluetooth.musicSource.id == "deezer" || mode?.bindings.musicViaNowPlaying == true
        {
            controlNowPlaying(id)
            return
        }
        switch router.target(for: id) {
        case .webhook where id == "volume_up" || id == "volume_down":
            debounceVolume(step: id == "volume_up" ? 1 : -1) { [weak self] actionId, value in
                self?.bridge.send(actionId: actionId, value: value)
            }
        case .macDaemon where id == "volume_up" || id == "volume_down":
            debounceVolume(step: id == "volume_up" ? 1 : -1) { [weak self] actionId, value in
                guard let self else { return }
                self.macd.send(command: self.router.daemonCommand(for: actionId), value: value)
            }
        case .webhook:
            bridge.send(actionId: id, text: replyText)
        case .macDaemon:
            macd.send(command: router.daemonCommand(for: id), text: replyText)
            // find_phone routé « Mac (daemon) » n'est qu'un porteur
            // d'événements : l'écran find-phone de la montre pulse en
            // boucle — on coupe le moteur une fois la commande partie.
            if id == "find_phone" {
                silenceWatchAlert()
            }
            scheduleBurstEnd(for: id)
        case .appleMusic:
            music.handle(id)
        case .ringPhone:
            phone.startAlarm()
        case .phoneCamera:
            phone.shoot()
        case .shortcut:
            guard let url = router.shortcutURL(for: id) else {
                log.add(.error, "No shortcut configured for \(id)")
                return
            }
            // iOS n'ouvre une URL que pour une app au premier plan.
            if UIApplication.shared.applicationState == .active {
                UIApplication.shared.open(url)
            } else {
                log.add(.error, "Shortcut “\(router.shortcut(for: id))” skipped: app in background")
            }
        case .ignore:
            break
        }
    }

    /// Activation d'un mode contextuel : exécute ses hooks — commandes
    /// daemon (dans l'ordre), intervalle cardio forcé, puis remap des
    /// boutons physiques sur la montre (uniquement les écarts).
    private func activateMode(_ mode: RouteMode) {
        let bindings = mode.bindings
        log.add(.info, "Mode “\(mode.label)” activated")
        for command in bindings.onActivate {
            macd.send(command: command)
        }
        if let timed = bindings.timedCommand() {
            log.add(.info, "Timed command “\(timed.command)” (mode \(mode.label))")
            macd.send(command: timed.command)
        }
        if let minutes = bindings.heartRateMinutes {
            Task { @MainActor in
                await settings.apply(
                    .setHeartRateInterval(minutes: UInt8(minutes)),
                    label: String(localized: "Cardio \(minutes) min (mode \(mode.label))"),
                    on: bluetooth
                )
            }
        }
        Task { @MainActor in await pushModeButtons(mode) }
    }

    /// Pousse sur la montre les fonctions de boutons du mode — ne touche
    /// que les entrées définies et différentes de la table courante.
    @MainActor
    private func pushModeButtons(_ mode: RouteMode) async {
        let desired = mode.bindings.buttons
        guard bluetooth.isReady, !desired.isEmpty else { return }
        let current = Dictionary(
            bluetooth.buttonFunctions.map { ($0.button, $0.function) },
            uniquingKeysWith: { $1 }
        )
        for (button, function) in desired.sorted(by: { $0.key < $1.key }) where current[button] != function {
            do {
                try await bluetooth.perform(
                    .setButtonFunction(button: button, function: function),
                    label: String(localized: "Mode \(mode.label): \(WatchButtonTables.buttonLabel(button))")
                )
            } catch {
                log.add(.error, "Remap mode \(mode.label) : \(error.localizedDescription)")
            }
        }
        await bluetooth.refreshButtonFunctions()
    }

    /// Lecteur Deezer choisi sur la montre : ouvre l'app (premier plan
    /// seulement, iOS l'interdit sinon).
    private func musicSourceChanged(_ source: ZeTimeBluetoothManager.MusicSource) {
        if source.id == "deezer" {
            phone.openPlayer(source.id)
            // La molette part du volume réel de l'iPhone.
            volume.prepare()
            bluetooth.setMusicVolumeOnNextRequest(UInt8((volume.level * 100).rounded()))
        }
    }

    /// Commande envoyée à l'app en cours de lecture (Deezer) via
    /// MediaRemote ; la molette règle le volume système de l'iPhone sur le
    /// niveau absolu envoyé par la montre (0…100).
    private func controlNowPlaying(_ id: String) {
        if ["volume", "volume_up", "volume_down"].contains(id) {
            let level = bluetooth.musicVolume
            if volume.set(Float(level) / 100) {
                log.add(.info, "Deezer : volume \(level) %")
            } else {
                log.add(.error, "Deezer: volume \(level)% failed (system slider not found)")
            }
            return
        }
        guard let command = NowPlaying.command(for: id) else {
            log.add(.info, "Deezer : \(id) non pris en charge")
            return
        }
        if NowPlaying.send(command) {
            log.add(.info, "Deezer: \(id) sent")
        } else {
            log.add(.error, "Deezer: \(id) refused by iOS (MediaRemote \(NowPlaying.isAvailable ? "available" : "absent"))")
        }
    }

    /// Aperçu « Volume 60 % » sur la montre ; la direction nette et le
    /// niveau final partent en une requête quand la molette s'arrête.
    /// `send` reçoit l'id final (volume_up/down) et le niveau absolu.
    private func debounceVolume(step: Int, send: @escaping (String, Int?) -> Void) {
        volumeSteps += step
        let level = bluetooth.musicVolume
        bluetooth.updateMusic(playing: bluetooth.musicPlaying, title: String(localized: "Volume \(level) %"))
        volumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let steps = self.volumeSteps
            self.volumeSteps = 0
            self.bluetooth.updateMusic(playing: self.bluetooth.musicPlaying, title: self.bluetooth.musicSource.name)
            guard steps != 0 else { return }
            self.log.add(.info, "Volume \(level)% (\(steps > 0 ? "+" : "")\(steps) step(s) batched)")
            send(steps > 0 ? "volume_up" : "volume_down", Int(level))
        }
        volumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.volumeDebounce, execute: work)
    }

    /// Fin de rafale : chaque événement d'une action « start/stop »
    /// replanifie le tir — la commande de fin (ex. dictation_stop)
    /// ne part que si plus rien n'arrive depuis `burstSilence`, c.-à-d.
    /// quand l'écran find-phone de la montre est refermé.
    /// La montre émet les 0xD2 toutes les ~2 s (jitter jusqu'à ~2.6 s
    /// mesuré live) tant que l'écran find-phone est ouvert — la
    /// fermeture réelle ne se détecte qu'après plusieurs intervalles
    /// manqués ; 5 s ≈ 2 cadences pleines.
    private static let burstSilence: TimeInterval = 5
    private var burstEndTimers: [String: DispatchWorkItem] = [:]

    private func scheduleBurstEnd(for id: String) {
        guard let command = router.daemonEndCommand(for: id) else { return }
        burstEndTimers[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.burstEndTimers[id] = nil
            self?.macd.send(command: command)
        }
        burstEndTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.burstSilence, execute: work)
    }

    /// find_phone → daemon : `findDevice stop` éteint la vibration de
    /// l'écran find-phone ~3 s après le premier événement (la montre
    /// ré-émet 0xD2 en boucle tant que l'écran reste ouvert — une seule
    /// planification par rafale, garde de 8 s).
    private var lastAlertSilence = Date.distantPast
    private func silenceWatchAlert() {
        guard Date().timeIntervalSince(lastAlertSilence) > 8 else { return }
        lastAlertSilence = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.bluetooth.findWatch(start: false)
        }
    }

    /// Vibre la montre selon le motif configuré dans l'onglet Routage.
    /// `findDevice start/stop` pilote le moteur : chaque événement de la
    /// séquence allume ou éteint la vibration à son délai.
    private func wristHaptic(success: Bool) {
        let enabled = success ? router.hapticOnSuccess : router.hapticOnFailure
        guard enabled, bluetooth.isReady else { return }
        for event in router.hapticPattern.buzzEvents {
            DispatchQueue.main.asyncAfter(deadline: .now() + event.delay) { [weak self] in
                self?.bluetooth.findWatch(start: event.on)
            }
        }
    }

    /// À chaque connexion : météo et synchro d'activité si périmées.
    private func connectionReady() {
        Task { @MainActor in
            // Bind QR une seule fois après un appairage explicite.
            if bluetooth.pendingQrBind {
                await bluetooth.completeQrBind()
            }
            if weather.enabled {
                if weather.isStale {
                    await weather.refresh(sendTo: bluetooth)
                } else {
                    await weather.resend(to: bluetooth)
                }
            }
            if Date().timeIntervalSince(activity.lastSync ?? .distantPast) > Self.activityAutoSyncAge {
                await activity.sync(from: bluetooth)
            }
            // Sortie d'une éventuelle session cardio restée active (BLE
            // coupé en cours de séance), complétion d'une FCR interrompue
            // par une suspension, puis FCR matinale si dormi récemment.
            await heartRate.recover()
            await heartRate.checkPendingFCR()
            await heartRate.checkRestingMeasurement()
            // Synchro échelonnée (modèle Android SyncCoordinator) :
            // réglages relus au plus une fois par 24 h.
            if Date().timeIntervalSince(settings.loadedAt ?? .distantPast) > 24 * 3600 {
                await settings.load(from: bluetooth)
            }
        }
    }
}
