import EventKit
import Foundation
import OpenAgujaCore

/// Envoi des prochains événements de l'agenda à la montre (0x99, comme
/// Gadgetbridge : 17 événements max, 300 ms entre deux). Expérimental :
/// Gadgetbridge garde cette fonction désactivée faute de test.
final class CalendarSync: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var lastResult: String?

    static let maxEvents = 17
    private let store = EKEventStore()

    @MainActor
    func sync(to watch: ZeTimeBluetoothManager, days: Int = 7) async {
        busy = true
        defer { busy = false }
        do {
            guard try await requestAccess() else {
                lastResult = String(localized: "Calendar access denied (iOS Settings → Privacy → Calendars)")
                return
            }
            let start = Date()
            let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = store.events(matching: predicate)
                .filter { !$0.isAllDay }
                .sorted { $0.startDate < $1.startDate }
                .prefix(Self.maxEvents)
            // Remplacement complet (flux Android) : purge → événements du
            // jour → masque mensuel 0x98. La purge part même sans
            // événement pour effacer l'ancienne synchro.
            try await watch.perform(.clearCalendar, label: String(localized: "Calendar: clearing"))
            try? await Task.sleep(nanoseconds: 300_000_000)
            for (i, event) in events.enumerated() {
                if i > 0 { try await Task.sleep(nanoseconds: 300_000_000) }
                try await watch.perform(
                    .calendarEvent(first: i == 0, at: WatchDateTime(date: event.startDate), title: event.title ?? "Event"),
                    label: String(localized: "Calendar \(i + 1)/\(events.count)")
                )
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            try await watch.perform(
                .calendarMonthView(mask: monthMask()),
                label: String(localized: "Calendar: month view")
            )
            lastResult = events.isEmpty
                ? "Calendar cleared on the watch"
                : "\(events.count) event(s) sent + month view"
        } catch {
            lastResult = error.localizedDescription
        }
    }

    /// Masque 0x98 : 8 u32 jour-mois, ordre fil `[mois courant][mois
    /// dernier][+1…+6]` (Android `CalendarMonthView.kt`). Bit `jour-1` par
    /// jour avec événement. La montre déduit les vrais mois de sa propre
    /// heure — aucun mois/année n'est envoyé.
    private func monthMask() -> [UInt32] {
        let cal = Calendar.current
        guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date())),
              let windowStart = cal.date(byAdding: .month, value: -1, to: monthStart),
              let windowEnd = cal.date(byAdding: .month, value: 7, to: monthStart)
        else { return [UInt32](repeating: 0, count: 8) }
        let events = store.events(matching: store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil))
            .filter { !$0.isAllDay }
        var buckets = [Int: UInt32]()
        for event in events {
            guard let eventMonth = cal.date(from: cal.dateComponents([.year, .month], from: event.startDate)),
                  let offset = cal.dateComponents([.month], from: monthStart, to: eventMonth).month,
                  (-1...6).contains(offset)
            else { continue }
            // offset -1 → slot 1 (mois dernier), 0 → slot 0, +n → slot n+1.
            let slot = offset + 1
            let day = cal.component(.day, from: event.startDate)
            buckets[slot, default: 0] |= UInt32(1) << UInt32(day - 1)
        }
        // Ordre fil : [ce mois][mois dernier][+1][+2][+3][+4][+5][+6].
        return [
            buckets[1] ?? 0, buckets[0] ?? 0,
            buckets[2] ?? 0, buckets[3] ?? 0, buckets[4] ?? 0,
            buckets[5] ?? 0, buckets[6] ?? 0, buckets[7] ?? 0,
        ]
    }

    /// Prochain événement (hors journée entière) dans les 36 h.
    @MainActor
    func nextEvent() async -> (date: Date, title: String)? {
        guard (try? await requestAccess()) == true else { return nil }
        let start = Date()
        let end = start.addingTimeInterval(36 * 3600)
        let event = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.startDate >= start }
            .min { $0.startDate < $1.startDate }
        return event.map { ($0.startDate, $0.title ?? "Event") }
    }

    private func requestAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await store.requestFullAccessToEvents()
        }
        return try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(to: .event) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }
}
