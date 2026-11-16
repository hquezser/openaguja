import SwiftUI
import OpenAgujaCore

/// Coquille de l'app : onglets Montre, Activité, Réglages toujours
/// visibles ; Routage uniquement en Mode Développeur. Les quatre piles
/// restent montées (opacité) pour préserver leur état quand un onglet
/// est masqué.
struct RootView: View {
    @SceneStorage("root.tab") private var tab = ZTTab.watch
    /// « dark » / « light » / « system » — piloté par Réglages → Apparence.
    @AppStorage("app.appearance") private var appearance = "system"
    /// Mode développeur : débloque l'onglet Routage et les outils avancés.
    @AppStorage("app.developerMode") private var developerMode = false

    @EnvironmentObject private var telemetryUploader: TelemetryUploader
    @State private var toast: LocalizedStringKey?
    @State private var toastTask: Task<Void, Never>?

    enum ZTTab: String, CaseIterable, Identifiable {
        case watch, activity, settings, routing

        var id: String { rawValue }

        var label: String {
            switch self {
            case .watch: return String(localized: "Watch")
            case .activity: return String(localized: "Activity")
            case .settings: return String(localized: "Settings")
            case .routing: return String(localized: "Routing")
            }
        }

        var symbol: String {
            switch self {
            case .watch: return "applewatch"
            case .activity: return "figure.walk"
            case .settings: return "gearshape"
            case .routing: return "arrow.triangle.branch"
            }
        }
    }

    /// Onglets visibles, dans l'ordre du prototype (Routage en dernier,
    /// seulement en mode développeur).
    private var visibleTabs: [ZTTab] {
        developerMode ? [.watch, .activity, .settings, .routing]
                      : [.watch, .activity, .settings]
    }

    var body: some View {
        ZStack {
            // Chaque onglet a sa propre pile de navigation : les
            // NavigationLink des vues poussent dans leur onglet.
            NavigationStack { WatchHomeView() }
                .opacity(tab == .watch ? 1 : 0)
                .allowsHitTesting(tab == .watch)
                .accessibilityHidden(tab != .watch)
            NavigationStack { ActivityView() }
                .opacity(tab == .activity ? 1 : 0)
                .allowsHitTesting(tab == .activity)
                .accessibilityHidden(tab != .activity)
            NavigationStack { AppSettingsView() }
                .opacity(tab == .settings ? 1 : 0)
                .allowsHitTesting(tab == .settings)
                .accessibilityHidden(tab != .settings)
            NavigationStack { RoutingView() }
                .opacity(tab == .routing ? 1 : 0)
                .allowsHitTesting(tab == .routing)
                .accessibilityHidden(tab != .routing)
        }
        .background(ZTColor.background.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            ZTToast(message: toast)
                .padding(.bottom, 96)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ZTTabBar(selection: $tab, tabs: visibleTabs,
                     badge: developerMode ? telemetryUploader.queuedCount : 0)
        }
        .preferredColorScheme(colorScheme)
        .onAppear(perform: applyLaunchArguments)
        .onChange(of: developerMode) { on in
            // Quitter le mode développeur depuis Routage → retour Réglages.
            if !on && tab == .routing { tab = .settings }
        }
        .environment(\.ztShowToast) { message in
            showToast(message)
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    private func showToast(_ message: LocalizedStringKey) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { toast = nil }
        }
    }

    #if DEBUG
    /// Arguments de lancement DEBUG :
    ///   -OAInitialTab montre|activite|reglages|routage
    ///   -OAOpenSheet webhook   (ouvre la feuille Serveur Webhook)
    private func applyLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-OAInitialTab"), i + 1 < args.count {
            switch args[i + 1].lowercased() {
            case "montre", "watch": tab = .watch
            case "activite", "activity": tab = .activity
            case "reglages", "settings": tab = .settings
            case "routage", "routing": tab = .routing
            default: break
            }
        }
        // -app.developerMode YES fonctionne nativement via UserDefaults.
        if args.contains("-OAOpenSheet"), let i = args.firstIndex(of: "-OAOpenSheet"),
           i + 1 < args.count, args[i + 1] == "webhook" {
            UserDefaults.standard.set("webhook", forKey: "oa.openSheet")
        }
    }
    #else
    private func applyLaunchArguments() {}
    #endif
}

/// Action « toast » injectée dans l'environnement pour les vues profondes.
private struct ZTShowToastKey: EnvironmentKey {
    static let defaultValue: (LocalizedStringKey) -> Void = { _ in }
}

extension EnvironmentValues {
    var ztShowToast: (LocalizedStringKey) -> Void {
        get { self[ZTShowToastKey.self] }
        set { self[ZTShowToastKey.self] = newValue }
    }
}

/// Barre d'onglets flottante : capsule translucide ; badge du compteur
/// de file de télémétrie sur Routage quand > 0.
private struct ZTTabBar: View {
    @Binding var selection: RootView.ZTTab
    let tabs: [RootView.ZTTab]
    var badge: Int = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs) { item in
                let on = selection == item
                Button {
                    selection = item
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 20, weight: .medium))
                            if item == .routing, badge > 0 {
                                Text("\(badge)")
                                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                                    .foregroundStyle(ZTColor.primaryForeground)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(ZTColor.warning, in: Capsule())
                                    .offset(x: 8, y: -4)
                            }
                        }
                        Text(item.label)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(on ? ZTColor.primary : ZTColor.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if on {
                            Capsule().fill(ZTColor.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(ZTColor.stroke, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }
}

// MARK: - Composants partagés

/// Pastille d'état de connexion (couleur + libellé).
struct ConnectionBadge: View {
    let state: ZeTimeBluetoothManager.ConnectionState
    let ready: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZTStatusDot(color: color)
            Text(ready ? "Connected" : state.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        if ready { return ZTColor.success }
        switch state {
        case .connected, .connecting, .scanning: return ZTColor.warning
        default: return ZTColor.danger
        }
    }
}

/// Bandeau d'erreur ou de succès sous un formulaire.
struct StatusFooter: View {
    let error: String?
    var success: String?

    var body: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(ZTColor.danger)
                .font(.footnote)
        } else if let success {
            Label("\(success) : applied", systemImage: "checkmark.circle.fill")
                .foregroundStyle(ZTColor.success)
                .font(.footnote)
        }
    }
}

/// Avertissement affiché quand la montre n'est pas prête.
struct NotConnectedHint: View {
    @EnvironmentObject private var bluetooth: ZeTimeBluetoothManager

    var body: some View {
        if !bluetooth.isReady {
            Label("Watch not connected: changes will not be sent.", systemImage: "antenna.radiowaves.left.and.right.slash")
                .font(.footnote)
                .foregroundStyle(ZTColor.warning)
        }
    }
}

extension Date {
    /// « il y a 5 min » — format relatif dans la locale courante.
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale.current
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: Date())
    }
}
