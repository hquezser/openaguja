import Foundation

#if canImport(OpenAgujaCore)
    import OpenAgujaCore
#endif

/// Cardio à la demande piloté par l'intervalle auto (`0x5C`,
/// `SetHeartRateInterval`) — les sauts `0x1A[0x03]`/`[0x0F]` du SDK
/// décompilé ont été testés live les 08/11/2026 et ne produisent rien
/// sur A2.0.55 (le saut caméra `0x0B` était déjà refusé ack=2 le 29/10).
///
/// Stratégie : descendre temporairement l'intervalle à 5 min (minimum
/// accepté par le firmware — 1 est refusé), attendre le prochain relevé,
/// puis restaurer l'intervalle d'origine.
final class HeartRateService: ObservableObject {
    /// Intervalle forcé pendant une mesure/session. Le firmware REFUSE 1
    /// (ack status 1, live 2026-11-08) — 5 min = plus petite valeur
    /// acceptée, cohérente avec les choix du picker officiel.
    private static let fastInterval: UInt8 = 5
    /// Durée max d'attente d'un relevé (intervalle 5 min + chauffe capteur).
    static let measureTimeout: TimeInterval = 400
    /// Intervalle de polling du compteur de records cardio.
    private static let pollInterval: TimeInterval = 15
    /// Filet de sécurité : fin de session auto si oubliée.
    static let sessionTimeout: TimeInterval = 90 * 60
    /// Fenêtre max après la fin du sommeil pour tenter la FCR.
    static let restingWindow: TimeInterval = 3 * 3600
    /// Durée de vie du marqueur « FCR en attente » : l'app peut être
    /// suspendue pendant le relevé, la complétion a lieu à la prochaine
    /// connexion (les records restent sur la montre jusqu'à la synchro).
    private static let pendingWindow: TimeInterval = 6 * 3600

    private static let sessionFlag = "hr.sessionActive"
    private static let savedIntervalKey = "hr.savedInterval"
    /// `since`/`expires` (epoch) du one-shot FCR interrompu.
    private static let pendingFCRKey = "hr.pendingFCR"

    private let watch: ZeTimeBluetoothManager
    private let activity: ActivityStore
    private let settings: WatchSettingsModel
    private let log: LogStore

    /// Session cardio en cours = intervalle forcé à 5 min.
    @Published private(set) var sessionActive = false
    /// Dernier BPM poussé par la montre (0xE2) — nil si jamais reçu.
    @Published private(set) var liveBpm: Int?
    /// Horodatage du dernier push 0xE2 (pour juger de la fraîcheur).
    @Published private(set) var liveBpmDate: Date?
    /// One-shot FCR en cours — évite les doubles mesures.
    private var measuring = false
    private var sessionWork: DispatchWorkItem?

    init(watch: ZeTimeBluetoothManager, activity: ActivityStore, settings: WatchSettingsModel, log: LogStore) {
        self.watch = watch
        self.activity = activity
        self.settings = settings
        self.log = log
        sessionActive = UserDefaults.standard.bool(forKey: Self.sessionFlag)
        watch.realTimeHeartRateHandler = { [weak self] bpm in
            Task { @MainActor in
                self?.liveBpm = Int(bpm)
                self?.liveBpmDate = Date()
            }
        }
    }

    // MARK: - Intervalle

    /// Valeur actuelle de l'intervalle cardio : relue sur la montre,
    /// sinon repli sur la valeur configurée dans l'app.
    @MainActor
    private func currentInterval() async -> UInt8 {
        do {
            guard case .heartRateInterval(let minutes) = try await watch.readSetting(.heartRateInterval)
            else { throw WatchError.invalid("HR interval setting unreadable") }
            return minutes
        } catch {
            log.add(.info, "HR interval unreadable (\(error.localizedDescription)) — falling back to \(settings.heartRateIntervalIntent) min")
            return UInt8(clamping: settings.heartRateIntervalIntent)
        }
    }

