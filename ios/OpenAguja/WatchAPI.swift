import Foundation

#if canImport(OpenAgujaCore)
    import OpenAgujaCore
#endif

/// Opérations de haut niveau au-dessus des échanges requête/réponse.
extension ZeTimeBluetoothManager {
    @MainActor
    func readSetting(_ kind: SettingKind) async throws -> SettingValue {
        let payload = try await request(.readSetting(setting: kind), label: String(localized: "Reading \(kind)"))
        return try parseSetting(setting: kind, payload: payload)
    }

    /// Lit tous les réglages ; un réglage illisible est journalisé et omis.
    @MainActor
    func readAllSettings() async -> [SettingKind: SettingValue] {
        var values: [SettingKind: SettingValue] = [:]
        let kinds: [SettingKind] = [
            .timeSurface, .signaling, .doNotDisturb, .analogMode, .activityTracking, .screenTime,
            .wrist, .heartRateInterval, .inactivity, .caloriesType, .displayOnMovement,
            .notificationSwitches, .sleepSwitches, .autoSleepWindow,
            .units, .volume, .brightness, .snooze, .textSize,
        ]
        for kind in kinds {
            do {
                values[kind] = try await readSetting(kind)
            } catch {
                log.add(.error, "Setting \(kind): \(error.localizedDescription)")
            }
        }
        return values
    }

    @MainActor
    func readButtons() async throws -> [ButtonFunction] {
        parseButtonFunctions(payload: try await request(.getButtonFunctions, label: String(localized: "Reading buttons")))
    }

    /// Relit la table 0x2E dans le cache utilisé par la télémétrie
    /// `button` (après un remap fait depuis cette app ou ailleurs).
    @MainActor
    func refreshButtonFunctions() async {
        buttonFunctions = (try? await readButtons()) ?? buttonFunctions
    }

    /// Alarmes : nombre via 0x91, puis 0x97 diffuse une trame par alarme.
    @MainActor
    func readAlarms() async throws -> [AlarmEntry] {
        let countPayload = try await request(.getAlarmCount, label: String(localized: "Alarm count"))
        let count = Int(countPayload.first ?? 0)
        guard count > 0 else { return [] }
        var seen = 0
        let collected = try await collect(.getAlarms, label: String(localized: "Alarms"), idleTimeout: 6) { _ in
            seen += 1
            return seen >= count
        }
        guard collected.complete else {
            throw WatchError.invalid("Alarms: \(collected.payloads.count) received of \(count)")
        }
        return collected.payloads.compactMap { try? parseAlarm(payload: $0) }.sorted { $0.slot < $1.slot }
    }

    struct ActivityDump {
        var steps: [StepRecord] = []
        var sleep: [SleepRecord] = []
        var heartRate: [HeartRateRecord] = []
        /// Faux si une collecte s'est arrêtée avant le dernier
        /// enregistrement annoncé : ne rien effacer sur la montre alors.
        var complete = true
    }

    /// Récupère tous les enregistrements stockés sur la montre (pas,
    /// sommeil, cardio). Un enregistrement porte son index : la collecte
    /// s'arrête quand l'index atteint le nombre annoncé (comme le CLI/GB).
    @MainActor
    func fetchActivity() async throws -> ActivityDump {
        let available = try parseAvailableData(payload: await request(.getAvailableData, label: String(localized: "Available data")))
        log.add(.info, "Available: \(available.steps) steps, \(available.sleep) sleep, \(available.heartRate) HR")
        var dump = ActivityDump()
        if available.steps > 0 {
            let frames = try await collect(.getStepData, label: String(localized: "Steps")) { p in
                ((try? parseStepRecord(payload: p))?.index ?? .max) >= available.steps
            }
            dump.steps = frames.payloads.compactMap { try? parseStepRecord(payload: $0) }
            dump.complete = dump.complete && frames.complete
        }
        if available.sleep > 0 {
            let frames = try await collect(.getSleepData, label: String(localized: "Sleep")) { p in
                ((try? parseSleepRecord(payload: p))?.index ?? .max) >= available.sleep
            }
            dump.sleep = frames.payloads.compactMap { try? parseSleepRecord(payload: $0) }
            dump.complete = dump.complete && frames.complete
        }
        if available.heartRate > 0 {
            let frames = try await collect(.getHeartRateData, label: String(localized: "Cardio")) { p in
                ((try? parseHeartRateRecords(payload: p))?.last?.index ?? .max) >= available.heartRate
            }
            dump.heartRate = frames.payloads.flatMap { (try? parseHeartRateRecords(payload: $0)) ?? [] }
            dump.complete = dump.complete && frames.complete
        }
        return dump
    }

