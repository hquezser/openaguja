import SwiftUI
import UIKit
import UniformTypeIdentifiers
import OpenAgujaCore

/// Onglet Réglages — structure du prototype `SettingsTab` : mode
/// développeur, apparence, connexions, capteurs & batterie, profil,
/// debug et à propos. Réutilise les sous-vues existantes.
struct AppSettingsView: View {
    @EnvironmentObject private var bluetooth: ZeTimeBluetoothManager
    @EnvironmentObject private var bridge: WebhookBridge
    @EnvironmentObject private var macd: MacDaemonBridge
    @EnvironmentObject private var router: ActionRouter
    @EnvironmentObject private var telemetry: TelemetryUploader
    @EnvironmentObject private var log: LogStore
    @EnvironmentObject private var settings: WatchSettingsModel
    @EnvironmentObject private var weather: WeatherService
    @AppStorage("app.appearance") private var appearance = "system"
    @AppStorage("app.developerMode") private var developerMode = false
    /// Profil énergétique persisté (clé partagée avec `EnergyProfile`).
    @AppStorage(EnergyProfile.storageKey) private var energyProfileRaw = EnergyProfile.balanced.rawValue
    @State private var showWebhook = false
    @State private var showMacd = false
    @State private var showJournal = false
    @State private var showProfileImporter = false
    @State private var showMemoryDump = false
    @State private var showTelemetryHistory = false
    @State private var profileShare: ShareItem?
    @State private var profileMessage: String?

