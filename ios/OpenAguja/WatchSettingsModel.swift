import Foundation

#if canImport(OpenAgujaCore)
    import OpenAgujaCore
#endif

/// Réglages de la montre affichés dans l'app : relus depuis la montre quand
/// elle sait les renvoyer, sinon mémorisés localement (dernière valeur
/// appliquée). Chaque modification est envoyée tout de suite et confirmée
/// par l'ack de la montre.
final class WatchSettingsModel: ObservableObject {
    // Heure & langue
    @Published var time12h = false
    @Published var dateFormat: DateFormat = .ddMmYy
    @Published var language: Language = .fr
    @Published var homeCity = ""
    @Published var homeTimeZoneID = TimeZone.current.identifier

    // Affichage
    @Published var screenTime = 10
    @Published var raiseToWake = true
    @Published var analogMode: AnalogMode = .hands
    @Published var wrist: Wrist = .left

    // Affichage — réglages simples relus sur 1 octet (0x0C/0x09/0x07/0x14/0x19)
    @Published var unitsImperial = false
    @Published var watchVolume = 2
    @Published var brightness = 5
    /// 0x14 : durée de rappel brute (unité non documentée).
    @Published var snoozeValue = 10
    @Published var textSize = 1

    // Mode nuit (0x21) : couleur 1=bleu 2=vert 3=blanc, bague = graduations.
    @Published var nightModeColor: UInt8 = 1
    @Published var nightModeDial = false

    // Objectifs quotidiens relus sur 0x50 (au-delà des pas).
    @Published var calorieGoal = 400
    @Published var distanceGoalKm = 5
    @Published var sleepGoalHours = 8
    @Published var activeGoalMinutes = 30

    // Santé
    @Published var activityTracking = true
    @Published var heartRateInterval = 0
    @Published var heartRateMin = 50
    @Published var heartRateMax = 180
    @Published var heartRateAlarm = false
    @Published var inactivityEnabled = false
    @Published var inactivityThreshold = 60
    @Published var inactivityStart = ClockTime(hour: 9, minute: 0)
    @Published var inactivityEnd = ClockTime(hour: 18, minute: 0)
    /// bit0 lundi … bit6 dimanche.
    @Published var inactivityDays: UInt8 = 0x1F
    /// Switches sommeil du masque 0x90 : bit2 = suivi manuel, bit3 = auto.
    @Published var sleepTracking = false
    @Published var autoSleep = false
    /// Fenêtre de détection auto-sleep (0x58), défaut 23:00 → 09:00.
    @Published var autoSleepEnter = ClockTime(hour: 23, minute: 0)
    @Published var autoSleepExit = ClockTime(hour: 9, minute: 0)
    /// bit0 lundi … bit6 dimanche.
    @Published var autoSleepDays: UInt8 = 0x7F
    @Published var caloriesType: CaloriesType = .all
    @Published var stepGoal = 8000
    @Published var gender: Gender = .male
    @Published var age = 35
    @Published var heightCm = 175
    @Published var weightKg = 70.0

    // Notifications
    @Published var dndEnabled = false
    @Published var dndStart = ClockTime(hour: 22, minute: 0)
    @Published var dndEnd = ClockTime(hour: 7, minute: 0)
    @Published var notifyCalls = true
    @Published var notifyMissedCalls = true
    @Published var notifySms = true
    @Published var notifySocial = true
    @Published var notifyEmail = true
    @Published var notifyCalendar = true
    @Published var signaling: [SignalEvent: SignalPattern] = [:]

    @Published private(set) var loading = false
    @Published private(set) var loadedAt: Date?
    @Published var lastError: String?
    @Published private(set) var lastSuccess: String?

