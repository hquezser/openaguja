import Charts
import SwiftUI
import OpenAgujaCore

/// Détail d'une journée passée : pas/kcal/km/activité, cardio et sommeil
/// (données déjà synchronisées dans `ActivityStore` — pas de requête BLE).
struct DayDetailView: View {
    @EnvironmentObject private var activity: ActivityStore
    @EnvironmentObject private var settings: WatchSettingsModel
    @State private var day: Date

    /// `day` optionnel : ouvre directement sur un jour (ex. depuis le
    /// graphique 7 jours de l'onglet Activité) ; sinon aujourd'hui.
    init(day: Date = Date()) {
        _day = State(initialValue: Calendar.current.startOfDay(for: day))
    }

    private var availableDays: [Date] { activity.daysWithData() }
    private var total: ActivityStore.DayTotal { activity.dayTotal(on: day) }
    private var hrSamples: [ActivityStore.HeartRateSample] { activity.heartRate(on: day) }
    private var sleep: (deep: Int, light: Int, awake: Int)? {
        // La nuit « du » jour J se termine le matin de J : on regarde la
        // nuit qui s'est terminée ce jour-là (comme la carte Sommeil).
        activity.sleepSummary(endingOn: day)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                        .disabled(!canShift(-1))
                    Spacer()
                    Text(day.formatted(date: .complete, time: .omitted))
                        .font(.headline)
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(day >= Calendar.current.startOfDay(for: Date()))
                }
                .buttonStyle(.plain)
            }

            Section("Activity") {
                LabeledContent("Steps", value: total.steps.formatted())
                LabeledContent("Calories", value: "\(total.calories) kcal")
                LabeledContent("Distance", value: String(format: "%.1f km", Double(total.distanceM) / 1000))
                LabeledContent("Active time", value: "\(total.activeMin) min")
                LabeledContent("Step goal", value: settings.stepGoal.formatted())
            }

            Section("Cardio") {
                if hrSamples.isEmpty {
                    Text("No measurement that day")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    let avg = hrSamples.map(\.bpm).reduce(0, +) / hrSamples.count
                    let maxBpm = hrSamples.map(\.bpm).max() ?? 0
                    LabeledContent("Readings", value: "\(hrSamples.count)")
                    LabeledContent("Average", value: "\(avg) bpm")
                    LabeledContent("Max", value: "\(maxBpm) bpm")
                    Chart(hrSamples, id: \.date) { s in
                        LineMark(x: .value("Time", s.date), y: .value("bpm", s.bpm))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(ZTColor.danger)
                        PointMark(x: .value("Time", s.date), y: .value("bpm", s.bpm))
                            .foregroundStyle(ZTColor.danger)
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 140)
                }
            }

            Section("Sleep") {
                if let s = sleep, s.deep + s.light + s.awake > 0 {
                    LabeledContent("Deep", value: ActivityView.duration(s.deep))
                    LabeledContent("Light", value: ActivityView.duration(s.light))
                    LabeledContent("Awake", value: ActivityView.duration(s.awake))
                } else {
                    Text("No sleep data")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Day by day")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Jour le plus récent avec des données, ou aujourd'hui.
            if let last = availableDays.last, day > last {
                day = min(day, last)
            }
        }
    }

    private func canShift(_ delta: Int) -> Bool {
        guard let idx = availableDays.firstIndex(of: day) else { return delta > 0 }
        let target = idx + delta
        return availableDays.indices.contains(target)
    }

    private func shift(_ delta: Int) {
        guard let idx = availableDays.firstIndex(of: day) else { return }
        let target = idx + delta
        guard availableDays.indices.contains(target) else { return }
        day = availableDays[target]
    }
}
