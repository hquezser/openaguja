import Foundation

#if canImport(OpenAgujaCore)
    import OpenAgujaCore
#endif

/// Historique d'activité récupéré de la montre (pas, sommeil, cardio),
/// dédoublonné par horodatage et persisté dans Application Support.
final class ActivityStore: ObservableObject {
    struct StepSample: Codable, Hashable {
        let date: Date
        let steps: Int
        let calories: Int
        let distanceM: Int
        let activeMin: Int
    }

    struct SleepSample: Codable, Hashable {
        let date: Date
        /// 0 profond, 1 léger, autre = code brut.
        let kind: Int
    }

    struct HeartRateSample: Codable, Hashable {
        let date: Date
        let bpm: Int
    }

    struct BatterySample: Codable, Hashable {
        let date: Date
        let level: Int
    }

    struct DayTotal: Identifiable {
        let day: Date
        let steps: Int
        let calories: Int
        let distanceM: Int
        let activeMin: Int
        var id: Date { day }
    }

    private struct Archive: Codable {
        var steps: [StepSample] = []
        var sleep: [SleepSample] = []
        var heartRate: [HeartRateSample] = []
        var restingHeartRate: HeartRateSample?
        var battery: [BatterySample] = []
        var lastSync: Date?
    }

    @Published private(set) var steps: [StepSample] = []
    @Published private(set) var sleep: [SleepSample] = []
    @Published private(set) var heartRate: [HeartRateSample] = []
    /// FCR mesurée par le one-shot `HeartRateService` (nil = jamais faite).
    @Published private(set) var restingHeartRate: HeartRateSample?
    /// Historique batterie (~240 relevés ≈ 30 jours à une synchro/3 h).
    @Published private(set) var batteryHistory: [BatterySample] = []
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    @Published var lastError: String?
    /// Efface les données de la montre après une synchro réussie (option
    /// Gadgetbridge « ne pas garder les données sur la montre »).
    @Published var deleteAfterSync: Bool {
        didSet { UserDefaults.standard.set(deleteAfterSync, forKey: "activity.deleteAfterSync") }
    }

    private let fileURL: URL?
    private let log: LogStore

    init(log: LogStore, fileURL: URL? = ActivityStore.defaultFileURL()) {
        self.log = log
        self.fileURL = fileURL
        deleteAfterSync = UserDefaults.standard.bool(forKey: "activity.deleteAfterSync")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let archive = try? JSONDecoder().decode(Archive.self, from: data)
        {
            steps = archive.steps
            sleep = archive.sleep
            heartRate = archive.heartRate
            restingHeartRate = archive.restingHeartRate
            batteryHistory = archive.battery
            lastSync = archive.lastSync
        }
    }