    /// Clés des réglages sans relecture possible, mémorisés localement.
    private enum Key {
        static let prefix = "watch.local."
        static let language = prefix + "language"
        static let homeCity = prefix + "homeCity"
        static let homeTZ = prefix + "homeTZ"
        static let hrMin = prefix + "hrMin"
        static let hrMax = prefix + "hrMax"
        static let hrAlarm = prefix + "hrAlarm"
        static let hrIntervalIntent = prefix + "hrIntervalIntent"
        static let stepGoal = prefix + "stepGoal"
        static let gender = prefix + "gender"
        static let age = prefix + "age"
        static let height = prefix + "height"
        static let weight = prefix + "weight"
        static let settingsCache = prefix + "settingsCache"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = Language.all.first { "\($0)" == defaults.string(forKey: Key.language) } ?? .fr
        homeCity = defaults.string(forKey: Key.homeCity) ?? ""
        homeTimeZoneID = defaults.string(forKey: Key.homeTZ) ?? TimeZone.current.identifier
        heartRateMin = defaults.object(forKey: Key.hrMin) as? Int ?? 50
        heartRateMax = defaults.object(forKey: Key.hrMax) as? Int ?? 180
        heartRateAlarm = defaults.bool(forKey: Key.hrAlarm)
        stepGoal = defaults.object(forKey: Key.stepGoal) as? Int ?? 8000
        gender = defaults.string(forKey: Key.gender) == "female" ? .female
            : defaults.string(forKey: Key.gender) == "other" ? .other : .male
        age = defaults.object(forKey: Key.age) as? Int ?? 35
        heightCm = defaults.object(forKey: Key.height) as? Int ?? 175
        weightKg = defaults.object(forKey: Key.weight) as? Double ?? 70
        if let data = defaults.data(forKey: Key.settingsCache),
           let cache = try? JSONDecoder().decode(SettingsCache.self, from: data) {
            restore(cache)
        }
    }

    // MARK: - Lecture

    @MainActor
    func load(from watch: ZeTimeBluetoothManager) async {
        guard watch.isReady else {
            lastError = WatchError.notConnected.localizedDescription
            return
        }
        loading = true
        defer { loading = false }
        let values = await watch.readAllSettings()
        for (kind, value) in values {
            if case .byte(let v) = value {
                applyByte(kind: kind, value: v)
            } else {
                apply(readBack: value)
            }
        }
        // Relectures sans SettingKind dédié : objectifs (0x50), profil
        // (0x30), mode nuit (0x21) — un échec n'empêche pas le reste.
        if let g = try? await watch.readGoals() {
            stepGoal = max(1000, Int(g.steps))
            calorieGoal = Int(g.calories)
            distanceGoalKm = Int(g.distanceKm)
            sleepGoalHours = Int(g.sleepHours)
            activeGoalMinutes = Int(g.activeMinutes)
        }
        if let info = try? await watch.readUserInfo() {
            gender = info.sex == 1 ? .female : info.sex == 2 ? .other : .male
            age = Int(info.age)
            heightCm = Int(info.heightCm)
            weightKg = Double(info.weightKg)
        }
        if let night = try? await watch.readNightMode() {
            nightModeColor = night.color
            nightModeDial = night.hasDial
        }
        loadedAt = Date()
        lastError = values.isEmpty ? "No setting could be re-read" : nil
        if !values.isEmpty { persistCache() }
    }