    private var energyProfile: EnergyProfile {
        EnergyProfile(rawValue: energyProfileRaw) ?? .balanced
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                ZTLargeTitle("Settings")
                developerRow
                appearanceSection
                connectionsSection
                sensorsSection
                if developerMode { profileSection }
                if developerMode { debugSection }
                aboutSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showWebhook) { NavigationStack { WebhookServerView() } }
        .sheet(isPresented: $showMacd) {
            NavigationStack { MacDaemonSettingsView() }
        }
        .sheet(isPresented: $showJournal) { LogView() }
        .sheet(isPresented: $showMemoryDump) { NavigationStack { MemoryDumpView() } }
        .sheet(isPresented: $showTelemetryHistory) { TelemetryHistoryView() }
        .sheet(item: $profileShare) { item in ShareSheet(items: [item.url]) }
        .fileImporter(isPresented: $showProfileImporter, allowedContentTypes: [.json]) { result in
            importProfile(result)
        }
    }

    // MARK: - Developer mode

    private var developerRow: some View {
        ZTList {
            ZTRow(icon: "hammer", iconTint: ZTColor.primary, iconBg: ZTColor.primary,
                  label: "Developer mode",
                  sub: developerMode ? "Advanced tools enabled" : "Disabled") {
                Toggle("", isOn: $developerMode).labelsHidden().tint(ZTColor.primary)
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        ZTSection(title: "Appearance") {
            ZTList {
                HStack(spacing: 12) {
                    ZTIconTile(symbol: "circle.lefthalf.filled", tint: ZTColor.accent, bg: ZTColor.accent)
                    Text("Theme").font(.callout).foregroundStyle(ZTColor.foreground)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                ZTSegmented(options: [
                    ("dark", "Dark"), ("light", "Light"), ("system", "System"),
                ], selection: $appearance)
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
    }

    // MARK: - Connections

    private var connectionsSection: some View {
        ZTSection(title: "Connections") {
            ZTList {
                if developerMode {
                    ZTRow(icon: "network", label: "Webhook server",
                          sub: LocalizedStringKey(webhookSubtitle), value: webhookBadgeValue, chevron: true) {
                        showWebhook = true
                    }
                    ZTRowDivider()
                }
                NavigationLink { WeatherSettingsView() } label: {
                    ZTRow(icon: "cloud.sun.fill", iconTint: ZTColor.info, iconBg: ZTColor.info,
                          label: "Weather", sub: LocalizedStringKey(weatherSubtitle), chevron: true) { EmptyView() }
                }
                .buttonStyle(.plain)
                ZTRowDivider()
                NavigationLink { PhoneSettingsView() } label: {
                    ZTRow(icon: "iphone", iconTint: ZTColor.success, iconBg: ZTColor.success,
                          label: "Music, calls & alerts",
                          sub: "Apple Music, incoming calls, ringtone, camera", chevron: true) { EmptyView() }
                }
                .buttonStyle(.plain)
                if developerMode {
                    ZTRowDivider()
                    ZTRow(icon: "desktopcomputer", label: "Mac daemon",
                          sub: LocalizedStringKey(macdSubtitle), value: macdBadgeValue, chevron: true) {
                        showMacd = true
                    }
                }
            }
        }
    }

    // MARK: - Sensors & battery

    private var sensorsSection: some View {
        ZTSection(title: "Sensors & battery",
                  footer: "Only setting that drives auto heart-rate measure; spot measures in Activity.") {
            ZTList {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ZTIconTile(symbol: "bolt.fill", tint: ZTColor.success, bg: ZTColor.success, size: 24)
                        Text("Energy profile").font(.callout.weight(.medium)).foregroundStyle(ZTColor.foreground)
                    }
                    .padding(.horizontal, 16).padding(.top, 12)
                    Picker("Energy profile", selection: Binding(
                        get: { energyProfile },
                        set: { apply($0) }
                    )) {
                        ForEach(EnergyProfile.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    Text(LocalizedStringKey(energyProfile.detail))
                        .font(.caption).foregroundStyle(ZTColor.muted)
                        .padding(.horizontal, 16)
                    if bluetooth.isReady {
                        ZTInfoRow(title: String(localized: "Watch HR interval"),
                                  value: settings.heartRateInterval > 0 ? "every \(settings.heartRateInterval) min" : "off",
                                  symbol: "heart.fill", valueTint: ZTColor.danger)
                    } else {
                        Text("Watch disconnected: the profile is saved and applied at next connection if reachable.")
                            .font(.caption).foregroundStyle(ZTColor.muted)
                            .padding(.horizontal, 16)
                    }
                    Text("Single source of truth: the watch's “Auto HR measure” setting follows this profile (Settings → Watch → Health).")
                        .font(.caption2).foregroundStyle(ZTColor.muted.opacity(0.7))
                        .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
        }
    }

    private func apply(_ profile: EnergyProfile) {
        energyProfileRaw = profile.rawValue
        Task {
            await settings.apply(.setHeartRateInterval(minutes: profile.heartRateMinutes),
                                 label: String(localized: "Energy profile"), on: bluetooth)
        }
    }

    // MARK: - Profile (dev)

    private var profileSection: some View {
        ZTSection(title: "Profile") {
            ZTList {
                VStack(alignment: .leading, spacing: 10) {
                    Text("A JSON profile holds the webhook config, Mac daemon URL, routing targets and contextual modes — never a token.")
                        .font(.footnote).foregroundStyle(ZTColor.muted)
                        .padding(.horizontal, 16).padding(.top, 12)
                    HStack(spacing: 10) {
                        Button { exportProfile() } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        Button { showProfileImporter = true } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 16)
                    if let profileMessage {
                        Text(profileMessage).font(.footnote).foregroundStyle(ZTColor.muted)
                            .padding(.horizontal, 16)
                    }
                    Spacer().frame(height: 8)
                }
            }
        }
    }

    private func exportProfile() {
        do {
            let data = try AppProfile.export().jsonData()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("openaguja-profile.json")
            try data.write(to: url, options: .atomic)
            profileShare = ShareItem(url: url)
            profileMessage = "Profile exported — tokens are never included."
        } catch {
            profileMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importProfile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            profileMessage = "Import failed: \(error.localizedDescription)"
            return
        case .success(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let profile = try AppProfile.decode(data)
                try profile.apply()
                bridge.reload(); macd.reload(); router.reload()
                if profile.modes != nil, #available(iOS 17.0, *) {
                    ZeTimeShortcuts.updateAppShortcutParameters()
                }
                profileMessage = "Profile imported."
            } catch {
                profileMessage = "Import refused: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Debug (dev)

    private var debugSection: some View {
        ZTSection(title: "Debug") {
            ZTList {
                Button { showJournal = true } label: {
                    ZTRow(icon: "list.bullet.rectangle", label: "Technical log",
                          sub: "\(log.entries.count) entr(y/ies) · frames, errors, calls",
                          value: "\(frameCount) / \(httpCount)", chevron: true) { EmptyView() }
                }
                .buttonStyle(.plain)
                ZTRowDivider()
                Button { showMemoryDump = true } label: {
                    ZTRow(icon: "memorychip", iconTint: ZTColor.warning, iconBg: ZTColor.warning,
                          label: "Memory dump / init (lab)", sub: "Low-level diagnostics", chevron: true) { EmptyView() }
                }
                .buttonStyle(.plain)
                if !bridge.config.telemetryHistoryURL.isEmpty {
                    ZTRowDivider()
                    Button { showTelemetryHistory = true } label: {
                        ZTRow(icon: "chart.bar.xaxis", label: "Telemetry history",
                              sub: "Server charts (sleep, HR, steps)", chevron: true) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var frameCount: Int {
        log.entries.reduce(0) { $0 + (($1.category == .tx || $1.category == .rx) ? 1 : 0) }
    }
    private var httpCount: Int {
        log.entries.reduce(0) { $0 + ($1.category == .http ? 1 : 0) }
    }

    // MARK: - About

    private var aboutSection: some View {
        ZTSection(title: "About") {
            ZTList {
                ZTInfoRow(title: String(localized: "Version"), value: appVersion, symbol: "info.circle", valueTint: .primary)
                if let firmware = bluetooth.firmware {
                    ZTInfoRow(title: String(localized: "Watch firmware"), value: firmware, symbol: "applewatch", valueTint: .primary)
                }
                aboutLink("doc.text", "ZeTime protocol — artificialred.nl",
                          "artificialred.nl", "https://zetime.artificialred.nl")
                ZTRowDivider()
                aboutLink("shield.lefthalf.filled", "License", "AGPL-3.0",
                          "https://github.com/hquezser/openaguja/blob/main/LICENSE")
                ZTRowDivider()
                aboutLink("chevron.left.forwardslash.chevron.right", "Source code",
                          "github.com/hquezser/openaguja",
                          "https://github.com/hquezser/openaguja")
                ZTRowDivider()
                aboutLink("cloud", "Weather data — Open-Meteo", "open-meteo.com",
                          "https://open-meteo.com")
                ZTRowDivider()
                aboutLink("link", "Gadgetbridge", "codeberg.org",
                          "https://codeberg.org/Freeyourgadget/Gadgetbridge")
            }
            Text("Not affiliated with MyKronoz.")
                .font(.caption).foregroundStyle(ZTColor.muted)
                .padding(.horizontal, 16).padding(.top, 8)
        }
    }

    private func aboutLink(_ symbol: String, _ label: LocalizedStringKey, _ value: String,
                           _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            ZTRow(icon: symbol, label: label, value: LocalizedStringKey(value), chevron: true) { EmptyView() }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Subtitles / badges

    private var macdHost: String {
        guard let url = URL(string: macd.baseURL), let host = url.host else {
            return macd.baseURL.isEmpty ? String(localized: "not configured") : macd.baseURL
        }
        return host
    }
    private var macdSubtitle: String {
        let http = macd.lastHTTPStatus ?? macd.lastTestStatus
        if let http { return http == 0 ? "\(macdHost) · offline" : "\(macdHost) · HTTP \(http)" }
        return "\(macdHost) · openaguja-macd"
    }
    private var macdBadgeValue: LocalizedStringKey {
        let status = macd.lastHTTPStatus ?? macd.lastTestStatus
        guard let status else { return "" }
        if status == 0 { return "offline" }
        if (200...299).contains(status) { return "OK" }
        return LocalizedStringKey("HTTP \(status)")
    }
    private var webhookHost: String {
        guard let url = URL(string: bridge.config.actionURL), let host = url.host else {
            return bridge.config.actionURL.isEmpty ? String(localized: "not configured") : bridge.config.actionURL
        }
        return host
    }
    private var webhookSubtitle: String {
        if bridge.config.actionURL.isEmpty { return String(localized: "URL & token to set") }
        let http = bridge.lastHTTPStatus ?? bridge.lastTestStatus
        if let http { return http == 0 ? "\(webhookHost) · offline" : "\(webhookHost) · HTTP \(http)" }
        return webhookHost
    }
    private var webhookBadgeValue: LocalizedStringKey {
        let status = bridge.lastHTTPStatus ?? bridge.lastTestStatus
        guard !bridge.config.actionURL.isEmpty, let status else { return "" }
        if status == 0 { return "offline" }
        if (200...299).contains(status) { return "OK" }
        return LocalizedStringKey("HTTP \(status)")
    }
    private var weatherSubtitle: String {
        guard let snapshot = weather.snapshot else { return weather.enabled ? "on" : "off" }
        return "\(snapshot.place) · \(Int(snapshot.currentC.rounded())) °C"
    }
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

// MARK: - Daemon Mac

/// Réglages du daemon HTTP local (`openaguja-macd` sur macOS) : URL,
/// jeton Bearer et test de connexion.
struct MacDaemonSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var macd: MacDaemonBridge
    @State private var url = ""
    @State private var token = ""
    @State private var currentToken = ""
    @State private var revealed = false
    @State private var copied = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Server") {
                TextField(MacDaemonBridge.urlPlaceholder, text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("New token (empty = unchanged)", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                tokenRow
            }
            Section {
                Button("Save") {
                    macd.save(baseURL: url, token: token)
                    token = ""
                    reloadToken()
                }
                Button {
                    testing = true
                    testResult = nil
                    Task {
                        let result = await macd.testConnection()
                        await MainActor.run {
                            testResult = result
                            testing = false
                        }
                    }
                } label: {
                    HStack {
                        Text("Test connection")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing || url.isEmpty)
                if let testResult {
                    let ok = macd.lastTestStatus.map { (200...299).contains($0) } ?? false
                    Label(testResult, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(ok ? ZTColor.success : ZTColor.danger)
                } else if let status = macd.lastTestStatus {
                    LabeledContent("Last test", value: "HTTP \(status)")
                }
            } footer: {
                Text("Each action routed to “Mac (local HTTP)” sends POST <url>/cmd/<action> with a Bearer token — works with the iPhone locked, same Wi-Fi only. Commands: Routing tab → each action’s target.")
            }
        }
        .navigationTitle("Mac daemon")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Close") { dismiss() }
            }
        }
        .onAppear {
            url = macd.baseURL
            reloadToken()
        }
        .alert("Copied to clipboard", isPresented: $copied) {
            Button("OK", role: .cancel) {}
        }
    }

    private var tokenRow: some View {
        Group {
            if currentToken.isEmpty {
                LabeledContent("Current token", value: String(localized: "none"))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.secondary)
                    if revealed {
                        Text(currentToken)
                            .font(.subheadline.monospaced())
                            .lineLimit(1)
                            .textSelection(.enabled)
                    } else {
                        Text(Self.mask(currentToken))
                            .font(.subheadline.monospaced())
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(revealed ? "Hide token" : "Show token")
                    Button {
                        UIPasteboard.general.string = currentToken
                        copied = true
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copy token")
                }
            }
        }
    }

    private func reloadToken() {
        currentToken = Keychain.macdToken() ?? ""
        revealed = false
    }

    private static func mask(_ token: String) -> String {
        guard token.count > 12 else { return String(repeating: "•", count: max(token.count, 4)) }
        return "\(token.prefix(7))…\(token.suffix(4))"
    }
}

// MARK: - Météo

/// Ligne récap du dernier relevé météo (icône + lieu + températures).
struct WeatherRow: View {
    let snapshot: WeatherService.Snapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: WeatherService.symbol(wmo: snapshot.wmoCode, isDay: snapshot.isDay))
                .symbolRenderingMode(.multicolor)
                .font(.title)
            VStack(alignment: .leading) {
                Text(snapshot.place)
                    .font(.headline)
                Text("\(Int(snapshot.currentC.rounded())) °C · min \(Int(snapshot.minC.rounded()))° max \(Int(snapshot.maxC.rounded()))°")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(snapshot.fetchedAt.relative)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct WeatherSettingsView: View {
    @EnvironmentObject private var weather: WeatherService
    @EnvironmentObject private var bluetooth: ZeTimeBluetoothManager
    @State private var city = ""

    var body: some View {
        Form {
            Section {
                Toggle("Send weather to watch", isOn: $weather.enabled)
                Picker("Place", selection: $weather.source) {
                    ForEach(WeatherService.Source.allCases) { Text($0.label).tag($0) }
                }
                if weather.source == .city {
                    HStack {
                        TextField("City", text: $city)
                            .onSubmit { Task { await weather.setCity(city) } }
                        Button("Search") { Task { await weather.setCity(city) } }
                            .disabled(city.isEmpty || weather.busy)
                    }
                    if !weather.cityName.isEmpty {
                        LabeledContent("Chosen city", value: weather.cityName)
                    }
                }
            } footer: {
                Text("Updated on each watch connection and hourly while the app runs.")
            }
            Section {
                if let snapshot = weather.snapshot {
                    WeatherRow(snapshot: snapshot)
                    ForEach(Array(snapshot.days.enumerated()), id: \.offset) { i, day in
                        HStack {
                            Text(Calendar.current.date(byAdding: .day, value: i + 1, to: Date())?.formatted(.dateTime.weekday(.wide)) ?? "")
                            Spacer()
                            Image(systemName: WeatherService.symbol(wmo: day.wmoCode))
                                .symbolRenderingMode(.multicolor)
                            Text("\(Int(day.minC.rounded()))° / \(Int(day.maxC.rounded()))°")
                                .monospacedDigit()
                                .frame(width: 80, alignment: .trailing)
                        }
                    }
                }
                Button {
                    Task { await weather.refresh(sendTo: bluetooth) }
                } label: {
                    HStack {
                        Text("Refresh & send")
                        if weather.busy {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(weather.busy || !weather.enabled)
                StatusFooter(error: weather.lastError)
            } header: {
                Text("Last reading")
            }
        }
        .navigationTitle("Weather")
        .onAppear { city = weather.cityName }
    }
}

// MARK: - Téléphone

struct PhoneSettingsView: View {
    @EnvironmentObject private var music: MusicController
    @EnvironmentObject private var calls: CallMonitor
    @EnvironmentObject private var phone: PhoneActions
    @EnvironmentObject private var router: ActionRouter

    var body: some View {
        Form {
            Section {
                LabeledContent("In progress", value: music.nowPlaying ?? "—")
                LabeledContent("State", value: music.isPlaying ? "Lecture" : "Stopped")
                LabeledContent("Music buttons", value: router.target(for: "play").label)
            } header: {
                Text("Apple Music")
            } footer: {
                Text("When music buttons are routed to Apple Music, the current title shows on the watch. On the watch Music screen: the default player follows the configured webhook and Spotify follows routing (Routing), Deezer drives the Deezer app directly (experimental).")
            }
            Section {
                Toggle("Show incoming calls", isOn: $calls.enabled)
            } header: {
                Text("Calls")
            } footer: {
                Text("iOS does not pass the caller’s name or number to apps: the watch shows “Incoming call”. Works while the app is active or woken by the watch.")
            }
            Section {
                if phone.alarmRinging {
                    Button("Stop ringtone", role: .destructive) { phone.stopAlarm() }
                } else {
                    Button("Test ringtone") { phone.startAlarm() }
                }
            } header: {
                Text("Find my phone")
            } footer: {
                Text("Rings even in silent mode, with the torch, and stops by itself after 60 s.")
            }
            Section {
                NavigationLink {
                    CameraView(phone: phone)
                } label: {
                    LabeledContent("Camera", value: phone.cameraArmed ? "armed" : "to frame")
                }
            } header: {
                Text("Camera")
            } footer: {
                Text("The watch trigger takes a photo with the iPhone, saved to the library. iOS only allows capture with the app in front: in background a notification asks to open the app.")
            }
        }
        .navigationTitle("Phone")
    }
}