    /// Force l'intervalle rapide en mémorisant la valeur d'origine
    /// (UserDefaults pour survivre à un kill de l'app).
    @MainActor
    private func overrideInterval() async throws {
        let saved: UInt8
        if let pending = UserDefaults.standard.object(forKey: Self.savedIntervalKey) as? Int {
            // Override précédent interrompu : la clé contient la vraie
            // origine — la montre affiche encore l'intervalle forcé, ne
            // pas la relire comme « valeur d'origine ».
            saved = UInt8(clamping: pending)
        } else {
            // Réglage configuré capturé AVANT la lecture : readSetting
            // met à jour `settings.heartRateInterval` avec la valeur
            // réellement lue sur la montre — l'intention persistée fait
            // foi à la place.
            let configured = settings.heartRateIntervalIntent
            var origin = await currentInterval()
            if origin == Self.fastInterval, configured != Int(Self.fastInterval) {
                // « 5 min » lu = reste d'un override sans clé persistée
                // (ancienne version) : l'origine voulue est le réglage.
                log.add(.info, "Intervalle cardio : \(origin) min = reste d'override — origine \(configured) min")
                origin = UInt8(clamping: configured)
            }
            saved = origin
            UserDefaults.standard.set(Int(saved), forKey: Self.savedIntervalKey)
        }
        try await watch.perform(.setHeartRateInterval(minutes: Self.fastInterval), label: String(localized: "Quick HR"))
        log.add(.info, "HR interval forced to \(Self.fastInterval) min (was \(saved))")
    }

    /// Rend à la montre son intervalle d'origine et nettoie l'état.
    /// La clé n'est retirée qu'après un SET accepté : un échec laisse
    /// `recover()` réessayer à la prochaine connexion.
    @MainActor
    private func restoreInterval() async {
        guard let saved = UserDefaults.standard.object(forKey: Self.savedIntervalKey) as? Int else { return }
        do {
            try await watch.perform(.setHeartRateInterval(minutes: UInt8(saved)), label: String(localized: "HR interval"))
            UserDefaults.standard.removeObject(forKey: Self.savedIntervalKey)
            log.add(.info, "HR interval restored to \(saved) min")
        } catch {
            log.add(.error, "Restauration intervalle cardio : \(error.localizedDescription)")
        }
    }

    /// Nombre de records cardio stockés sur la montre.
    @MainActor
    private func heartRateRecordCount() async throws -> Int {
        let payload = try await watch.request(.getAvailableData, label: String(localized: "Available data"))
        return Int(try parseAvailableData(payload: payload).heartRate)
    }

