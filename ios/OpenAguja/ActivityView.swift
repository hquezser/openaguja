import Charts
import SwiftUI
import OpenAgujaCore

/// Onglet Activité — structure du prototype `ActivityTab` : grand
/// compteur de pas du jour + objectif, courbe 7 jours, métriques,
/// cardio du jour, sommeil et mesures cardiaques. Données réelles
/// d'`ActivityStore` / `HeartRateService`.
struct ActivityView: View {
    @EnvironmentObject private var bluetooth: ZeTimeBluetoothManager
    @EnvironmentObject private var activity: ActivityStore
    @EnvironmentObject private var settings: WatchSettingsModel
    @EnvironmentObject private var heartRate: HeartRateService
    @State private var share: ShareItem?
    @State private var selectedDay: Date?
    @State private var showData = false

    private var today: ActivityStore.DayTotal {
        activity.dailyTotals(days: 1).last
            ?? ActivityStore.DayTotal(day: .now, steps: 0, calories: 0, distanceM: 0, activeMin: 0)
    }

    private var totals: [ActivityStore.DayTotal] { activity.dailyTotals() }
    private var goal: Int { settings.stepGoal }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                stepsCard
                weekChartCard
                metricsCard
                heartCard
                sleepCard
                heartRateActions
                dataCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            ZTLargeTitle("Activity") {
                syncButton
            }
        }
        .refreshable { await activity.sync(from: bluetooth) }
        .sheet(item: $share) { item in ShareSheet(items: [item.url]) }
    }

    private var syncButton: some View {
        Group {
            if activity.syncing {
                ProgressView()
            } else {
                ZTCircleButton(symbol: "arrow.triangle.2.circlepath", label: "Sync") {
                    Task { await activity.sync(from: bluetooth) }
                }
            }
        }
        .disabled(!bluetooth.isReady)
    }

    // MARK: - Steps today

    private var stepsCard: some View {
        ZTCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Steps today")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ZTColor.muted)
                        Text(today.steps.formatted())
                            .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(ZTColor.foreground)
                    }
                    Spacer()
                    Text("\(min(100, Int((Double(today.steps) / Double(max(goal, 1)) * 100).rounded()))) %")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(today.steps >= goal ? ZTColor.success : ZTColor.primary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ZTColor.secondary).frame(height: 8)
                        Capsule()
                            .fill(today.steps >= goal ? ZTColor.success : ZTColor.primary)
                            .frame(width: geo.size.width * CGFloat(min(1, Double(today.steps) / Double(max(goal, 1)))), height: 8)
                    }
                }
                .frame(height: 8)
                HStack {
                    Label("Goal \(goal.formatted())", systemImage: "flag.checkered")
                        .font(.caption).foregroundStyle(ZTColor.muted)
                    Spacer()
                    if today.steps >= goal {
                        Label("Goal reached", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(ZTColor.success)
                    } else {
                        Text("\(max(0, goal - today.steps).formatted()) to go")
                            .font(.caption).foregroundStyle(ZTColor.muted)
                    }
                }
            }
        }
    }

    // MARK: - 7-day chart

    private var weekChartCard: some View {
        ZTCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Last 7 days")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let selectedDay {
                        Text("\(Self.dayName(selectedDay)) · \(activity.dayTotal(on: selectedDay).steps.formatted()) steps")
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(ZTColor.primary)
                    }
                }
                Chart(totals) { day in
                    BarMark(
                        x: .value("Day", day.day, unit: .day),
                        y: .value("Steps", day.steps)
                    )
                    .foregroundStyle(day.steps >= goal ? ZTColor.success : ZTColor.primary)
                    .cornerRadius(4)
                    .opacity(selectedDay.map { Calendar.current.isDate($0, inSameDayAs: day.day) ? 1.0 : 0.35 } ?? 1.0)
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(
                                SpatialTapGesture().onEnded { value in
                                    let origin = geo[proxy.plotAreaFrame].origin
                                    guard let date: Date = proxy.value(atX: value.location.x - origin.x)
                                    else { return }
                                    selectedDay = Calendar.current.startOfDay(for: date)
                                }
                            )
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 170)
                HStack {
                    NavigationLink {
                        DayDetailView(day: selectedDay ?? .now)
                    } label: {
                        Label("Day by day", systemImage: "calendar.day.timeline.left")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ZTColor.primary)
                    Spacer()
                    syncStatusLine
                }
            }
        }
    }

    // MARK: - Metrics grid

    private var metricsCard: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            metricTile("flame.fill", ZTColor.warning, "kcal", today.calories.formatted())
            metricTile("point.topleft.down.curvedto.point.bottomright.up", ZTColor.info, "km",
                       String(format: "%.1f", Double(today.distanceM) / 1000))
            metricTile("timer", ZTColor.accent, "active min", "\(today.activeMin)")
        }
    }

    private func metricTile(_ symbol: String, _ tint: Color, _ label: LocalizedStringKey, _ value: String) -> some View {
        ZTCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                ZTIconTile(symbol: symbol, tint: tint, bg: tint, size: 26)
                Text(value).font(.title3.weight(.bold).monospacedDigit())
                Text(label).font(.caption).foregroundStyle(ZTColor.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Heart rate today

    private var heartCard: some View {
        ZTCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Heart rate · today")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if heartRate.sessionActive {
                        ZTPill(tone: .accent, text: "Live")
                    }
                    if let live = heartRate.liveBpm,
                       let at = heartRate.liveBpmDate,
                       Date().timeIntervalSince(at) < 120 {
                        Text("\(live) bpm")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(ZTColor.danger)
                    }
                }
                heartRateChart
                if let last = activity.heartRate(on: Date()).last {
                    Label("Last \(last.bpm) bpm · \(last.date.formatted(date: .omitted, time: .shortened))",
                          systemImage: "heart.text.square")
                        .font(.caption).foregroundStyle(ZTColor.muted)
                }
                if let fcr = activity.restingHeartRate {
                    Label("Resting \(fcr.bpm) bpm · \(fcr.date.formatted(date: .abbreviated, time: .shortened))",
                          systemImage: "heart.circle")
                        .font(.caption).foregroundStyle(ZTColor.muted)
                }
            }
        }
    }

    @ViewBuilder
    private var heartRateChart: some View {
        let samples = activity.heartRate(on: Date())
        if samples.isEmpty {
            Text("No measurement today (enable auto measure in Settings → Sensors).")
                .font(.footnote).foregroundStyle(ZTColor.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Chart(samples, id: \.date) { s in
                AreaMark(x: .value("Time", s.date), y: .value("bpm", s.bpm))
                    .foregroundStyle(LinearGradient(
                        colors: [ZTColor.danger.opacity(0.35), ZTColor.danger.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", s.date), y: .value("bpm", s.bpm))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(ZTColor.danger)
                PointMark(x: .value("Time", s.date), y: .value("bpm", s.bpm))
                    .foregroundStyle(ZTColor.danger).symbolSize(14)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 150)
        }
    }

    // MARK: - Heart-rate actions

    private var heartRateActions: some View {
        HStack(spacing: 10) {
            Button {
                Task { await heartRate.measureResting() }
            } label: {
                Label("Measure RHR", systemImage: "heart.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent).tint(ZTColor.danger)
            .disabled(!bluetooth.isReady || heartRate.sessionActive)
            Button {
                Task {
                    if heartRate.sessionActive { await heartRate.stopSession() }
                    else { try? await heartRate.startSession() }
                }
            } label: {
                Label(heartRate.sessionActive ? "Stop" : "~5 min session",
                      systemImage: heartRate.sessionActive ? "stop.circle" : "figure.run")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
            }
            .buttonStyle(.bordered)
            .disabled(!bluetooth.isReady)
        }
    }

    // MARK: - Sleep

    private var sleepCard: some View {
        ZTCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Sleep · last night")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let s = activity.sleepSummary(endingOn: Date()) {
                        let total = s.deep + s.light + s.awake
                        Text(total > 0 ? "\(Self.duration(total)) total" : "—")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(ZTColor.muted)
                    }
                }
                if let s = activity.sleepSummary(endingOn: Date()) {
                    sleepBar(deep: s.deep, light: s.light, awake: s.awake,
                             total: s.deep + s.light + s.awake)
                    HStack(spacing: 14) {
                        sleepLegend("Deep", minutes: s.deep, color: ZTColor.sleepDeep)
                        sleepLegend("Light", minutes: s.light, color: ZTColor.sleepLight)
                        sleepLegend("Awake", minutes: s.awake, color: ZTColor.sleepREM)
                    }
                } else {
                    Text("No sleep data for last night.")
                        .font(.footnote).foregroundStyle(ZTColor.muted)
                }
            }
        }
    }

    private func sleepBar(deep: Int, light: Int, awake: Int, total: Int) -> some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                if deep > 0 { segment(minutes: deep, total: total, color: ZTColor.sleepDeep, width: geo.size.width) }
                if light > 0 { segment(minutes: light, total: total, color: ZTColor.sleepLight, width: geo.size.width) }
                if awake > 0 { segment(minutes: awake, total: total, color: ZTColor.sleepREM, width: geo.size.width) }
            }
        }
        .frame(height: 14)
    }

    private func segment(minutes: Int, total: Int, color: Color, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color)
            .frame(width: max(6, width * CGFloat(minutes) / CGFloat(max(total, 1)) - 2))
    }

    private func sleepLegend(_ label: LocalizedStringKey, minutes: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(label) \(Self.duration(minutes))")
                .font(.caption.monospacedDigit()).foregroundStyle(ZTColor.muted)
        }
    }

    // MARK: - Data & sync

    private var dataCard: some View {
        ZTCard {
            VStack(spacing: 0) {
                Toggle(isOn: $activity.deleteAfterSync) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete from watch after sync").font(.body.weight(.medium))
                        Text("Records are removed from the watch once synced.")
                            .font(.caption).foregroundStyle(ZTColor.muted)
                    }
                }
                .tint(ZTColor.primary)
                .padding(.horizontal, 16).padding(.vertical, 10)
                ZTRowDivider()
                ZTRow(icon: "tablecells", label: "Export CSV", chevron: false) {
                    share = activity.exportCSV().map(ShareItem.init)
                }
            }
        }
    }

    @ViewBuilder
    private var syncStatusLine: some View {
        if let error = activity.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(ZTColor.danger)
        } else if let sync = activity.lastSync {
            Text("Synced \(sync.relative)").font(.caption).foregroundStyle(ZTColor.muted)
        } else {
            Text("Never synced — pull to fetch watch data.")
                .font(.caption).foregroundStyle(ZTColor.muted)
        }
    }

    private static func dayName(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day())
    }

    static func duration(_ minutes: Int) -> String {
        "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }
}
