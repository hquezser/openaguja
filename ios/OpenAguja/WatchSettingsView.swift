import SwiftUI
import OpenAgujaCore

/// Réglages de la montre : chaque contrôle envoie sa commande dès qu'il
/// change (confirmée par l'ack de la montre, erreur affichée sinon).
struct WatchSettingsView: View {
    @EnvironmentObject private var bluetooth: ZeTimeBluetoothManager
    @EnvironmentObject private var model: WatchSettingsModel
    /// Profil énergétique (clé partagée avec Réglages → Capteurs).
    @AppStorage(EnergyProfile.storageKey) private var energyProfileRaw = EnergyProfile.balanced.rawValue

    var body: some View {
        Form {
            Section {
                NotConnectedHint()
                StatusFooter(error: model.lastError, success: model.lastSuccess)
                if let loaded = model.loadedAt {
                    Text("Re-read on watch \(loaded.relative)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            timeSection
            displaySection
            nightModeSection
            healthSection
            notificationsSection
        }
        .disabled(model.loading)
        .navigationTitle("Watch settings")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if model.loading {
                    ProgressView()
                } else {
                    Button {
                        Task { await model.load(from: bluetooth) }
                    } label: {
                        Label("Re-read", systemImage: "arrow.clockwise")
                    }
                    .disabled(!bluetooth.isReady)
                }
            }
        }
        .task {
            if model.loadedAt == nil, bluetooth.isReady {
                await model.load(from: bluetooth)
            }
        }
    }

    // MARK: - Sections

    private var timeSection: some View {
        Section {
            Picker("Time format", selection: bind(\.time12h, "Time format") { $0.timeFormatCommand }) {
                Text("24 h").tag(false)
                Text("12 h").tag(true)
            }
            Picker("Date format", selection: bind(\.dateFormat, "Date format") { $0.dateFormatCommand }) {
                ForEach([DateFormat.ddMmYy, .mmDdYy, .yyMmDd], id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Language", selection: bind(\.language, "Language") { $0.languageCommand }) {
                ForEach(Language.all, id: \.self) { Text($0.label).tag($0) }
            }
            NavigationLink {
                HomeCityView()
            } label: {
                LabeledContent("Second time zone", value: model.homeCity.isEmpty ? "—" : model.homeCity)
            }
        } header: {
            Text("Time & language")
        } footer: {
            Text("Time syncs automatically on each connection and on each phone time-zone change.")
        }
    }

    private var displaySection: some View {
        Section("Display") {
            Stepper(value: bind(\.screenTime, "Display duration") { $0.screenTimeCommand }, in: 10...60, step: 5) {
                LabeledContent("Display duration", value: "\(model.screenTime) s")
            }
            Toggle("Raise to wake", isOn: bind(\.raiseToWake, "Allumage au mouvement") { $0.raiseToWakeCommand })
            Picker("Hands", selection: bind(\.analogMode, "Hand mode") { $0.analogModeCommand }) {
                Text("Time").tag(AnalogMode.hands)
                Text("Time + step goal").tag(AnalogMode.handsAndSteps)
            }
            Picker("Wrist", selection: bind(\.wrist, "Wrist") { $0.wristCommand }) {
                Text("Left").tag(Wrist.left)
                Text("Right").tag(Wrist.right)
            }
            Picker("Units", selection: bind(\.unitsImperial, "Units") { $0.unitsCommand }) {
                Text("Metric").tag(false)
                Text("Imperial").tag(true)
            }
            Stepper(value: bind(\.watchVolume, "Watch volume") { $0.watchVolumeCommand }, in: 0...10) {
                LabeledContent("Volume", value: "\(model.watchVolume)")
            }
            Stepper(value: bind(\.brightness, "Brightness") { $0.brightnessCommand }, in: 0...10) {
                LabeledContent("Brightness", value: "\(model.brightness)")
            }
            Stepper(value: bind(\.textSize, "Text size") { $0.textSizeCommand }, in: 0...3) {
                LabeledContent("Notification text", value: "\(model.textSize)")
            }
            Stepper(value: bind(\.snoozeValue, "Rappel") { $0.snoozeCommand }, in: 0...30) {
                LabeledContent("Snooze duration", value: "\(model.snoozeValue)")
            }
        }
    }

    /// Mode nuit (0x21) : appui sur la couronne → écran coloré ~10 s.
    private var nightModeSection: some View {
        Section {
            Picker("Color", selection: bind(\.nightModeColor, "Night mode") { $0.nightModeCommand }) {
                Text("Blue").tag(UInt8(1))
                Text("Green").tag(UInt8(2))
                Text("White").tag(UInt8(3))
            }
            Toggle("Tick ring", isOn: bind(\.nightModeDial, "Night mode") { $0.nightModeCommand })
        } header: {
            Text("Night mode")
        } footer: {
            Text("Press the crown to show the colored night screen.")
        }
    }

    private var healthSection: some View {
        Section {
            Toggle("Activity tracking", isOn: bind(\.activityTracking, "Activity tracking") { $0.activityTrackingCommand })
            Stepper(value: bind(\.stepGoal, "Step goal") { $0.stepGoalCommand }, in: 1000...30000, step: 500) {
                LabeledContent("Step goal", value: model.stepGoal.formatted())
            }
            Stepper(value: bind(\.calorieGoal, "Calorie goal") { $0.calorieGoalCommand }, in: 100...2000, step: 50) {
                LabeledContent("Calories", value: "\(model.calorieGoal) kcal")
            }
            Stepper(value: bind(\.distanceGoalKm, "Distance goal") { $0.distanceGoalCommand }, in: 1...100, step: 1) {
                LabeledContent("Distance", value: "\(model.distanceGoalKm) km")
            }
            Stepper(value: bind(\.sleepGoalHours, "Sleep goal") { $0.sleepGoalCommand }, in: 4...12, step: 1) {
                LabeledContent("Sleep", value: "\(model.sleepGoalHours) h")
            }
            Stepper(value: bind(\.activeGoalMinutes, "Activity goal") { $0.activeGoalCommand }, in: 10...240, step: 10) {
                LabeledContent("Activity", value: "\(model.activeGoalMinutes) min")
            }
            Picker("Calories", selection: bind(\.caloriesType, "Type de calories") { $0.caloriesCommand }) {
                Text("All").tag(CaloriesType.all)
                Text("Active only").tag(CaloriesType.activeOnly)
            }
            LabeledContent("Auto HR measure", value: cardioIntervalLabel)
            NavigationLink("HR alert") { HeartRateLimitsView() }
            NavigationLink("Inactivity alert") { InactivityView() }
            NavigationLink("Automatic sleep") { AutoSleepView() }
            NavigationLink("Profile (calorie calc)") { UserProfileView() }
        } header: {
            Text("Health")
        } footer: {
            Text("HR frequency and sync cadence: a single setting in Settings → Sensors & battery (Economy / Balanced / Precise).")
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle("Do not disturb", isOn: bind(\.dndEnabled, "Do not disturb") { $0.dndCommand })
            if model.dndEnabled {
                DatePicker("Start", selection: clockBinding(\.dndStart, "Do not disturb") { $0.dndCommand }, displayedComponents: .hourAndMinute)
                DatePicker("End", selection: clockBinding(\.dndEnd, "Do not disturb") { $0.dndCommand }, displayedComponents: .hourAndMinute)
            }
            ForEach(WatchSettingsModel.notificationSwitchIndex, id: \.index) { item in
                Toggle(item.label, isOn: bind(item.keyPath, "Notifications \(item.label)") { m in
                    .setSwitchSetting(index: item.index, enabled: m[keyPath: item.keyPath])
                })
            }
            NavigationLink("Per-event vibrations") { SignalingView() }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Notifications from other iPhone apps go through system Bluetooth (ANCS), not this app.")
        }
    }

    /// Intervalle cardio affiché en lecture seule : la valeur vient du
    /// profil énergétique (Réglages → Capteurs), pas d'un second réglage.
    private var cardioIntervalLabel: String {
        let minutes = EnergyProfile(rawValue: energyProfileRaw)?.heartRateMinutes ?? EnergyProfile.balanced.heartRateMinutes
        return String(localized: "Every \(minutes) min")
    }

    // MARK: - Liaisons

    /// Binding qui modifie le modèle puis envoie la commande associée.
    private func bind<T>(
        _ keyPath: ReferenceWritableKeyPath<WatchSettingsModel, T>,
        _ label: String,
        command: @escaping (WatchSettingsModel) -> WatchCommand
    ) -> Binding<T> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { value in
                model[keyPath: keyPath] = value
                let cmd = command(model)
                Task { await model.apply(cmd, label: label, on: bluetooth) }
            }
        )
    }

