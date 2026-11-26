import SwiftUI
import OpenAgujaCore

/// Tables de correspondance des boutons physiques (0x2E) — partagées
/// entre l'onglet Routage (remap) et l'onglet Montre (lecture seule).
enum WatchButtonTables {
    static let buttons: [(id: UInt8, label: String, symbol: String)] = [
        (1, String(localized: "Top button"), "arrow.up.circle"),
        (2, String(localized: "Bottom button"), "arrow.down.circle"),
        (3, String(localized: "Crown · short press"), "digitalcrown.press"),
        (4, String(localized: "Crown · long press"), "digitalcrown.horizontal.press"),
    ]

    /// Fonctions 0x2E assignables (table du protocole).
    static let functions: [(id: UInt8, label: String)] = [
        (0, String(localized: "None")), (1, String(localized: "Dim screen")), (2, String(localized: "Heart rate")),
        (3, String(localized: "Calendar")), (4, String(localized: "Music")), (5, String(localized: "Timer")), (6, String(localized: "Camera")),
        (7, String(localized: "Alarm")), (8, String(localized: "Weather")), (9, String(localized: "Second time zone")), (10, String(localized: "Notifications")),
        (11, String(localized: "SMS")), (12, String(localized: "Stopwatch")), (13, String(localized: "Missed calls")), (14, String(localized: "Activity")),
        (15, String(localized: "Sleep")), (16, String(localized: "Find phone")), (17, String(localized: "Do not disturb")),
        (18, String(localized: "Silent")), (19, String(localized: "Airplane")),
    ]

    static func buttonLabel(_ id: UInt8) -> String {
        buttons.first { $0.id == id }?.label ?? String(localized: "Button \(id)")
    }

    static func functionLabel(_ id: UInt8) -> String {
        functions.first { $0.id == id }?.label ?? String(localized: "Function \(id)")
    }
}

/// Onglet Routage (mode développeur) — structure du prototype
/// `MappingsTab` : section Physique (boutons 0x2E), Média, Alertes,
/// retour haptique et Modes contextuels. Données réelles `ActionRouter`.
struct RoutingView: View {
    @EnvironmentObject private var bluetooth: ZeTimeBluetoothManager
    @EnvironmentObject private var router: ActionRouter
    @EnvironmentObject private var bridge: WebhookBridge
    @EnvironmentObject private var macd: MacDaemonBridge

    enum Segment: String, CaseIterable, Identifiable {
        case physical, media, alerts, remote
        var id: String { rawValue }
    }

    /// Action en attente de confirmation (mode contextuel ou préréglage).
    private enum Pending: Identifiable {
        case mode(RouteMode)
        case preset(String, () -> Void)
        var id: String {
            switch self {
            case .mode(let m): return "mode-\(m.id)"
            case .preset(let label, _): return "preset-\(label)"
            }
        }
    }

    @State private var segment = Segment.physical
    @State private var pending: Pending?
    @State private var assignments: [UInt8: UInt8] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var success: String?
    @State private var exampleMessage: String?

    /// Actions « alertes » : trouver, caméra, appel rejeté, SOS, réponse.
    private static let alertIds: Set<String> = ["find_phone", "camera", "call_rejected", "sos", "quick_reply"]
    /// Les boutons Remote n'existent qu'avec le firmware patché.
    private static let remoteFooter: LocalizedStringKey = "Only watches running the community “Remote” firmware patch send these buttons (zetime.artificialred.nl). Stock firmware never does."
    /// Actions « média » : transport et volume.
    private static let mediaIds: Set<String> = ["play", "pause", "previous", "next", "volume_up", "volume_down"]