    /// Attend qu'un nouveau record cardio apparaisse, puis fusionne et
    /// retourne le plus récent. `nil` si le délai est dépassé.
    @MainActor
    private func awaitNextHeartRateRecord(baseline: Int) async throws -> HeartRateRecord? {
        let deadline = Date().addingTimeInterval(Self.measureTimeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(Self.pollInterval) * 1_000_000_000)
            let count = try await heartRateRecordCount()
            guard count > baseline else { continue }
            let records = try await watch.fetchHeartRate()
            activity.mergeHeartRate(records)
            return records.max {
                ($0.time.date ?? .distantPast) < ($1.time.date ?? .distantPast)
            }
        }
        return nil
    }

    // MARK: - One-shot FCR

    /// FCR à la demande : intervalle forcé à 5 min → prochain relevé →
    /// FCR.
    /// Montre connectée requise (`watch.isReady`).
    @MainActor
    func measureResting() async {
        log.add(.info, "RHR: request received")
        guard watch.isReady else {
            log.add(.error, "RHR: watch not ready")
            return
        }
        guard !measuring else {
            log.add(.info, "RHR: measurement already running")
            return
        }
        guard !sessionActive else {
            log.add(.info, "RHR: cardio session active, one-shot ignored")
            return
        }
        measuring = true
        defer { measuring = false }
        // Marqueur persisté : si l'app est suspendue/tuée pendant
        // l'attente, `checkPendingFCR` retrouvera le relevé à la
        // prochaine connexion. Survit à la suspension car le defer ne
        // s'exécute pas quand le processus est figé.
        let startedAt = Date()
        UserDefaults.standard.set([
            "since": startedAt.timeIntervalSince1970,
            "expires": startedAt.addingTimeInterval(Self.pendingWindow).timeIntervalSince1970,
        ], forKey: Self.pendingFCRKey)
        do {
            try await overrideInterval()
            let baseline = try await heartRateRecordCount()
            guard let record = try await awaitNextHeartRateRecord(baseline: baseline),
                  record.bpm > 0, let date = record.time.date
            else {
                UserDefaults.standard.removeObject(forKey: Self.pendingFCRKey)
                await restoreInterval()
                log.add(.error, "RHR: no HR reading within \(Int(Self.measureTimeout / 60)) min")
                return
            }
            UserDefaults.standard.removeObject(forKey: Self.pendingFCRKey)
            await restoreInterval()
            activity.recordRestingHeartRate(Int(record.bpm), at: date)
            log.add(.event, "FCR : \(record.bpm) bpm")
        } catch {
            // Pending conservé : le relevé a pu être stocké avant
            // l'erreur — la prochaine connexion retentera.
            await restoreInterval()
            log.add(.error, "FCR : \(error.localizedDescription)")
        }
    }

    /// FCR interrompue par une suspension/kill de l'app : le relevé est
    /// peut-être déjà archivé (synchro) ou encore sur la montre — on
    /// cherche le premier échantillon cardio postérieur au départ de
    /// la mesure et on l'enregistre comme FCR.
    @MainActor
    func checkPendingFCR() async {
        guard !measuring, !sessionActive,
              let raw = UserDefaults.standard.dictionary(forKey: Self.pendingFCRKey),
              let since = raw["since"] as? TimeInterval,
              let expires = raw["expires"] as? TimeInterval
        else { return }
        guard Date().timeIntervalSince1970 < expires else {
            UserDefaults.standard.removeObject(forKey: Self.pendingFCRKey)
            log.add(.error, "RHR: interrupted measurement expired")
            return
        }
        guard watch.isReady else { return }
        do {
            // La synchro de connexion a pu déjà fusionner les records ;
            // sinon on les relit depuis la montre.
            if activity.heartRate.allSatisfy({ $0.date.timeIntervalSince1970 < since }) {
                activity.mergeHeartRate(try await watch.fetchHeartRate())
            }
            let sinceDate = Date(timeIntervalSince1970: since)
            guard let sample = activity.heartRate
                .filter({ $0.date >= sinceDate })
                .min(by: { $0.date < $1.date })
            else { return } // pas encore tombé — retentera à la prochaine connexion
            activity.recordRestingHeartRate(sample.bpm, at: sample.date)
            UserDefaults.standard.removeObject(forKey: Self.pendingFCRKey)
            log.add(.event, "RHR: \(sample.bpm) bpm (recovered interrupted reading)")
        } catch {
            log.add(.error, "FCR en attente : \(error.localizedDescription)")
        }
    }

    /// FCR automatique : dernier `end` de sommeil dans la fenêtre et pas
    /// de FCR aujourd'hui → one-shot. Appelé après la synchro d'activité.
    @MainActor
    func checkRestingMeasurement() async {
        guard watch.isReady, !measuring, !sessionActive else { return }
        if let fcr = activity.restingHeartRate, Calendar.current.isDateInToday(fcr.date) { return }
        guard let wake = activity.lastSleepEnd(),
              Date().timeIntervalSince(wake) < Self.restingWindow
        else { return }
        await measureResting()
    }

    // MARK: - Session sport

    /// Démarre une session cardio (intervalle forcé à 5 min) avec filet
    /// de sécurité à `sessionTimeout`.
    @MainActor
    func startSession() async throws {
        guard !sessionActive else { return }
        do {
            try await overrideInterval()
        } catch {
            log.add(.error, "Session cardio : \(error.localizedDescription)")
            throw error
        }
        sessionActive = true
        UserDefaults.standard.set(true, forKey: Self.sessionFlag)
        scheduleSessionTimeout()
        log.add(.event, "Cardio session started (reading every ~5 min)")
    }

    /// Termine la session et rend l'intervalle d'origine.
    @MainActor
    func stopSession() async {
        sessionWork?.cancel()
        sessionWork = nil
        guard sessionActive else { return }
        sessionActive = false
        UserDefaults.standard.set(false, forKey: Self.sessionFlag)
        await restoreInterval()
        log.add(.event, "Cardio session ended")
    }

    private func scheduleSessionTimeout() {
        sessionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.stopSession() }
        }
        sessionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.sessionTimeout, execute: work)
    }

    /// Au (re)démarrage d'une connexion : session cardio ou override
    /// d'intervalle interrompu(s) (app tuée/suspendue) — la valeur
    /// d'origine persistée est restaurée sur la montre.
    @MainActor
    func recover() async {
        let hadSession = UserDefaults.standard.bool(forKey: Self.sessionFlag)
        let hadOverride = UserDefaults.standard.object(forKey: Self.savedIntervalKey) != nil
        guard hadSession || hadOverride else { return }
        sessionWork?.cancel()
        sessionWork = nil
        sessionActive = false
        UserDefaults.standard.set(false, forKey: Self.sessionFlag)
        await restoreInterval()
    }
}