    /// Cardio seul : saute les centaines de records de pas/sommeil —
    /// ~10 records au lieu de ~300 pour la FCR et les sessions.
    @MainActor
    func fetchHeartRate() async throws -> [HeartRateRecord] {
        let available = try parseAvailableData(payload: await request(.getAvailableData, label: String(localized: "Available data")))
        guard available.heartRate > 0 else { return [] }
        let frames = try await collect(.getHeartRateData, label: String(localized: "Cardio")) { p in
            ((try? parseHeartRateRecords(payload: p))?.last?.index ?? .max) >= available.heartRate
        }
        return frames.payloads.flatMap { (try? parseHeartRateRecords(payload: $0)) ?? [] }
    }

    /// Réponses rapides stockées sur la montre : métadonnées 0xDA puis
    /// une trame 0xDB par entrée. Chaque SET réécrit la zone flash
    /// 0xA2000 — les opérations d'écriture sont dans `QuickRepliesView`.
    @MainActor
    func readQuickReplies() async throws -> [QuickReply] {
        let metaPayload = try await request(.getQuickReplies, label: String(localized: "Quick replies"))
        let meta = try parseQuickReplyMeta(payload: metaPayload)
        guard !meta.crcs.isEmpty else { return [] }
        var seen = 0
        let collected = try await collect(.getQuickReply(crc: nil), label: String(localized: "Quick replies"), idleTimeout: 10) { _ in
            seen += 1
            return seen >= meta.crcs.count
        }
        guard collected.complete else {
            throw WatchError.invalid("Replies: \(collected.payloads.count) received of \(meta.crcs.count)")
        }
        return collected.payloads.compactMap { try? parseQuickReply(payload: $0) }.sorted { $0.index < $1.index }
    }

    /// Objectifs quotidiens relus sur la montre (0x50) — 5 valeurs.
    @MainActor
    func readGoals() async throws -> Goals {
        try parseGoals(payload: await request(.getGoals, label: String(localized: "Goals")))
    }

    /// Profil utilisateur relu sur la montre (0x30).
    @MainActor
    func readUserInfo() async throws -> UserInfo {
        try parseUserInfo(payload: await request(.getUserInfo, label: String(localized: "Profile")))
    }

    /// Configuration du mode nuit (0x21) : couleur + bague de graduations.
    @MainActor
    func readNightMode() async throws -> NightMode {
        try parseNightMode(payload: await request(.getNightMode, label: String(localized: "Night mode")))
    }

    /// Fuseau secondaire (ligne « ville » des cadrans numériques).
    @MainActor
    func setHomeCity(_ timeZone: TimeZone, city: String) async throws {
        let minutes = Int16(timeZone.secondsFromGMT() / 60)
        try await perform(.setTimezone(offsetMinutes: minutes, city: city), label: String(localized: "Second time zone"))
    }
}

extension WatchDateTime {
    /// Date locale (la montre stocke l'heure murale, sans fuseau).
    var date: Date? {
        var c = DateComponents()
        c.year = Int(year)
        c.month = Int(month)
        c.day = Int(day)
        c.hour = Int(hour)
        c.minute = Int(minute)
        c.second = Int(second)
        return Calendar.current.date(from: c)
    }

    init(date: Date) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        self.init(
            year: UInt16(c.year ?? 2000),
            month: UInt8(c.month ?? 1),
            day: UInt8(c.day ?? 1),
            hour: UInt8(c.hour ?? 0),
            minute: UInt8(c.minute ?? 0),
            second: UInt8(c.second ?? 0)
        )
    }
}

extension ClockTime {
    var date: Date {
        Calendar.current.date(from: DateComponents(hour: Int(hour), minute: Int(minute))) ?? Date()
    }

    init(date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        self.init(hour: UInt8(c.hour ?? 0), minute: UInt8(c.minute ?? 0))
    }

    var label: String { String(format: "%02d:%02d", hour, minute) }
}