    /// Écrit l'instantané courant dans UserDefaults — affichage immédiat
    /// au prochain lancement en attendant la relecture BLE.
    private func persistCache() {
        let cache = SettingsCache(
            time12h: time12h,
            dateFormatCode: DateFormat.code(of: dateFormat),
            signaling: Dictionary(uniqueKeysWithValues: SignalEvent.all.enumerated().compactMap { index, event in
                signaling[event].map { (index, signalPatternCode(pattern: $0)) }
            }),
            dndEnabled: dndEnabled,
            dndStart: Self.clockString(dndStart),
            dndEnd: Self.clockString(dndEnd),
            analogHandsAndSteps: analogMode == .handsAndSteps,
            activityTracking: activityTracking,
            screenTime: screenTime,
            wristRight: wrist == .right,
            heartRateInterval: heartRateInterval,
            inactivityEnabled: inactivityEnabled,
            inactivityDays: Int(inactivityDays),
            inactivityThreshold: inactivityThreshold,
            inactivityStart: Self.clockString(inactivityStart),
            inactivityEnd: Self.clockString(inactivityEnd),
            caloriesAll: caloriesType == .all,
            raiseToWake: raiseToWake,
            notifyCalls: notifyCalls,
            notifyMissedCalls: notifyMissedCalls,
            notifySms: notifySms,
            notifySocial: notifySocial,
            notifyEmail: notifyEmail,
            notifyCalendar: notifyCalendar,
            sleepTracking: sleepTracking,
            autoSleep: autoSleep,
            autoSleepEnter: Self.clockString(autoSleepEnter),
            autoSleepExit: Self.clockString(autoSleepExit)
        )
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: Key.settingsCache)
        }
    }

    /// Réapplique l'instantané lu au lancement — valeurs « dernière
    /// lecture confirmée » en attendant que `load` ne les rafraîchisse.
    private func restore(_ cache: SettingsCache) {
        time12h = cache.time12h
        dateFormat = [DateFormat.yyMmDd: 1, .ddMmYy: 2, .mmDdYy: 3]
            .first { $0.value == cache.dateFormatCode }?.key ?? dateFormat
        signaling = Dictionary(uniqueKeysWithValues: cache.signaling.compactMap { index, code in
            guard SignalEvent.all.indices.contains(index),
                  let pattern = signalPatternFromCode(code: code) else { return nil }
            return (SignalEvent.all[index], pattern)
        })
        dndEnabled = cache.dndEnabled
        dndStart = Self.clockTime(cache.dndStart) ?? dndStart
        dndEnd = Self.clockTime(cache.dndEnd) ?? dndEnd
        analogMode = cache.analogHandsAndSteps ? .handsAndSteps : .hands
        activityTracking = cache.activityTracking
        screenTime = cache.screenTime
        wrist = cache.wristRight ? .right : .left
        heartRateInterval = cache.heartRateInterval
        inactivityEnabled = cache.inactivityEnabled
        inactivityDays = UInt8(clamping: cache.inactivityDays)
        inactivityThreshold = cache.inactivityThreshold
        inactivityStart = Self.clockTime(cache.inactivityStart) ?? inactivityStart
        inactivityEnd = Self.clockTime(cache.inactivityEnd) ?? inactivityEnd
        caloriesType = cache.caloriesAll ? .all : .activeOnly
        raiseToWake = cache.raiseToWake
        notifyCalls = cache.notifyCalls
        notifyMissedCalls = cache.notifyMissedCalls
        notifySms = cache.notifySms
        notifySocial = cache.notifySocial
        notifyEmail = cache.notifyEmail
        notifyCalendar = cache.notifyCalendar
        sleepTracking = cache.sleepTracking
        autoSleep = cache.autoSleep
        autoSleepEnter = Self.clockTime(cache.autoSleepEnter) ?? autoSleepEnter
        autoSleepExit = Self.clockTime(cache.autoSleepExit) ?? autoSleepExit
    }

    private static func clockString(_ t: ClockTime) -> String {
        String(format: "%02d:%02d", t.hour, t.minute)
    }

    private static func clockTime(_ s: String) -> ClockTime? {
        let parts = s.split(separator: ":").compactMap { UInt8($0) }
        guard parts.count == 2 else { return nil }
        return ClockTime(hour: parts[0], minute: parts[1])
    }

    private func apply(readBack value: SettingValue) {
        switch value {
        case .timeSurface(let date, let is12h):
            time12h = is12h
            dateFormat = [DateFormat.yyMmDd, .ddMmYy, .mmDdYy].first { DateFormat.code(of: $0) == date } ?? dateFormat
        case .signaling(let antiloss, let call, let missed, let sms, let social, let email, let calendar, let inactivity, let lowPower):
            let codes: [SignalEvent: UInt8] = [
                .antiLoss: antiloss, .call: call, .missedCall: missed, .sms: sms, .social: social,
                .email: email, .calendar: calendar, .inactivity: inactivity, .lowPower: lowPower,
            ]
            signaling = codes.compactMapValues { signalPatternFromCode(code: $0) }
        case .doNotDisturb(let enabled, let start, let end):
            dndEnabled = enabled
            dndStart = start
            dndEnd = end
        case .analogMode(let code):
            analogMode = code == 1 ? .handsAndSteps : .hands
        case .activityTracking(let enabled):
            activityTracking = enabled
        case .screenTime(let seconds):
            screenTime = Int(seconds)
        case .wrist(let code):
            wrist = code == 1 ? .right : .left
        case .heartRateInterval(let minutes):
            heartRateInterval = Int(minutes)
        case .inactivity(let enabled, let days, let threshold, let start, let end):
            inactivityEnabled = enabled
            if enabled {
                inactivityDays = days
                inactivityStart = start
                inactivityEnd = end
            }
            inactivityThreshold = Int(threshold)
        case .caloriesType(let code):
            caloriesType = code == 0 ? .activeOnly : .all
        case .displayOnMovement(let enabled):
            raiseToWake = enabled
        case .notificationSwitches(let calls, let missed, let sms, let social, let email, let calendar):
            notifyCalls = calls
            notifyMissedCalls = missed
            notifySms = sms
            notifySocial = social
            notifyEmail = email
            notifyCalendar = calendar
        case .sleepSwitches(let tracking, let autoSleep):
            sleepTracking = tracking
            self.autoSleep = autoSleep
        case .autoSleepWindow(let enter, let exit, let days):
            autoSleepEnter = enter
            autoSleepExit = exit
            autoSleepDays = days
        case .byte, .raw:
            break
        }
    }

    /// Réglages « un octet » : la valeur seule ne dit pas quel réglage —
    /// le `SettingKind` de la réponse fait la différence.
    private func applyByte(kind: SettingKind, value: UInt8) {
        switch kind {
        case .units: unitsImperial = value != 0
        case .volume: watchVolume = Int(value)
        case .brightness: brightness = Int(value)
        case .snooze: snoozeValue = Int(value)
        case .textSize: textSize = Int(value)
        default: break
        }
    }

    // MARK: - Écriture

    /// Intervalle cardio choisi par l'utilisateur dans l'app. Persisté
    /// car `heartRateInterval` reflète la valeur lue sur la montre : un
    /// override FCR/session ou une lecture peut la faire mentir.
    var heartRateIntervalIntent: Int {
        defaults.object(forKey: Key.hrIntervalIntent) as? Int ?? heartRateInterval
    }

    /// Envoie une commande et mémorise le résultat pour l'affichage.
    @MainActor
    func apply(_ command: WatchCommand, label: String, on watch: ZeTimeBluetoothManager) async {
        do {
            try await watch.perform(command, label: label)
            if case .setHeartRateInterval(let minutes) = command {
                defaults.set(Int(minutes), forKey: Key.hrIntervalIntent)
            }
            lastError = nil
            lastSuccess = label
            persistLocal()
        } catch {
            lastError = "\(label) : \(error.localizedDescription)"
        }
    }

    /// Mémorise les réglages que la montre ne sait pas relire.
    private func persistLocal() {
        defaults.set("\(language)", forKey: Key.language)
        defaults.set(homeCity, forKey: Key.homeCity)
        defaults.set(homeTimeZoneID, forKey: Key.homeTZ)
        defaults.set(heartRateMin, forKey: Key.hrMin)
        defaults.set(heartRateMax, forKey: Key.hrMax)
        defaults.set(heartRateAlarm, forKey: Key.hrAlarm)
        defaults.set(stepGoal, forKey: Key.stepGoal)
        defaults.set(gender == .female ? "female" : gender == .other ? "other" : "male", forKey: Key.gender)
        defaults.set(age, forKey: Key.age)
        defaults.set(heightCm, forKey: Key.height)
        defaults.set(weightKg, forKey: Key.weight)
    }

    // Commandes prêtes à l'emploi pour les vues.

    var timeFormatCommand: WatchCommand { .setTimeFormat(format: time12h ? .h12 : .h24) }
    var dateFormatCommand: WatchCommand { .setDateFormat(format: dateFormat) }
    var languageCommand: WatchCommand { .setLanguage(language: language) }
    var screenTimeCommand: WatchCommand { .setScreenTime(seconds: UInt16(max(10, screenTime))) }
    var raiseToWakeCommand: WatchCommand { .setDisplayOnMovement(enabled: raiseToWake) }
    var analogModeCommand: WatchCommand { .setAnalogMode(mode: analogMode) }
    var wristCommand: WatchCommand { .setWrist(wrist: wrist) }
    var activityTrackingCommand: WatchCommand { .setActivityTracking(enabled: activityTracking) }
    var heartRateIntervalCommand: WatchCommand { .setHeartRateInterval(minutes: UInt8(heartRateInterval)) }
    var heartRateLimitsCommand: WatchCommand {
        .setHeartRateLimits(max: UInt8(heartRateMax), min: UInt8(heartRateMin), alarm: heartRateAlarm)
    }

    var inactivityCommand: WatchCommand {
        .setInactivityAlert(
            enabled: inactivityEnabled,
            thresholdMin: UInt8(clamping: inactivityThreshold),
            start: inactivityStart,
            end: inactivityEnd,
            days: inactivityDays
        )
    }

    var caloriesCommand: WatchCommand { .setCaloriesType(kind: caloriesType) }
    /// Switches sommeil : index 2 = suivi, 3 = auto-sleep (masque 0x90).
    var sleepTrackingCommand: WatchCommand { .setSwitchSetting(index: 2, enabled: sleepTracking) }
    var autoSleepCommand: WatchCommand { .setSwitchSetting(index: 3, enabled: autoSleep) }
    /// `days` est envoyé à 0x7F (tous les jours) en dur : la valeur relue
    /// sur la montre ne doit pas être répercutée — le firmware renvoie 0
    /// par défaut et un apply avec days=0 désarme la détection (le check
    /// teste `window[4] & daymask`, 0 = jamais dans la fenêtre).
    var autoSleepWindowCommand: WatchCommand {
        .setAutoSleepWindow(enter: autoSleepEnter, exit: autoSleepExit, days: 0x7F)
    }
    /// L'objectif de pas est envoyé en centaines.
    var stepGoalCommand: WatchCommand { .setGoal(kind: .steps, value: UInt16(clamping: stepGoal / 100)) }
    var calorieGoalCommand: WatchCommand { .setGoal(kind: .calories, value: UInt16(clamping: calorieGoal)) }
    var distanceGoalCommand: WatchCommand { .setGoal(kind: .distance, value: UInt16(clamping: distanceGoalKm)) }
    var sleepGoalCommand: WatchCommand { .setGoal(kind: .sleep, value: UInt16(clamping: sleepGoalHours)) }
    var activeGoalCommand: WatchCommand { .setGoal(kind: .activeTime, value: UInt16(clamping: activeGoalMinutes)) }

    var unitsCommand: WatchCommand { .setUnits(imperial: unitsImperial) }
    var watchVolumeCommand: WatchCommand { .setWatchVolume(level: UInt8(clamping: watchVolume)) }
    var brightnessCommand: WatchCommand { .setBrightness(level: UInt8(clamping: brightness)) }
    var snoozeCommand: WatchCommand { .setSnooze(value: UInt8(clamping: snoozeValue)) }
    var textSizeCommand: WatchCommand { .setTextSize(level: UInt8(clamping: textSize)) }
    var nightModeCommand: WatchCommand { .setNightMode(color: nightModeColor, hasDial: nightModeDial) }
    var userInfoCommand: WatchCommand {
        .setUserInfo(gender: gender, age: UInt8(clamping: age), heightCm: UInt8(clamping: heightCm), weightKg: Float(weightKg))
    }

    var dndCommand: WatchCommand { .setDoNotDisturb(enabled: dndEnabled, start: dndStart, end: dndEnd) }

    /// Bit du masque 0x90 de chaque catégorie de notification.
    static let notificationSwitchIndex: [(label: String, index: UInt8, keyPath: ReferenceWritableKeyPath<WatchSettingsModel, Bool>)] = [
        (String(localized: "Calls"), 4, \.notifyCalls),
        (String(localized: "Missed calls"), 5, \.notifyMissedCalls),
        ("SMS", 6, \.notifySms),
        (String(localized: "Social networks"), 7, \.notifySocial),
        (String(localized: "E-mails"), 8, \.notifyEmail),
        (String(localized: "Calendar"), 9, \.notifyCalendar),
    ]
}