    private func clockBinding(
        _ keyPath: ReferenceWritableKeyPath<WatchSettingsModel, ClockTime>,
        _ label: String,
        command: @escaping (WatchSettingsModel) -> WatchCommand
    ) -> Binding<Date> {
        Binding(
            get: { model[keyPath: keyPath].date },
            set: { date in
                model[keyPath: keyPath] = ClockTime(date: date)
                let cmd = command(model)
                Task { await model.apply(cmd, label: label, on: bluetooth) }
            }
        )
    }
}

// MARK: - Sous-écrans

struct HomeCityView: View {
    @EnvironmentObject private var bluetooth: ZeTimeBluetoothManager
    @EnvironmentObject private var model: WatchSettingsModel
    @State private var search = ""

    private var zones: [String] {
        let all = TimeZone.knownTimeZoneIdentifiers
        guard !search.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Form {
            Section {
                TextField("Display name (e.g. GENEVA)", text: $model.homeCity)
                    .textInputAutocapitalization(.characters)
                LabeledContent("Time zone", value: model.homeTimeZoneID)
                Button("Send to watch") {
                    Task { await send() }
                }
                .disabled(!bluetooth.isReady || model.homeCity.isEmpty)
                StatusFooter(error: model.lastError, success: model.lastSuccess)
            } footer: {
                Text("“City” line of digital faces. Resend after a DST change in this zone.")
            }
            Section("Choose time zone") {
                ForEach(zones, id: \.self) { id in
                    Button {
                        model.homeTimeZoneID = id
                        if model.homeCity.isEmpty {
                            model.homeCity = id.split(separator: "/").last.map { String($0).replacingOccurrences(of: "_", with: " ") } ?? id
                        }
                    } label: {
                        HStack {
                            Text(id)
                            Spacer()
                            if id == model.homeTimeZoneID {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .searchable(text: $search, prompt: "Paris, New_York, Tokyo…")
        .disabled(model.loading)
        .navigationTitle("Second time zone")
    }

    @MainActor
    private func send() async {
        guard let zone = TimeZone(identifier: model.homeTimeZoneID) else { return }
        let city = WeatherService.watchLabel(model.homeCity)
        await model.apply(
            .setTimezone(offsetMinutes: Int16(zone.secondsFromGMT() / 60), city: city),
            label: String(localized: "Second time zone"),
            on: bluetooth
        )
    }
}

struct HeartRateLimitsView: View {
    @EnvironmentObject private var bluetooth: ZeTimeBluetoothManager
    @EnvironmentObject private var model: WatchSettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Alert", isOn: $model.heartRateAlarm)
                Stepper("Minimum: \(model.heartRateMin) bpm", value: $model.heartRateMin, in: 30...120, step: 5)
                Stepper("Maximum: \(model.heartRateMax) bpm", value: $model.heartRateMax, in: 100...220, step: 5)
                Button("Apply") {
                    Task { await model.apply(model.heartRateLimitsCommand, label: String(localized: "HR alert"), on: bluetooth) }
                }
                .disabled(!bluetooth.isReady)
                StatusFooter(error: model.lastError, success: model.lastSuccess)
            } footer: {
                Text("The watch vibrates when measured HR leaves this range.")
            }
        }
        .disabled(model.loading)
        .navigationTitle("HR alert")
    }
}

struct InactivityView: View {
    @EnvironmentObject private var bluetooth: ZeTimeBluetoothManager
    @EnvironmentObject private var model: WatchSettingsModel
    private static let days = ["L", "M", "M", "J", "V", "S", "D"]

    var body: some View {
        Form {
            Section {
                Toggle("Inactivity alert", isOn: $model.inactivityEnabled)
                Stepper("After \(model.inactivityThreshold) min without moving", value: $model.inactivityThreshold, in: 15...180, step: 15)
                DatePicker("From", selection: Binding(get: { model.inactivityStart.date }, set: { model.inactivityStart = ClockTime(date: $0) }), displayedComponents: .hourAndMinute)
                DatePicker("To", selection: Binding(get: { model.inactivityEnd.date }, set: { model.inactivityEnd = ClockTime(date: $0) }), displayedComponents: .hourAndMinute)
                HStack {
                    ForEach(0..<7, id: \.self) { i in
                        let on = model.inactivityDays & (1 << i) != 0
                        Button(Self.days[i]) {
                            model.inactivityDays ^= UInt8(1 << i)
                        }
                        .buttonStyle(.bordered)
                        .tint(on ? .accentColor : .secondary)
                        .accessibilityValue(on ? "on" : "off")
                    }
                }
                Button("Apply") {
                    Task { await model.apply(model.inactivityCommand, label: String(localized: "Inactivity alert"), on: bluetooth) }
                }
                .disabled(!bluetooth.isReady)
                StatusFooter(error: model.lastError, success: model.lastSuccess)
            }
        }
        .disabled(model.loading)
        .navigationTitle("Inactivity")
    }
}

struct AutoSleepView: View {
    @EnvironmentObject private var bluetooth: ZeTimeBluetoothManager
    @EnvironmentObject private var model: WatchSettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Sleep tracking", isOn: $model.sleepTracking)
                Toggle("Auto detection", isOn: $model.autoSleep)
                DatePicker("Window: from", selection: Binding(get: { model.autoSleepEnter.date }, set: { model.autoSleepEnter = ClockTime(date: $0) }), displayedComponents: .hourAndMinute)
                DatePicker("to", selection: Binding(get: { model.autoSleepExit.date }, set: { model.autoSleepExit = ClockTime(date: $0) }), displayedComponents: .hourAndMinute)
                Button("Apply") {
                    Task { await apply() }
                }
                .disabled(!bluetooth.isReady)
                StatusFooter(error: model.lastError, success: model.lastSuccess)
            } footer: {
                Text("The window marks the hours when the watch looks for sleep (every day) — it need not match your exact schedule. Auto-sleep is not confirmed on this firmware: validate by watching upcoming readings.")
            }
        }
        .disabled(model.loading)
        .navigationTitle("Sleep")
    }

