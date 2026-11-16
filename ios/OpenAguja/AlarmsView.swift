import SwiftUI
import OpenAgujaCore

/// Alarmes et rappels stockés sur la montre : lecture, ajout, modification
/// (0x97 edit, confirmé live par le projet Android), suppression. Types :
/// alarme (4), médicament (1), eau (2), rappel perso (7 — affiche `content`).
struct AlarmsView: View {
    @EnvironmentObject private var bluetooth: ZeTimeBluetoothManager
    @State private var alarms: [AlarmEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var editing: AlarmEntry?
    @State private var adding = false

    private static let dayLetters = ["L", "M", "M", "J", "V", "S", "D"]

    var body: some View {
        List {
            Section {
                NotConnectedHint()
                if let error {
                    StatusFooter(error: error)
                }
                if alarms.isEmpty, !loading {
                    Text("No alarms on the watch")
                        .foregroundStyle(.secondary)
                }
                ForEach(alarms, id: \.slot) { alarm in
                    Button {
                        editing = alarm
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(format: "%02d:%02d", alarm.hour, alarm.minute))
                                    .font(.title2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(alarm.enabled ? .primary : .secondary)
                                Text(Self.subtitle(alarm))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("Active", isOn: Binding(
                                get: { alarm.enabled },
                                set: { on in Task { await toggle(alarm, on: on) } }
                            ))
                            .labelsHidden()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    let targets = offsets.map { alarms[$0] }
                    Task {
                        for alarm in targets {
                            await delete(alarm)
                        }
                        await reload()
                    }
                }
            } footer: {
                Text("Tap a row to edit. Days: Monday→Sunday bitmask; an alarm with no day never rings.")
            }
        }
        .navigationTitle("Alarms")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if loading { ProgressView() }
                Button {
                    adding = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .disabled(!bluetooth.isReady)
            }
        }
        .refreshable { await reload() }
        .task { await reload() }
        .sheet(isPresented: $adding) {
            AlarmEditView(title: String(localized: "New alarm"), alarm: nil) { draft in
                Task {
                    await run("Add alarm") {
                        try await bluetooth.perform(.addAlarm(
                            hour: draft.hour, minute: draft.minute, days: draft.days,
                            enabled: true, pattern: draft.pattern,
                            alarmType: draft.kind, content: draft.content
                        ), label: String(localized: "Add alarm"))
                    }
                    await reload()
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { editing != nil },
            set: { if !$0 { editing = nil } }
        )) {
            if let alarm = editing {
                AlarmEditView(title: String(localized: "Edit"), alarm: alarm) { draft in
                    Task {
                        await run("Edit alarm") {
                            try await bluetooth.perform(.editAlarm(
                                existing: alarm,
                                hour: draft.hour, minute: draft.minute, days: draft.days,
                                enabled: alarm.enabled, pattern: draft.pattern,
                                alarmType: draft.kind, content: draft.content
                            ), label: String(localized: "Edit alarm"))
                        }
                        await reload()
                    }
                }
            }
        }
    }

    static func daysLabel(_ mask: UInt8) -> String {
        if mask & 0x7F == 0x7F { return String(localized: "Every day") }
        if mask & 0x7F == 0x1F { return String(localized: "Weekdays") }
        if mask & 0x7F == 0x60 { return String(localized: "Weekends") }
        if mask == 0 { return String(localized: "No day") }
        return (0..<7).filter { mask & (1 << $0) != 0 }.map { dayLetters[$0] }.joined(separator: " ")
    }

    private static func kindLabel(_ type: UInt8) -> String {
        switch type {
        case 1: return String(localized: "Medication")
        case 2: return String(localized: "Water")
        case 7: return String(localized: "Custom reminder")
        default: return type == 4 ? "Alarm" : "Type \(type)"
        }
    }

    private static func subtitle(_ alarm: AlarmEntry) -> String {
        var parts = [kindLabel(alarm.alarmType)]
        let days = daysLabel(alarm.cycle)
        if days != "No day" { parts.append(days) }
        if alarm.alarmType == 7 { parts.append("(text shown on the watch)") }
        return parts.joined(separator: " · ")
    }

    /// Type 0x97 → AlarmKind FFI (4 = alarme par défaut).
    private static func kind(of alarm: AlarmEntry) -> AlarmKind {
        switch alarm.alarmType {
        case 1: return .medicine
        case 2: return .water
        case 7: return .custom
        default: return .alarm
        }
    }

    @MainActor
    private func reload() async {
        guard bluetooth.isReady else { return }
        loading = true
        defer { loading = false }
        do {
            alarms = try await bluetooth.readAlarms()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func delete(_ alarm: AlarmEntry) async {
        await run("Delete alarm") {
            try await bluetooth.perform(.deleteAlarm(alarm: alarm), label: String(localized: "Delete alarm"))
        }
    }

    /// Activation/désactivation par édition (champs existants conservés,
    /// horodatage/date conservés tels quels — l'identité = le bloc de
    /// champs, pas un id).
    @MainActor
    private func toggle(_ alarm: AlarmEntry, on: Bool) async {
        await run("Alarm \(on ? "on" : "off")") {
            try await bluetooth.perform(.editAlarm(
                existing: alarm,
                hour: alarm.hour, minute: alarm.minute, days: alarm.cycle,
                enabled: on,
                pattern: signalPatternFromCode(code: alarm.shock) ?? .vibrateOnce,
                alarmType: Self.kind(of: alarm),
                content: ""
            ), label: String(localized: "Alarm"))
        }
        await reload()
    }

    @MainActor
    private func run(_ label: String, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            error = nil
        } catch {
            self.error = "\(label) : \(error.localizedDescription)"
        }
    }
}

/// Brouillon d'alarme/rappel pour ajout et modification.
private struct AlarmDraft {
    var hour: UInt8 = 7
    var minute: UInt8 = 0
    var days: UInt8 = 0x1F
    var pattern: SignalPattern = .vibrate
    var kind: AlarmKind = .alarm
    var content: String = ""
}

private struct AlarmEditView: View {
    let title: String
    let alarm: AlarmEntry?
    let onSave: (AlarmDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var time: Date
    @State private var days: UInt8
    @State private var pattern: SignalPattern
    @State private var kind: AlarmKind
    @State private var content: String

    private static let names = ["Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi", "Dimanche"]

    init(title: String, alarm: AlarmEntry?, onSave: @escaping (AlarmDraft) -> Void) {
        self.title = title
        self.alarm = alarm
        self.onSave = onSave
        let cal = Calendar.current
        _time = State(initialValue: alarm.map {
            cal.date(from: DateComponents(hour: Int($0.hour), minute: Int($0.minute))) ?? Date()
        } ?? cal.date(from: DateComponents(hour: 7, minute: 0)) ?? Date())
        _days = State(initialValue: alarm?.cycle ?? 0x1F)
        _pattern = State(initialValue: alarm.flatMap { signalPatternFromCode(code: $0.shock) } ?? .vibrate)
        _kind = State(initialValue: alarm.map {
            switch $0.alarmType {
            case 1: return .medicine
            case 2: return .water
            case 7: return .custom
            default: return .alarm
            }
        } ?? .alarm)
        _content = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    Text("Alarm").tag(AlarmKind.alarm)
                    Text("Medication").tag(AlarmKind.medicine)
                    Text("Water").tag(AlarmKind.water)
                    Text("Custom reminder").tag(AlarmKind.custom)
                }
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                Section("Repeat") {
                    ForEach(0..<7, id: \.self) { i in
                        Toggle(Self.names[i], isOn: Binding(
                            get: { days & (1 << i) != 0 },
                            set: { on in days = on ? days | UInt8(1 << i) : days & ~UInt8(1 << i) }
                        ))
                    }
                }
                Picker("Signal", selection: $pattern) {
                    ForEach(SignalPattern.all.filter { $0 != .none }, id: \.self) { Text($0.label).tag($0) }
                }
                if kind == .custom {
                    TextField("Reminder text", text: $content, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                        onSave(AlarmDraft(
                            hour: UInt8(c.hour ?? 7), minute: UInt8(c.minute ?? 0),
                            days: days, pattern: pattern, kind: kind, content: content
                        ))
                        dismiss()
                    }
                    .disabled(days == 0 || (kind == .custom && content.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
    }
}