extension Language {
    static let all: [Language] = [
        .fr, .en, .de, .es, .it, .nl, .pt, .pl, .ru, .cs, .sv, .el, .he, .ar, .ja, .ko, .th, .zhCn, .zhTw,
    ]

    var label: String {
        switch self {
        case .en: return String(localized: "English")
        case .zhCn: return "简体中文"
        case .zhTw: return "繁體中文"
        case .ko: return "한국어"
        case .th: return "ไทย"
        case .ja: return "日本語"
        case .fr: return String(localized: "French")
        case .es: return String(localized: "Español")
        case .de: return String(localized: "Deutsch")
        case .it: return String(localized: "Italiano")
        case .pl: return String(localized: "Polski")
        case .pt: return String(localized: "Portuguese")
        case .ru: return "Русский"
        case .nl: return String(localized: "Nederlands")
        case .ar: return "العربية"
        case .el: return "Ελληνικά"
        case .he: return "עברית"
        case .sv: return String(localized: "Svenska")
        case .cs: return "Čeština"
        }
    }
}

extension DateFormat {
    /// Code renvoyé par la relecture 0x05 (identique au code envoyé).
    static func code(of format: DateFormat) -> UInt8 {
        switch format {
        case .yyMmDd: return 1
        case .ddMmYy: return 2
        case .mmDdYy: return 3
        }
    }

