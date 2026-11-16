import Charts
import SwiftUI
import OpenAgujaCore

/// Graphiques des synthèses quotidiennes lues depuis le webhook
/// (`telemetryHistoryURL`) : sommeil, cardio, pas et rythme
/// coucher/réveil — lecture seule via `TelemetryHistoryStore`.
struct TelemetryHistoryView: View {
    @EnvironmentObject private var history: TelemetryHistoryStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Period", selection: $history.periodDays) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented)
                }
                if let error = history.error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
                if history.days.isEmpty && !history.loading {
                    Section {
                        Text("No data for this period.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Sleep") {
                    sleepChart
                    Text("Indigo = deep, cyan = light, mint = REM.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Cardio") {
                    heartChart
                    Text("Red = resting, orange = average.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Steps") {
                    stepsChart
                }
                Section("Bedtime / wake") {
                    rhythmChart
                    Text("Local times; bedtime in violet, wake in green.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Refresh") { Task { await history.refresh() } }
                        .disabled(history.loading)
                } footer: {
                    if let last = history.lastRefresh {
                        Text("Last sync: \(last.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }
            .navigationTitle("Health (server)")
            .refreshable { await history.refresh() }
            .task(id: history.periodDays) { await history.refresh() }
        }
    }

    private var sleepChart: some View {
        Chart {
            ForEach(history.days) { day in
                if let d = day.dayDate {
                    // Répartition par phase quand le serveur la fournit ;
                    // sinon repli sur la hauteur totale historique.
                    let stages = [
                        (day.deepMinutes, Color.indigo),
                        (day.lightMinutes, Color.cyan),
                        (day.remMinutes, Color.mint),
                    ].compactMap { m, c -> (Double, Color)? in
                        guard let m, m > 0 else { return nil }
                        return (Double(m) / 60, c)
                    }
                    if stages.isEmpty {
                        if let h = day.sleepHours {
                            BarMark(x: .value("Day", d), y: .value("Hours", h))
                                .foregroundStyle(.blue)
                                .cornerRadius(2)
                        }
                    } else {
                        ForEach(Array(stages.enumerated()), id: \.offset) { _, s in
                            BarMark(x: .value("Day", d), y: .value("Hours", s.0))
                                .foregroundStyle(s.1)
                        }
                    }
                }
            }
        }
        .frame(height: 180)
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    Text("\(Int(value.as(Double.self) ?? 0)) h")
                }
            }
        }
    }

    private var heartChart: some View {
        Chart {
            ForEach(history.days) { day in
                if let d = day.dayDate, let v = day.restingHr {
                    LineMark(x: .value("Day", d), y: .value("bpm", Double(v)))
                        .foregroundStyle(.red)
                        .symbol(.circle)
                }
            }
            ForEach(history.days) { day in
                if let d = day.dayDate, let v = day.avgHr {
                    LineMark(x: .value("Day", d), y: .value("bpm", Double(v)))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
            }
        }
        .frame(height: 180)
    }

    private var stepsChart: some View {
        Chart {
            ForEach(history.days) { day in
                if let d = day.dayDate, let v = day.totalSteps {
                    BarMark(x: .value("Day", d), y: .value("Steps", Double(v)))
                        .foregroundStyle(.green)
                        .cornerRadius(2)
                }
            }
        }
        .frame(height: 180)
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    Text((value.as(Double.self) ?? 0).formatted(.number.notation(.compactName)))
                }
            }
        }
    }

    private var rhythmChart: some View {
        Chart {
            ForEach(history.days) { day in
                if let d = day.dayDate, let v = day.bedtimeMinutes {
                    LineMark(x: .value("Day", d), y: .value("Time", v))
                        .foregroundStyle(.purple)
                        .symbol(.circle)
                }
            }
            ForEach(history.days) { day in
                if let d = day.dayDate, let v = day.wakeMinutes {
                    LineMark(x: .value("Day", d), y: .value("Time", v))
                        .foregroundStyle(.teal)
                        .symbol(.circle)
                }
            }
        }
        .frame(height: 180)
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let m = value.as(Double.self) {
                        Text(String(format: "%02d:%02d", Int(m) / 60, Int(m) % 60))
                    }
                }
            }
        }
    }
}