    private var actionsForSegment: [ActionRouter.WatchActionInfo] {
        ActionRouter.actions.filter {
            switch segment {
            case .alerts: return Self.alertIds.contains($0.id)
            case .remote: return ActionRouter.isRemoteAction($0.id)
            default: return Self.mediaIds.contains($0.id)
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                ZTLargeTitle("Routing")
                segmentPicker
                if router.modes.isEmpty { modesEmptyCard } else { modesCard }
                if segment == .physical { physicalCard } else { actionsCard }
                hapticCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .task { if assignments.isEmpty { await load() } }
        .confirmationDialog("Confirm", item: $pending) { action in
            switch action {
            case .mode(let mode):
                Button("Apply “\(mode.label)”") { router.apply(mode: mode) }
                Button("Cancel", role: .cancel) {}
            case .preset(let label, let apply):
                Button("Apply “\(label)”", action: apply)
                Button("Cancel", role: .cancel) {}
            }
        } message: { action in
            switch action {
            case .mode(let mode):
                Text("Targets and side effects of “\(mode.label)” applied to all watch actions.")
            case .preset:
                Text("This action does not fire on scroll: it applies only on your confirmation.")
            }
        }
    }

    // MARK: - Segment

    private var segmentPicker: some View {
        ZTSegmented(options: [
            (.physical, "Physical"), (.media, "Media"), (.alerts, "Alerts"), (.remote, "Remote"),
        ], selection: $segment)
    }

    // MARK: - Modes

    private var modesCard: some View {
        ZTSection(title: "Modes") {
            ZTList {
                ForEach(Array(router.modes.enumerated()), id: \.element.id) { i, mode in
                    if i > 0 { ZTRowDivider() }
                    modeRow(mode)
                }
            }
        }
    }

    private func modeRow(_ mode: RouteMode) -> some View {
        Button { pending = .mode(mode) } label: {
            HStack(spacing: 12) {
                ZTIconTile(symbol: mode.symbol, tint: router.activeMode == mode ? ZTColor.primary : ZTColor.muted,
                           bg: router.activeMode == mode ? ZTColor.primary : ZTColor.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.label).font(.callout.weight(.medium)).foregroundStyle(ZTColor.foreground)
                    Text(Self.modeDetail(mode)).font(.caption).foregroundStyle(ZTColor.muted).lineLimit(2)
                }
                Spacer()
                if router.activeMode == mode {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(ZTColor.primary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Résumé d'un mode importé : cibles propres et effets de bord.
    private static func modeDetail(_ mode: RouteMode) -> String {
        var parts: [String] = []
        if !mode.targets.isEmpty { parts.append("\(mode.targets.count) own target(s)") }
        if !mode.bindings.buttons.isEmpty { parts.append("\(mode.bindings.buttons.count) button(s)") }
        if !mode.bindings.daemonCommands.isEmpty || !mode.bindings.onActivate.isEmpty
            || !mode.bindings.onActivateTimed.isEmpty { parts.append("Mac commands") }
        if mode.bindings.musicViaNowPlaying { parts.append("music via player") }
        return parts.isEmpty ? "Default targets" : parts.joined(separator: " · ")
    }

    private var modesEmptyCard: some View {
        ZTSection(title: "Modes") {
            ZTCard {
                VStack(spacing: 12) {
                    Text("No modes yet")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(ZTColor.foreground)
                    Text("Import a profile in Settings → Profile, or load the bundled example.")
                        .font(.caption).foregroundStyle(ZTColor.muted)
                        .multilineTextAlignment(.center)
                    Button {
                        loadExample()
                    } label: {
                        Label("Load example", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent).tint(ZTColor.primary)
                    if let exampleMessage {
                        Text(exampleMessage).font(.caption).foregroundStyle(ZTColor.muted)
                    }
                }
                .padding(16)
            }
        }
    }

    /// Charge `contrib/profiles/example.json` (bundlé comme ressource)
    /// via le même chemin que l'import de profil.
    private func loadExample() {
        guard let url = Bundle.main.url(forResource: "example", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            exampleMessage = "Example file not found in the app bundle."
            return
        }
        do {
            let profile = try AppProfile.decode(data)
            try profile.apply()
            bridge.reload(); macd.reload(); router.reload()
            if profile.modes != nil, #available(iOS 17.0, *) {
                ZeTimeShortcuts.updateAppShortcutParameters()
            }
            exampleMessage = "Example profile loaded."
        } catch {
            exampleMessage = "Load failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Physical buttons (0x2E)

    private var physicalCard: some View {
        ZTSection(title: "Physical") {
            ZTList {
                ForEach(Array(WatchButtonTables.buttons.enumerated()), id: \.element.id) { i, button in
                    if i > 0 { ZTRowDivider() }
                    physicalRow(button)
                }
            }
        }
    }

    private func physicalRow(_ button: (id: UInt8, label: String, symbol: String)) -> some View {
        HStack(spacing: 12) {
            ZTIconTile(symbol: button.symbol, tint: ZTColor.info, bg: ZTColor.info)
            Text(LocalizedStringKey(button.label)).font(.callout).foregroundStyle(ZTColor.foreground)
            Spacer()
            Picker("", selection: Binding(
                get: { assignments[button.id] ?? 0 },
                set: { function in Task { await assign(button.id, function) } }
            )) {
                ForEach(WatchButtonTables.functions, id: \.id) { Text(LocalizedStringKey($0.label)).tag($0.id) }
            }
            .pickerStyle(.menu).labelsHidden()
            .disabled(!bluetooth.isReady)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: - Actions (media / alerts)

    private var actionsCard: some View {
        ZTSection(
            title: segment == .media ? "Media" : segment == .remote ? "Remote" : "Alerts",
            footer: segment == .remote ? Self.remoteFooter : nil
        ) {
            ZTList {
                ForEach(Array(actionsForSegment.enumerated()), id: \.element.id) { i, action in
                    if i > 0 { ZTRowDivider() }
                    NavigationLink { ActionTargetView(action: action) } label: {
                        HStack(spacing: 12) {
                            ZTIconTile(symbol: action.symbol, tint: ZTColor.accent, bg: ZTColor.accent)
                            Text(LocalizedStringKey(action.label)).font(.callout).foregroundStyle(ZTColor.foreground)
                            Spacer()
                            Text(LocalizedStringKey(router.target(for: action.id).label))
                                .font(.caption).foregroundStyle(ZTColor.muted)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(ZTColor.muted)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Haptics

    private var hapticCard: some View {
        ZTSection(title: "Haptic feedback") {
            ZTList {
                ZTRow(icon: "checkmark.circle", iconTint: ZTColor.success, iconBg: ZTColor.success,
                      label: "On success (HTTP 200)") {
                    Toggle("", isOn: $router.hapticOnSuccess).labelsHidden().tint(ZTColor.success)
                }
                ZTRowDivider()
                ZTRow(icon: "xmark.circle", iconTint: ZTColor.danger, iconBg: ZTColor.danger,
                      label: "On failure / offline") {
                    Toggle("", isOn: $router.hapticOnFailure).labelsHidden().tint(ZTColor.danger)
                }
                ZTRowDivider()
                HStack(spacing: 12) {
                    ZTIconTile(symbol: router.hapticPattern.symbol, tint: ZTColor.accent, bg: ZTColor.accent)
                    Text("Vibration pattern").font(.callout).foregroundStyle(ZTColor.foreground)
                    Spacer()
                    Picker("", selection: $router.hapticPattern) {
                        ForEach(HapticPattern.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
    }

    // MARK: - Physical buttons BLE

    @MainActor
    private func load() async {
        guard bluetooth.isReady else { return }
        loading = true
        defer { loading = false }
        do {
            let read = try await bluetooth.readButtons()
            assignments = Dictionary(read.map { ($0.button, $0.function) }, uniquingKeysWith: { $1 })
            error = nil
        } catch {
            self.error = String(localized: "Read: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func assign(_ button: UInt8, _ function: UInt8) async {
        let label = WatchButtonTables.buttonLabel(button)
        do {
            try await bluetooth.perform(.setButtonFunction(button: button, function: function), label: label)
            assignments[button] = function
            Task { await bluetooth.refreshButtonFunctions() }
            error = nil
            success = label
        } catch {
            self.error = "\(label): \(error.localizedDescription)"
        }
    }
}

/// Choix de la destination d'une action de la montre.
struct ActionTargetView: View {
    let action: ActionRouter.WatchActionInfo
    @EnvironmentObject private var router: ActionRouter
    @State private var shortcut = ""

    var body: some View {
        Form {
            Section {
                Picker("Destination", selection: Binding(
                    get: { router.target(for: action.id) },
                    set: { router.setTarget($0, for: action.id) }
                )) {
                    ForEach(action.targets) { Text(LocalizedStringKey($0.label)).tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
            } header: {
                Label(LocalizedStringKey(action.label), systemImage: action.symbol)
            }
            switch router.target(for: action.id) {
            case .webhook:
                Section {
                    Text("POST JSON to the configured URL (Settings → Webhook server) with `{\"action\": \"\(action.id)\", …}` — the receiver must answer 2xx.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .shortcut:
                Section {
                    TextField("Shortcut name", text: $shortcut)
                        .onSubmit { router.setShortcut(shortcut, for: action.id) }
                    Button("Save") { router.setShortcut(shortcut, for: action.id) }
                } footer: {
                    Text("iOS only opens a shortcut when the app is foregrounded: in background the action is ignored (visible in the log).")
                }
            case .appleMusic:
                Section {
                    Text("Controls the Apple Music player; the current title shows on the watch Music screen.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .macDaemon:
                Section {
                    Text("POST \(MacDaemonBridge.defaultURLDisplay)/cmd/\(action.id) to the Mac HTTP daemon (openaguja-macd, same Wi-Fi) with a Bearer token — works with the phone locked. Commands carry the action name; URL & token: Settings → Connections → Mac.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .ringPhone:
                Section {
                    Text("Alarm on the iPhone, even in silent mode and background, with the torch; stop from the app or auto after 60 s.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .phoneCamera:
                Section {
                    Text("The watch trigger takes a photo with the iPhone (saved to the library). iOS forbids it in background: a notification then asks to open the app. Framing: Settings → Phone → Camera.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .ignore:
                EmptyView()
            }
        }
        .navigationTitle(LocalizedStringKey(action.label))
        .onAppear { shortcut = router.shortcut(for: action.id) }
    }
}