    var label: String {
        switch self {
        case .yyMmDd: return String(localized: "YY/MM/DD")
        case .ddMmYy: return String(localized: "DD/MM/YY")
        case .mmDdYy: return String(localized: "MM/DD/YY")
        }
    }
}

extension SignalEvent {
    static let all: [SignalEvent] = [.call, .missedCall, .sms, .social, .email, .calendar, .inactivity, .lowPower, .antiLoss]

    var label: String {
        switch self {
        case .antiLoss: return String(localized: "Connection lost")
        case .call: return String(localized: "Call")
        case .missedCall: return String(localized: "Missed call")
        case .sms: return "SMS"
        case .social: return String(localized: "Social networks")
        case .email: return String(localized: "E-mail")
        case .calendar: return String(localized: "Calendar")
        case .inactivity: return String(localized: "Inactivity")
        case .lowPower: return String(localized: "Low battery")
        }
    }
}

extension SignalPattern {
    static let all: [SignalPattern] = [
        .none, .vibrateOnce, .vibrateTwice, .vibrate, .beepOnce, .beepTwice, .beep, .vibrateBeepOnce, .vibrateBeep,
    ]

    var label: String {
        switch self {
        case .vibrateOnce: return String(localized: "Vibration ×1")
        case .vibrateTwice: return String(localized: "Vibration ×2")
        case .vibrate: return String(localized: "Long vibration")
        case .beepOnce: return String(localized: "Beep ×1")
        case .beepTwice: return String(localized: "Beep ×2")
        case .beep: return String(localized: "Long beep")
        case .vibrateBeepOnce: return String(localized: "Vibration + beep")
        case .vibrateBeep: return String(localized: "Vibration + long beeps")
        case .none: return String(localized: "None")
        }
    }
}

/// Instantané JSON des réglages relus sur la montre — affichage immédiat
/// au lancement en attendant la relecture BLE. La montre reste la source
/// de vérité : `load` écrase ces valeurs à chaque lecture.
private struct SettingsCache: Codable {
    var time12h: Bool
    var dateFormatCode: UInt8
    /// index dans `SignalEvent.all` → code `signalPatternCode`.
    var signaling: [Int: UInt8]
    var dndEnabled: Bool
    var dndStart: String
    var dndEnd: String
    var analogHandsAndSteps: Bool
    var activityTracking: Bool
    var screenTime: Int
    var wristRight: Bool
    var heartRateInterval: Int
    var inactivityEnabled: Bool
    var inactivityDays: Int
    var inactivityThreshold: Int
    var inactivityStart: String
    var inactivityEnd: String
    var caloriesAll: Bool
    var raiseToWake: Bool
    var notifyCalls: Bool
    var notifyMissedCalls: Bool
    var notifySms: Bool
    var notifySocial: Bool
    var notifyEmail: Bool
    var notifyCalendar: Bool
    var sleepTracking: Bool
    var autoSleep: Bool
    var autoSleepEnter: String
    var autoSleepExit: String
}