    static func defaultFileURL() -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("zetime-activity.json")
    }

    @MainActor
    func sync(from watch: ZeTimeBluetoothManager) async {
        guard watch.isReady else {
            lastError = WatchError.notConnected.localizedDescription
            return
        }
        syncing = true
        defer { syncing = false }
        do {
            let dump = try await watch.fetchActivity()
            merge(dump)
            lastSync = Date()
            save()
            lastError = nil
            log.add(.info, "Activity: \(dump.steps.count) steps, \(dump.sleep.count) sleep, \(dump.heartRate.count) HR")
            if deleteAfterSync, !dump.complete {
                log.add(.error, "Incomplete sync: data left on the watch")
            }
            if deleteAfterSync, dump.complete {
                if !dump.steps.isEmpty { try await watch.perform(.deleteStepData, label: String(localized: "Clear steps")) }
                if !dump.sleep.isEmpty { try await watch.perform(.deleteSleepData, label: String(localized: "Clear sleep")) }
                if !dump.heartRate.isEmpty { try await watch.perform(.deleteHeartRateData, label: String(localized: "Clear HR")) }
            }
            if let data = try? await watch.request(.getBattery, label: String(localized: "Battery")), let level = data.first {
                recordBattery(Int(level))
            }
        } catch {
            lastError = error.localizedDescription
            log.add(.error, "Activity sync: \(error.localizedDescription)")
        }
    }

    func merge(_ dump: ZeTimeBluetoothManager.ActivityDump) {
        let newSteps = dump.steps.compactMap { r -> StepSample? in
            guard let date = r.time.date else { return nil }
            return StepSample(date: date, steps: Int(r.steps), calories: Int(r.calories), distanceM: Int(r.distanceM), activeMin: Int(r.activeMin))
        }
        let newSleep = dump.sleep.compactMap { r -> SleepSample? in
            guard let date = r.time.date else { return nil }
            let kind: Int
            switch r.kind {
            case .deep: kind = 0
            case .light: kind = 1
            case .begin: kind = 10
            case .end: kind = 11
            case .unknown(let code): kind = Int(code)
            }
            return SleepSample(date: date, kind: kind)
        }
        let newHR = dump.heartRate.compactMap { r -> HeartRateSample? in
            guard let date = r.time.date, r.bpm > 0 else { return nil }
            return HeartRateSample(date: date, bpm: Int(r.bpm))
        }
        steps = Self.merged(steps, newSteps, key: \.date)
        sleep = Self.merged(sleep, newSleep, key: \.date)
        heartRate = Self.merged(heartRate, newHR, key: \.date)
    }

    /// Fusionne des records cardio seuls (lecture cardio-only).
    func mergeHeartRate(_ records: [HeartRateRecord]) {
        let samples = records.compactMap { r -> HeartRateSample? in
            guard let date = r.time.date, r.bpm > 0 else { return nil }
            return HeartRateSample(date: date, bpm: Int(r.bpm))
        }
        heartRate = Self.merged(heartRate, samples, key: \.date)
        save()
    }

    /// Fusion par horodatage : la nouvelle valeur remplace l'ancienne.
    static func merged<T>(_ old: [T], _ new: [T], key: KeyPath<T, Date>) -> [T] {
        var byDate: [Date: T] = [:]
        for item in old + new {
            byDate[item[keyPath: key]] = item
        }
        return byDate.values.sorted { $0[keyPath: key] < $1[keyPath: key] }
    }

    /// Totaux par jour, du plus ancien au plus récent, sur `days` jours.
    func dailyTotals(days: Int = 7, now: Date = Date()) -> [DayTotal] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: day)
            else { return nil }
            let samples = steps.filter { $0.date >= day && $0.date < next }
            return DayTotal(
                day: day,
                steps: samples.reduce(0) { $0 + $1.steps },
                calories: samples.reduce(0) { $0 + $1.calories },
                distanceM: samples.reduce(0) { $0 + $1.distanceM },
                activeMin: samples.reduce(0) { $0 + $1.activeMin }
            )
        }
    }

    /// Totaux d'une journée précise (zéros si aucune donnée ce jour-là).
    func dayTotal(on day: Date) -> DayTotal {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else {
            return DayTotal(day: start, steps: 0, calories: 0, distanceM: 0, activeMin: 0)
        }
        let samples = steps.filter { $0.date >= start && $0.date < next }
        return DayTotal(
            day: start,
            steps: samples.reduce(0) { $0 + $1.steps },
            calories: samples.reduce(0) { $0 + $1.calories },
            distanceM: samples.reduce(0) { $0 + $1.distanceM },
            activeMin: samples.reduce(0) { $0 + $1.activeMin }
        )
    }

    /// Jours avec au moins une donnée, du plus ancien au plus récent —
    /// borne le sélecteur de `DayDetailView`.
    func daysWithData() -> [Date] {
        let calendar = Calendar.current
        var days = Set<Date>()
        for s in steps { days.insert(calendar.startOfDay(for: s.date)) }
        for s in sleep { days.insert(calendar.startOfDay(for: s.date)) }
        for s in heartRate { days.insert(calendar.startOfDay(for: s.date)) }
        return days.sorted()
    }

    func heartRate(on day: Date) -> [HeartRateSample] {
        let calendar = Calendar.current
        return heartRate.filter { calendar.isDate($0.date, inSameDayAs: day) }
    }

    /// Nuit se terminant le jour donné (de 18 h la veille à 12 h) :
    /// minutes de sommeil profond, léger et éveillé, à partir des
    /// transitions. `nil` sans au moins deux marqueurs.
    func sleepSummary(endingOn day: Date) -> (deep: Int, light: Int, awake: Int)? {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .hour, value: -6, to: calendar.startOfDay(for: day))!
        let end = calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: day))!
        let samples = sleep.filter { $0.date >= start && $0.date < end }
        guard samples.count > 1 else { return nil }
        var deep = 0
        var light = 0
        var awake = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            let minutes = Int(b.date.timeIntervalSince(a.date) / 60)
            guard minutes < 180 else { continue } // trou de données
            // Kinds stockés (voir `merge`) : 0 = profond, 1 = léger,
            // 2/3/4 = éveillé (variantes protocole brutes), 10/11 =
            // marqueurs début/fin, autres codes bruts ignorés.
            if a.kind == 0 { deep += minutes }
            else if a.kind == 1 { light += minutes }
            else if (2...4).contains(a.kind) { awake += minutes }
        }
        return (deep, light, awake)
    }

    /// Export CSV (pas puis cardio) pour la feuille de partage.
    func exportCSV() -> URL? {
        let f = ISO8601DateFormatter()
        var lines = ["type,date,value,calories,distance_m,active_minutes"]
        lines += steps.map { "steps,\(f.string(from: $0.date)),\($0.steps),\($0.calories),\($0.distanceM),\($0.activeMin)" }
        lines += heartRate.map { "heart_rate,\(f.string(from: $0.date)),\($0.bpm),,," }
        lines += sleep.map { "sleep,\(f.string(from: $0.date)),\($0.kind),,," }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zetime-activity.csv")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// FCR mesurée par le one-shot : échantillon daté du relevé + ajout
    /// à la série cardio, puis persistance.
    func recordRestingHeartRate(_ bpm: Int, at date: Date = Date()) {
        let sample = HeartRateSample(date: date, bpm: bpm)
        restingHeartRate = sample
        heartRate = Self.merged(heartRate, [sample], key: \.date)
        save()
    }

    /// Relevé batterie daté, historique plafonné à 240 entrées.
    func recordBattery(_ level: Int) {
        batteryHistory.append(BatterySample(date: Date(), level: level))
        if batteryHistory.count > 240 {
            batteryHistory.removeFirst(batteryHistory.count - 240)
        }
        save()
    }

    /// Fin de sommeil la plus récente : marqueur `end` (kind 11) si
    /// présent, sinon dernier segment de sommeil des ~14 dernières heures.
    func lastSleepEnd() -> Date? {
        if let last = sleep.filter({ $0.kind == 11 }).map(\.date).max() {
            return last
        }
        let nightStart = Calendar.current.date(byAdding: .hour, value: -14, to: Date()) ?? .distantPast
        return sleep.filter { $0.date > nightStart }.map(\.date).max()
    }

    private func save() {
        guard let fileURL else { return }
        let archive = Archive(
            steps: steps, sleep: sleep, heartRate: heartRate,
            restingHeartRate: restingHeartRate, battery: batteryHistory,
            lastSync: lastSync
        )
        if let data = try? JSONEncoder().encode(archive) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