    /// Envoie les deux switches 0x90 (suivi bit2, auto bit3) puis la
    /// fenêtre 0x58 — l'app officielle envoie les trois à la sauvegarde.
    @MainActor
    private func apply() async {
        await model.apply(model.sleepTrackingCommand, label: String(localized: "Sleep tracking"), on: bluetooth)
        await model.apply(model.autoSleepCommand, label: String(localized: "Auto sleep"), on: bluetooth)
        await model.apply(model.autoSleepWindowCommand, label: String(localized: "Sleep window"), on: bluetooth)
    }
}

struct UserProfileView: View {
    @EnvironmentObject private var bluetooth: ZeTimeBluetoothManager
    @EnvironmentObject private var model: WatchSettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Sex", selection: $model.gender) {
                    Text("Male").tag(Gender.male)
                    Text("Female").tag(Gender.female)
                    Text("Other").tag(Gender.other)
                }
                Stepper("Age: \(model.age)", value: $model.age, in: 10...100)
                Stepper("Height: \(model.heightCm) cm", value: $model.heightCm, in: 100...230)
                Stepper("Weight: \(model.weightKg, specifier: "%.1f") kg", value: $model.weightKg, in: 30...200, step: 0.5)
                Button("Apply") {
                    Task { await model.apply(model.userInfoCommand, label: String(localized: "Profile"), on: bluetooth) }
                }
                .disabled(!bluetooth.isReady)
                StatusFooter(error: model.lastError, success: model.lastSuccess)
            } footer: {
                Text("Used by the watch to compute calories and distance.")
            }
        }
        .disabled(model.loading)
        .navigationTitle("Profile")
    }
}

struct SignalingView: View {
    @EnvironmentObject private var bluetooth: ZeTimeBluetoothManager
    @EnvironmentObject private var model: WatchSettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(SignalEvent.all, id: \.self) { event in
                    Picker(event.label, selection: Binding(
                        get: { model.signaling[event] ?? .vibrateOnce },
                        set: { pattern in
                            model.signaling[event] = pattern
                            Task {
                                await model.apply(.setSignaling(event: event, pattern: pattern), label: String(localized: "Vibration \(event.label)"), on: bluetooth)
                            }
                        }
                    )) {
                        ForEach(SignalPattern.all, id: \.self) { Text($0.label).tag($0) }
                    }
                }
            } footer: {
                StatusFooter(error: model.lastError, success: model.lastSuccess)
            }
        }
        .disabled(model.loading)
        .navigationTitle("Vibrations")
    }
}
