import CoreBluetooth
import Foundation

#if canImport(UIKit)
    import UIKit // significantTimeChangeNotification (iOS uniquement)
#endif
#if canImport(OpenAgujaCore)
    import OpenAgujaCore // bindings UniFFI (déjà dans le module en typecheck)
#endif

/// Erreurs des échanges requête/réponse avec la montre.
enum WatchError: LocalizedError {
    case notConnected
    case timeout(String)
    case refused(String, UInt8)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return String(localized: "Watch not connected")
        case .timeout(let what): return String(localized: "No response from watch (\(what))")
        case .refused(let what, let status): return String(localized: "Refused by watch (\(what), code \(status))")
        case .invalid(let what): return what
        }
    }
}

/// Trame reçue, découpée : octet commande, type, charge utile.
struct RawFrame {
    let bytes: Data
    var cmd: UInt8 { bytes.count > 1 ? bytes[bytes.startIndex + 1] : 0 }
    var kind: UInt8 { bytes.count > 2 ? bytes[bytes.startIndex + 2] : 0 }
    /// Octets 5..<n-1 (sans en-tête ni 0x8F final).
    var payload: Data {
        bytes.count >= 6 ? bytes.subdata(in: (bytes.startIndex + 5)..<(bytes.endIndex - 1)) : Data()
    }
}

/// Connexion BLE à la montre ZeTime : scan/pairing, réassemblage des trames,
/// encodage via le cœur Rust (openaguja-ffi), échanges requête/réponse
/// sérialisés, et remontée des actions de la montre vers `actionHandler`.
final class ZeTimeBluetoothManager: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case bluetoothOff, unauthorized, unsupported, scanning, connecting, connected, disconnected

        var label: String {
            switch self {
            case .bluetoothOff: return String(localized: "Bluetooth off")
            case .unauthorized: return String(localized: "Bluetooth not authorized")
            case .unsupported: return String(localized: "Bluetooth not handled")
            case .scanning: return String(localized: "Looking for watch…")
            case .connecting: return String(localized: "Connecting…")
            case .connected: return String(localized: "Connected")
            case .disconnected: return String(localized: "Disconnected")
            }
        }
    }

    /// Progression d'un dump mémoire en cours (lab 0xEE), `nil` au repos.
    @Published var dumpProgress: Double?

    @Published private(set) var state: ConnectionState = .disconnected
    /// Vrai une fois les caractéristiques TX/ACK/réponse découvertes.
    @Published private(set) var isReady = false
    @Published private(set) var peripheralName: String?
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var batteryDate: Date?
    @Published private(set) var lastAction: String?
    @Published private(set) var lastActionDate: Date?
    @Published private(set) var firmware: String?
    @Published private(set) var hardware: String?
    @Published private(set) var serial: String?
    /// Dernier RSSI lu sur le lien (dBm) — affiché dans la carte Montre.
    @Published private(set) var rssi: Int?
    @Published private(set) var pairingCandidates: [PairingCandidate] = []
    @Published private(set) var pairingCandidatesOverflow = false

    struct PairingCandidate: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int?
    }

    /// Action de la montre (id stable : play, next, volume_up…, + action brute).
    var actionHandler: ((String, WatchAction) -> Void)?
    /// Appelé à chaque connexion prête (synchro heure, météo…).
    var onReady: (() -> Void)?

    let log: LogStore

    private static let peripheralIDKey = "zetime.peripheralID"
    private static let trustedPeripheralIDKey = "zetime.trustedPeripheralID"
    private static let maxPairingCandidates = 16

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var candidatePeripherals: [UUID: CBPeripheral] = [:]
    /// Périphérique restauré par iOS (state restoration) — prioritaire.
    private var restoredPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var ackCharacteristic: CBCharacteristic?
    private var replyCharacteristic: CBCharacteristic?
    private var reassemblers: [CBUUID: FrameReassembler] = [:]
    private var didInitialSync = false

    /// Attentes de trame en cours (main thread uniquement).
    private struct Waiter {
        let match: (RawFrame) -> Bool
        let resume: (Result<RawFrame, Error>) -> Void
    }

    private var waiters: [UUID: Waiter] = [:]
    /// Collectes multi-trames en cours (main thread uniquement).
    private var collectors: [UUID: (match: (RawFrame) -> Bool, collector: FrameCollector)] = [:]
    /// Fin de la file des échanges sérialisés.
    private var queueTail: Task<Void, Never>?

    /// État musique renvoyé à la montre sur le canal réponse (0x8003).
    @Published private(set) var musicPlaying = false
    @Published private(set) var musicTitle = ""
    private(set) var musicVolume: UInt8 = 50

    /// Lecteur choisi sur l'écran Musique de la montre (octet source de la
    /// requête d'état 0xD0). Ordre observé sur l'iPhone le 2026-10-29 :
    /// 1 = Deezer, 2 = Spotify (l'inverse de l'hypothèse initiale) ; le
    /// lecteur par défaut (0) porte le nom du webhook configuré.
    struct MusicSource: Equatable {
        let id: String
        let name: String
    }

    /// Source 0 : le webhook HTTP configuré (`WebhookConfig.name`,
    /// "Webhook" par défaut) — relue à chaque requête pour suivre les
    /// changements de réglages.
    static func defaultMusicSource() -> MusicSource {
        MusicSource(id: "default", name: WebhookConfig.load().name)
    }

    private static let musicSources: [UInt8: MusicSource] = [
        1: MusicSource(id: "deezer", name: "Deezer"),
        2: MusicSource(id: "spotify", name: "Spotify"),
    ]
    /// Actions qui dépendent du lecteur choisi sur la montre.
    static let musicActionIds: Set<String> = [
        "play", "pause", "previous", "next", "volume", "volume_up", "volume_down",
    ]
    /// Webhook tant que la montre n'a rien demandé.
    @Published private(set) var musicSource = ZeTimeBluetoothManager.defaultMusicSource()
    /// L'ouverture d'un lecteur sur la montre envoie son octet (1/2) puis,
    /// 1 à 1,6 s plus tard, une requête à 0 (journal du 2026-10-29) : un 0
    /// dans cette fenêtre n'est pas un choix du webhook.
    private static let sourceEchoWindow: TimeInterval = 3
    private var lastPlayerSourceDate: Date?
    private var pendingMusicVolume: UInt8?
    var musicSourceHandler: ((MusicSource) -> Void)?
    /// Push cardio temps réel 0xE2 `[bpm:1]` — appelé à chaque mesure.
    var realTimeHeartRateHandler: ((UInt8) -> Void)?
    /// Télémétrie : chaque trame complète reçue (réponses 0x8002 +
    /// événements 0x8004), consommée ou non par les attentes/collectes.
    var telemetryFrameHandler: ((Data) -> Void)?
    /// Télémétrie `ble_status` : signaux de lien CoreBluetooth.
    var telemetryPresenceHandler: ((WatchPresenceSignal) -> Void)?
    /// Cache de la table 0x2E bouton→fonction — sert à résoudre le
    /// `button_id` des événements `button` (relue à chaque connexion).
    /// Écrit par `refreshButtonFunctions` (WatchAPI.swift).
    @Published var buttonFunctions: [ButtonFunction] = []
    private var rssiTimer: Timer?

    init(log: LogStore) {
        self.log = log
        super.init()
        // queue: nil → callbacks sur le main thread, où vivent les @Published.
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey: "OpenAguja.central",
                CBCentralManagerOptionShowPowerAlertKey: true,
            ]
        )
        #if canImport(UIKit)
            // Resynchronise l'heure sur changement d'heure (DST, fuseau).
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(significantTimeChange),
                name: UIApplication.significantTimeChangeNotification,
                object: nil
            )
            // Renommage du webhook dans les réglages : la source par
            // défaut suit le nouveau nom sans attendre la prochaine
            // requête 0xD0 de la montre.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(webhookConfigChanged),
                name: .webhookConfigDidChange,
                object: nil
            )
        #endif
        musicTitle = musicSource.name
    }

    // MARK: - Commandes simples (sans attente)

    /// Synchronise la date/heure de la montre sur l'heure du téléphone.
    func syncTime() {
        let now = Date()
        do {
            try send(encodeSetTime(
                unixSeconds: Int64(now.timeIntervalSince1970),
                utcOffsetSeconds: Int32(TimeZone.current.secondsFromGMT(for: now))
            ), label: String(localized: "Time sync"))
        } catch {
            log.add(.error, "Time sync: \(error.localizedDescription)")
        }
    }

    func sendNotification(kind: NotificationKind, title: String, body: String) {
        let now = Date()
        do {
            try send(encodeNotification(
                kind: kind,
                title: title,
                body: body,
                unixSeconds: Int64(now.timeIntervalSince1970),
                utcOffsetSeconds: Int32(TimeZone.current.secondsFromGMT(for: now))
            ), label: String(localized: "Notification"))
        } catch {
            log.add(.error, "Notification : \(error.localizedDescription)")
        }
    }

    func sendIncomingCall(caller: String) {
        let now = Date()
        do {
            try send(encodeIncomingCall(
                caller: caller,
                unixSeconds: Int64(now.timeIntervalSince1970),
                utcOffsetSeconds: Int32(TimeZone.current.secondsFromGMT(for: now))
            ), label: String(localized: "Incoming call"))
        } catch {
            log.add(.error, "Call: \(error.localizedDescription)")
        }
    }

    func sendCallEnded() {
        let now = Date()
        do {
            try send(encodeCallEnded(
                unixSeconds: Int64(now.timeIntervalSince1970),
                utcOffsetSeconds: Int32(TimeZone.current.secondsFromGMT(for: now))
            ), label: String(localized: "Call ended"))
        } catch {
            log.add(.error, "Call ended: \(error.localizedDescription)")
        }
    }

    /// Envoi d'une commande typée sans attendre son ack.
    func fire(_ command: WatchCommand, label: String) {
        do {
            try send(encodeCommand(command: command), label: label)
        } catch {
            log.add(.error, "\(label) : \(error.localizedDescription)")
        }
    }

    func findWatch(start: Bool) {
        fire(.findDevice(start: start), label: start ? "Faire sonner" : "Stop ringtone")
    }

    func requestBattery() {
        fire(.getBattery, label: String(localized: "Battery"))
    }

    /// État + titre poussés à l'écran Musique de la montre.
    func updateMusic(playing: Bool, title: String) {
        musicPlaying = playing
        musicTitle = title.isEmpty ? musicSource.name : title
        sendMusicState()
    }

    /// Volume à transmettre à la montre lors de la requête de suivi qui
    /// suit le choix d'un lecteur (la 1re réponse doit rester seule).
    func setMusicVolumeOnNextRequest(_ level: UInt8) {
        musicVolume = level
        pendingMusicVolume = level
    }

    /// Titre et état à afficher lors de la requête de suivi (même raison).
    func setMusicDisplayOnNextRequest(playing: Bool, title: String) {
        musicPlaying = playing
        musicTitle = title
    }

    func updateMusicVolume(_ level: UInt8) {
        musicVolume = level
        do {
            try sendReply(encodeMusicVolume(level: level), label: String(localized: "Music volume"))
        } catch {
            log.add(.error, "Music volume: \(error.localizedDescription)")
        }
    }

    /// Oublie la montre et repart en recherche (nouveau pairing).
    func forgetWatch() {
        UserDefaults.standard.removeObject(forKey: Self.peripheralIDKey)
        UserDefaults.standard.removeObject(forKey: Self.trustedPeripheralIDKey)
        // Détachée avant l'annulation : son didDisconnect sera ignoré (pas
        // de reconnexion) car ce n'est plus le périphérique courant.
        let old = peripheral
        peripheral = nil
        restoredPeripheral = nil
        peripheralName = nil
        batteryLevel = nil
        firmware = nil
        hardware = nil
        serial = nil
        markDisconnected()
        if let old {
            central.cancelPeripheralConnection(old)
        }
        log.add(.info, "Watch forgotten")
        if central.state == .poweredOn {
            scanForPairing()
        }
    }

    /// Enregistre uniquement un périphérique choisi explicitement dans
    /// l'interface, puis conserve la reconnexion automatique par son ID iOS.
    func pairWithWatch(_ id: UUID) {
        guard let candidate = candidatePeripherals[id],
              pairingCandidates.contains(where: { $0.id == id })
        else { return }
        central.stopScan()
        UserDefaults.standard.set(id.uuidString, forKey: Self.peripheralIDKey)
        UserDefaults.standard.set(id.uuidString, forKey: Self.trustedPeripheralIDKey)
        pairingCandidates.removeAll()
        pairingCandidatesOverflow = false
        candidatePeripherals.removeAll()
        pendingQrBind = true
        log.add(.info, "Selected watch pairing")
        attach(to: candidate)
    }

    /// Vrai juste après un appairage explicite : la séquence QR bind
    /// (0x93 → heure → 0x94[0x01]) ne part qu'une fois, à la prochaine
    /// connexion — jamais sur les reconnexions ordinaires.
    private(set) var pendingQrBind = false

    /// Séquence de bind QR (Android pairing) : `0x93 SET [0x02]` → synchro
    /// heure → `0x94 SET [0x01]`. Referme l'écran QR de la montre.
    /// À n'appeler qu'après un appairage (`pendingQrBind`).
    @MainActor
    func completeQrBind() async {
        pendingQrBind = false
        do {
            try await perform(.qrBindStart, label: String(localized: "Bind QR: start"))
            try? await Task.sleep(nanoseconds: 300_000_000)
            syncTime()
            try? await Task.sleep(nanoseconds: 300_000_000)
            try await perform(.bindEnd, label: String(localized: "QR bind: end"))
            log.add(.info, "Bind QR done")
        } catch {
            log.add(.error, "Bind QR : \(error.localizedDescription)")
        }
    }

    private func scanForPairing() {
        central.stopScan()
        pairingCandidates.removeAll()
        pairingCandidatesOverflow = false
        candidatePeripherals.removeAll()
        state = .scanning
        central.scanForPeripherals(withServices: nil)

        // Identifiant mémorisé par les anciennes versions : le proposer une
        // fois à confirmation au lieu de lui accorder rétroactivement confiance.
        let trustedID = UserDefaults.standard.string(forKey: Self.trustedPeripheralIDKey)
            .flatMap(UUID.init(uuidString:))
        if trustedID == nil,
           let raw = UserDefaults.standard.string(forKey: Self.peripheralIDKey),
           let legacyID = UUID(uuidString: raw),
           let p = central.retrievePeripherals(withIdentifiers: [legacyID]).first
        {
            addPairingCandidate(p, name: p.name ?? "ZeTime saved", rssi: nil)
        }

        let services = gattUuids().services.map { CBUUID(string: $0) }
        for p in central.retrieveConnectedPeripherals(withServices: services) {
            let name = p.name ?? ""
            if name.localizedCaseInsensitiveContains("zetime") {
                if p.identifier == trustedID {
                    central.stopScan()
                    attach(to: p)
                    return
                }
                addPairingCandidate(p, name: name, rssi: nil)
            }
        }
    }

    func rescanForPairing() {
        guard central.state == .poweredOn else { return }
        scanForPairing()
    }

    // MARK: - Échanges requête/réponse (sérialisés)

    /// Envoie une requête (GET) et renvoie la charge utile de sa réponse.
    @MainActor
    func request(_ command: WatchCommand, label: String, timeout: TimeInterval = 4) async throws -> Data {
        let code = try commandCode(command: command)
        let frame = try encodeCommand(command: command)
        return try await exclusive {
            try await self.sendAndWait(frame, label: label, timeout: timeout) { f in
                f.cmd == code && f.kind == 0x80 || Self.isRefusal(f, of: code)
            }.unwrapReply(code: code, label: label)
        }
    }

    /// Envoie une commande (SET) et attend son ack : lève une erreur si la
    /// montre refuse ou ne répond pas.
    @MainActor
    func perform(_ command: WatchCommand, label: String, timeout: TimeInterval = 4) async throws {
        let code = try commandCode(command: command)
        let frame = try encodeCommand(command: command)
        _ = try await exclusive {
            let ack = try await self.sendAndWait(frame, label: label, timeout: timeout) { f in
                f.cmd == 0x01 && f.kind == 0x81 && f.payload.first == code || Self.isRefusal(f, of: code)
            }
            let status = ack.payload.count > 1 ? ack.payload[ack.payload.startIndex + 1] : 0xFF
            guard status == 0, ack.payload.first == code else { throw WatchError.refused(label, status) }
            self.log.add(.info, "\(label) : OK")
        }
    }

    /// Résultat d'une collecte multi-trames : `complete` est faux si la
    /// montre s'est tue avant la dernière trame attendue.
    struct Collected {
        let payloads: [Data]
        let complete: Bool
    }

    /// Requête dont la réponse arrive en plusieurs trames (enregistrements
    /// d'activité, alarmes) : collecte jusqu'à ce que `isLast` renvoie vrai
    /// ou qu'aucune trame n'arrive pendant `idleTimeout`.
    @MainActor
    func collect(
        _ command: WatchCommand,
        label: String,
        idleTimeout: TimeInterval = 5,
        isLast: @escaping (Data) -> Bool
    ) async throws -> Collected {
        let code = try commandCode(command: command)
        let frame = try encodeCommand(command: command)
        return try await exclusive {
            guard self.isReady else { throw WatchError.notConnected }
            // Collecteur persistant (et non une attente par trame) : une
            // notification peut porter plusieurs trames d'affilée, traitées
            // avant que la tâche ait pu se réabonner.
            let collector = FrameCollector()
            let id = UUID()
            self.collectors[id] = (match: { f in
                f.cmd == code && f.kind == 0x80 || Self.isRefusal(f, of: code)
            }, collector: collector)
            defer {
                self.collectors.removeValue(forKey: id)
                collector.cancel()
            }
            guard self.send(frame, label: label) else { throw WatchError.notConnected }
            var payloads: [Data] = []
            while true {
                guard let next = await collector.next(timeout: idleTimeout) else {
                    if payloads.isEmpty { throw WatchError.timeout(label) }
                    self.log.add(.error, "\(label): collection stopped after \(payloads.count) frame(s)")
                    return Collected(payloads: payloads, complete: false)
                }
                if next.cmd != code {
                    throw WatchError.refused(label, next.payload.count > 1 ? next.payload[next.payload.startIndex + 1] : 0xFF)
                }
                payloads.append(next.payload)
                if isLast(next.payload) {
                    return Collected(payloads: payloads, complete: true)
                }
            }
        }
    }

    /// Refus d'une commande : code retour (GET 0x80 ou SET 0x81) qui
    /// l'échoit, ou réponse « opcode inconnu » (`6F 01 81 02 00 00 02 8F`,
    /// sans octet commande — attribuée à l'échange en cours).
    static func isRefusal(_ f: RawFrame, of code: UInt8) -> Bool {
        guard f.cmd == 0x01, let first = f.payload.first else { return false }
        if f.kind == 0x81, first == 0x00, f.payload.count > 1, f.payload[f.payload.startIndex + 1] == 0x02 {
            return true
        }
        return first == code && (f.kind == 0x80 || (f.kind == 0x81 && f.payload.count > 1 && f.payload[f.payload.startIndex + 1] != 0))
    }

    // MARK: - Interne

    @objc private func significantTimeChange() {
        syncTime()
    }

    /// La config webhook a changé (réglages, import de profil) : la
    /// source par défaut suit le nouveau nom sans attendre la prochaine
    /// requête 0xD0 de la montre.
    @objc private func webhookConfigChanged() {
        guard musicSource.id == "default" else { return }
        let source = Self.defaultMusicSource()
        guard source != musicSource else { return }
        musicSource = source
        musicTitle = source.name
        sendMusicState()
    }

    /// Une seule opération requête/réponse à la fois : les réponses ne
    /// portent que l'octet commande, deux échanges entremêlés se
    /// confondraient.
    @MainActor
    private func exclusive<T>(_ operation: @escaping () async throws -> T) async throws -> T {
        let previous = queueTail
        let task = Task { @MainActor () async throws -> T in
            _ = await previous?.value
            return try await operation()
        }
        queueTail = Task { _ = try? await task.value }
        return try await task.value
    }

    @MainActor
    private func sendAndWait(
        _ frame: Data,
        label: String,
        timeout: TimeInterval,
        match: @escaping (RawFrame) -> Bool
    ) async throws -> RawFrame {
        guard isReady else { throw WatchError.notConnected }
        // L'attente est enregistrée avant l'envoi : une réponse rapide ne
        // peut pas passer entre les deux.
        return try await withCheckedThrowingContinuation { continuation in
            let id = register(timeout: timeout, label: label, match: match) { continuation.resume(with: $0) }
            if !send(frame, label: label) {
                waiters.removeValue(forKey: id)?.resume(.failure(WatchError.notConnected))
            }
        }
    }

    private func register(
        timeout: TimeInterval,
        label: String,
        match: @escaping (RawFrame) -> Bool,
        resume: @escaping (Result<RawFrame, Error>) -> Void
    ) -> UUID {
        let id = UUID()
        waiters[id] = Waiter(match: match, resume: resume)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.waiters.removeValue(forKey: id)?.resume(.failure(WatchError.timeout(label)))
        }
        return id
    }

    /// Reconnecte uniquement l'identifiant déjà choisi par l'utilisateur.
    /// Tout nouveau périphérique passe par la sélection explicite.
    private func connectKnownOrScan() {
        let trustedID = UserDefaults.standard.string(forKey: Self.trustedPeripheralIDKey)
            .flatMap(UUID.init(uuidString:))
        if let p = restoredPeripheral, p.identifier == trustedID {
            peripheral = p
            peripheralName = p.name
            p.delegate = self
            if p.state == .connected {
                centralManager(central, didConnect: p)
            } else {
                state = .connecting
                central.connect(p)
            }
            return
        }
        // iOS may restore a connection independently of the app's trust
        // record; never adopt it unless its identifier is the saved one.
        restoredPeripheral = nil
        // Une connexion en attente n'expire jamais : c'est le mécanisme de
        // reconnexion automatique en arrière-plan (iOS la relance quand la
        // montre redevient joignable).
        if let id = trustedID,
           let p = central.retrievePeripherals(withIdentifiers: [id]).first
        {
            attach(to: p)
            return
        }
        log.add(.info, "Looking for a ZeTime…")
        scanForPairing()
    }

    private func attach(to p: CBPeripheral) {
        peripheral = p
        peripheralName = p.name
        p.delegate = self
        if p.state == .connected {
            centralManager(central, didConnect: p)
        } else {
            state = .connecting
            central.connect(p)
        }
    }

    private func isTrusted(_ p: CBPeripheral) -> Bool {
        guard peripheral?.identifier == p.identifier,
              let stored = UserDefaults.standard.string(forKey: Self.trustedPeripheralIDKey)
        else { return false }
        return UUID(uuidString: stored) == p.identifier
    }

    private func addPairingCandidate(_ peripheral: CBPeripheral, name: String, rssi: Int?) {
        let id = peripheral.identifier
        if let index = pairingCandidates.firstIndex(where: { $0.id == id }) {
            candidatePeripherals[id] = peripheral
            pairingCandidates[index] = PairingCandidate(id: id, name: name, rssi: rssi)
        } else if pairingCandidates.count < Self.maxPairingCandidates {
            candidatePeripherals[id] = peripheral
            pairingCandidates.append(PairingCandidate(id: id, name: name, rssi: rssi))
            log.add(.info, "ZeTime peripheral detected; manual selection required")
        } else {
            pairingCandidatesOverflow = true
        }
    }

    /// Nouvelle connexion en attente : iOS réessaie indéfiniment, y compris
    /// en arrière-plan, jusqu'à ce que la montre soit à portée.
    private func reconnect(_ peripheral: CBPeripheral) {
        state = .connecting
        log.add(.info, "Reconnexion…")
        central.connect(peripheral)
    }

    private func markDisconnected() {
        rssiTimer?.invalidate()
        rssiTimer = nil
        rssi = nil
        txCharacteristic = nil
        ackCharacteristic = nil
        replyCharacteristic = nil
        reassemblers.removeAll()
        didInitialSync = false
        isReady = false
        for entry in collectors.values {
            entry.collector.cancel()
        }
        collectors.removeAll()
        let pending = waiters
        waiters.removeAll()
        for waiter in pending.values {
            waiter.resume(.failure(WatchError.notConnected))
        }
    }

    @discardableResult
    private func send(_ frame: Data, label: String) -> Bool {
        guard let peripheral, let tx = txCharacteristic, let ack = ackCharacteristic else {
            log.add(.error, "\(label): watch not connected, frame not sent")
            return false
        }
        for chunk in chunkFrame(frame: frame) {
            write(chunk, to: tx, on: peripheral)
        }
        write(Data([ackByte()]), to: ack, on: peripheral)
        log.add(.tx, label, hex: toHex(bytes: frame))
        return true
    }

    /// Trame réponse (musique, ack générique) : canal 0x8003, SANS l'octet
    /// ack 0x03 (contrairement à `send` — Gadgetbridge replyMsgToWatch).
    private func sendReply(_ frame: Data, label: String) {
        guard let peripheral, let reply = replyCharacteristic else {
            log.add(.error, "\(label): no reply channel, frame not sent")
            return
        }
        for chunk in chunkFrame(frame: frame) {
            write(chunk, to: reply, on: peripheral)
        }
        log.add(.tx, "\(label) ↩", hex: toHex(bytes: frame))
    }

    private static func isMusicControl(_ action: WatchAction) -> Bool {
        switch action {
        case .play, .pause, .next, .previous, .volume: return true
        default: return false
        }
    }

    /// Ack générique (0x01/0x81) attendu par la montre après un événement
    /// 0xD0 (commandes musique)/0xD1/0xD2/0xD9/0xDD — canal réponse 0x8003.
    private func sendGenericAck(_ cmd: UInt8) {
        do {
            try sendReply(encodeGenericAck(echoedCmd: cmd), label: "Ack 0x\(String(format: "%02X", cmd))")
        } catch {
            log.add(.error, "Ack : \(error.localizedDescription)")
        }
    }

    private func sendMusicState() {
        do {
            try sendReply(encodeMusicInfo(playing: musicPlaying, title: musicTitle), label: String(localized: "Music state"))
        } catch {
            log.add(.error, "Music state: \(error.localizedDescription)")
        }
    }

    private func write(_ data: Data, to characteristic: CBCharacteristic, on p: CBPeripheral) {
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(data, for: characteristic, type: type)
    }

    /// Lecture des infos fixes (numéro de série, versions) après connexion.
    @MainActor
    private func loadDeviceInfo() async {
        do {
            serial = try parseWatchId(payload: await request(.getWatchId, label: String(localized: "Serial number")))
            firmware = try parseVersion(payload: await request(.getFirmwareVersion, label: String(localized: "Firmware")))
            hardware = try parseVersion(payload: await request(.getHardwareVersion, label: String(localized: "Hardware")))
        } catch {
            log.add(.error, "Watch info: \(error.localizedDescription)")
        }
    }

    private func handle(frame: Data) {
        let raw = RawFrame(bytes: frame)
        log.add(.rx, commandName(cmd: raw.cmd), hex: toHex(bytes: frame))
        // Télémétrie brute : toutes les trames, y compris celles qu'une
        // attente ou une collecte va consommer juste après.
        telemetryFrameHandler?(frame)
        // Une attente en cours prend la trame en priorité.
        if let (id, waiter) = waiters.first(where: { $0.value.match(raw) }) {
            waiters.removeValue(forKey: id)
            waiter.resume(.success(raw))
            if raw.cmd == 0x08, let level = raw.payload.first {
                setBattery(level)
            }
            return
        }
        if let entry = collectors.values.first(where: { $0.match(raw) }) {
            entry.collector.push(raw)
            return
        }
        do {
            switch try decodeFrame(frame: frame) {
            case .action(let action):
                handle(action: action)
            case .battery(let level):
                setBattery(level)
            case .ack(let cmd, let status):
                if status == 0 {
                    log.add(.info, "\(commandName(cmd: cmd)) : OK")
                } else {
                    // Garder l'octet de commande brut : certains codes ne
                    // sont pas nommés.
                    log.add(.error, "Ack 0x\(String(format: "%02X", cmd)) \(commandName(cmd: cmd)): refused \(status)")
                }
            case .musicStateRequest(let code):
                if code == 0, let last = lastPlayerSourceDate,
                   Date().timeIntervalSince(last) < Self.sourceEchoWindow
                {
                    log.add(.event, "Music source: \(musicSource.name) kept (tracking request 0)")
                    // Volume en attente envoyé ici, avant l'état : une trame
                    // volume juste après la 1re réponse bloque l'écran.
                    if let level = pendingMusicVolume {
                        pendingMusicVolume = nil
                        updateMusicVolume(level)
                    }
                    sendMusicState()
                    return
                }
                let source = Self.musicSources[code] ?? Self.defaultMusicSource()
                lastPlayerSourceDate = code == 0 ? nil : Date()
                log.add(.event, "Music source: \(source.name) (byte \(code))")
                musicSource = source
                // Titre affiché sur l'écran Musique : le nom du lecteur choisi.
                musicTitle = source.name
                sendMusicState()
                lastAction = source.name
                lastActionDate = Date()
                musicSourceHandler?(source)
            case .unknownMusic(let code):
                log.add(.event, "Unknown music command \(code)")
            case .realTimeHeartRate(let bpm):
                realTimeHeartRateHandler?(bpm)
            case .other:
                break // déjà journalisée en réception
            }
        } catch {
            log.add(.error, "Trame illisible : \(error.localizedDescription)")
        }
    }

    private func setBattery(_ level: UInt8) {
        batteryLevel = Int(level)
        batteryDate = Date()
    }

    private func handle(action: WatchAction) {
        var text = watchActionId(action: action)
        var id = text
        // La montre attend un code retour à ses commandes musique (0xD0
        // SEND) avant de rafraîchir l'écran : sans lui, 2-3 s de latence par
        // appui ou cran de molette (confirmé live le 2026-10-29).
        if Self.isMusicControl(action) {
            sendGenericAck(0xD0)
        }
        switch action {
        case .volume(let level):
            // La montre envoie un niveau absolu : la direction est déduite
            // du niveau précédent (molette ± → volume_up / volume_down).
            id = level > musicVolume ? "volume_up"
                : level < musicVolume ? "volume_down" : "volume"
            text += " \(level)"
            updateMusicVolume(level)
        case .play:
            musicPlaying = true
            sendMusicState()
        case .pause:
            musicPlaying = false
            sendMusicState()
        // La montre bloque sur l'ack générique après ces événements
        // (échec « connection failed » sinon) — envoyé avant tout.
        case .camera:
            sendGenericAck(0xD1)
        case .findPhone:
            sendGenericAck(0xD2)
        case .sos:
            sendGenericAck(0xD9)
        case .remoteButton:
            // 0xE8 (firmware patché) : « no reply needed » d'après
            // artificialred.nl — pas d'ack générique.
            break
        case .quickReply(let opcode, let text, let presetCrc, let face, let sender, let notificationCrc, _, let raw):
            // La montre bloque jusqu'à l'ack écho de SON opcode
            // (0xDD SMS / 0xDE contenu / 0xE6 social).
            sendGenericAck(opcode)
            Task { @MainActor in
                await handleQuickReply(
                    opcode: opcode, text: text, presetCrc: presetCrc, face: face,
                    sender: sender, notificationCrc: notificationCrc, raw: raw
                )
            }
            return
        default:
            break
        }
        lastAction = text
        lastActionDate = Date()
        log.add(.event, "Action : \(text)")
        actionHandler?(id, action)
    }

    /// Cache CRC → texte des réponses rapides, pour résoudre le preset
    /// choisi sur la montre (0xDA/0xDB) sans requête à chaque événement.
    private var quickReplyCache: [UInt16: String] = [:]
    private var quickReplyCacheDate: Date?

    @MainActor
    private func quickReplyText(crc: UInt16) async -> String? {
        if let hit = quickReplyCache[crc] { return hit }
        if quickReplyCacheDate.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
            if let replies = try? await readQuickReplies() {
                quickReplyCache = Dictionary(uniqueKeysWithValues: replies.map { ($0.crc, $0.text) })
                quickReplyCacheDate = Date()
            }
        }
        return quickReplyCache[crc]
    }

    /// Réponse rapide structurée : journal détaillé + texte résolu
    /// (contenu 0xDE > preset par CRC > emoji) passé au routage. iOS ne
    /// peut pas injecter la réponse dans la notification d'origine
    /// (limite ANCS) — elle est forwardée au webhook/daemon/Shortcuts.
    @MainActor
    private func handleQuickReply(
        opcode: UInt8, text: String, presetCrc: UInt16?, face: String,
        sender: String?, notificationCrc: UInt16?, raw: Data
    ) async {
        var resolved = text.isEmpty ? face : text
        var note = ""
        if let crc = presetCrc {
            if let preset = await quickReplyText(crc: crc) {
                resolved = preset
            } else {
                note = " · preset \(String(format: "%04X", crc)) unresolved"
            }
        }
        let kind = opcode == 0xDE ? "contenu" : opcode == 0xE6 ? "social network" : "SMS"
        if let sender, !sender.isEmpty { note += " · de \(sender)" }
        if let notificationCrc { note += " · notif \(String(format: "%04X", notificationCrc))" }
        lastAction = "Reply \(kind): \(resolved)\(note)"
        lastActionDate = Date()
        log.add(.event, "Reply \(kind): “\(resolved)”\(note)")
        log.add(.rx, "Raw reply", hex: toHex(bytes: raw))
        actionHandler?(
            "quick_reply",
            .quickReply(
                opcode: opcode, text: resolved, presetCrc: presetCrc, face: face,
                sender: sender, notificationCrc: notificationCrc,
                isContent: opcode == 0xDE, raw: raw
            )
        )
    }
}

/// Tampon des trames d'une collecte multi-trames : les trames arrivées
/// entre deux `next` sont gardées, `next` rend nil après `timeout` sans
/// trame. Main thread uniquement.
final class FrameCollector {
    private var buffer: [RawFrame] = []
    private var waiter: CheckedContinuation<RawFrame?, Never>?
    private var timer: DispatchWorkItem?
    private var cancelled = false

    func push(_ frame: RawFrame) {
        if let waiter {
            self.waiter = nil
            timer?.cancel()
            waiter.resume(returning: frame)
        } else {
            buffer.append(frame)
        }
    }

    @MainActor
    func next(timeout: TimeInterval) async -> RawFrame? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if cancelled { return nil }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            let work = DispatchWorkItem { [weak self] in
                guard let self, let waiter = self.waiter else { return }
                self.waiter = nil
                waiter.resume(returning: nil)
            }
            timer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    /// Fin de collecte (déconnexion) : l'attente en cours rend nil.
    func cancel() {
        cancelled = true
        timer?.cancel()
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }
}

private extension RawFrame {
    /// Réponse de données, ou code retour « GET refusé » (`6F 01 80 02 00 <cmd> <rc>`).
    func unwrapReply(code: UInt8, label: String) throws -> Data {
        if cmd == code { return payload }
        let status = payload.count > 1 ? payload[payload.startIndex + 1] : 0xFF
        throw WatchError.refused(label, status)
    }
}

// MARK: - CBCentralManagerDelegate

extension ZeTimeBluetoothManager: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let first = peripherals.first
        else { return }
        first.delegate = self
        restoredPeripheral = first
        // On n'agit qu'une fois le Bluetooth poweredOn
        // (centralManagerDidUpdateState → connectKnownOrScan).
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectKnownOrScan()
        case .poweredOff:
            state = .bluetoothOff
            markDisconnected()
            telemetryPresenceHandler?(.disconnected)
        case .unauthorized:
            state = .unauthorized
        case .unsupported:
            state = .unsupported
        case .resetting, .unknown:
            state = .disconnected
            markDisconnected()
            telemetryPresenceHandler?(.disconnected)
        @unknown default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard name.localizedCaseInsensitiveContains("zetime") else { return }
        let id = peripheral.identifier
        let trustedID = UserDefaults.standard.string(forKey: Self.trustedPeripheralIDKey)
            .flatMap(UUID.init(uuidString:))
        if id == trustedID {
            central.stopScan()
            telemetryPresenceHandler?(.seen(rssi: RSSI.intValue))
            rssi = RSSI.intValue
            attach(to: peripheral)
            return
        }
        addPairingCandidate(peripheral, name: name, rssi: RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isTrusted(peripheral) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        state = .connected
        peripheralName = peripheral.name
        markDisconnected()
        log.add(.info, "Connected to \(peripheral.name ?? "ZeTime")")
        telemetryPresenceHandler?(.connected)
        peripheral.readRSSI()
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard isTrusted(peripheral) else { return }
        log.add(.error, "Connection failed: \(error?.localizedDescription ?? "?")")
        reconnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Montre oubliée (forgetWatch) : plus le périphérique courant.
        guard isTrusted(peripheral) else { return }
        markDisconnected()
        telemetryPresenceHandler?(.disconnected)
        if let error {
            log.add(.error, "Disconnect: \(error.localizedDescription)")
        } else {
            log.add(.info, "Disconnected")
        }
        reconnect(peripheral)
    }
}

// MARK: - CBPeripheralDelegate

extension ZeTimeBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isTrusted(peripheral) else { return }
        if let error {
            log.add(.error, "Services : \(error.localizedDescription)")
            return
        }
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard isTrusted(peripheral) else { return }
        if let error {
            log.add(.error, "Characteristics: \(error.localizedDescription)")
            return
        }
        let uuids = gattUuids()
        for c in service.characteristics ?? [] {
            if c.uuid == CBUUID(string: uuids.tx) {
                txCharacteristic = c
            }
            if c.uuid == CBUUID(string: uuids.ack) {
                ackCharacteristic = c
            }
            if c.uuid == CBUUID(string: uuids.reply) {
                replyCharacteristic = c
            }
            // Comme le CLI Rust : souscription à tout ce qui notifie.
            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
        }
        // Première synchro (heure, batterie, état musique, infos) dès que
        // TX/ACK/réponse sont connus et les notifications 0x8002 actives.
        startIfReady(peripheral)
    }

    /// Échantillonne le RSSI toutes les 60 s tant que la montre est prête —
    /// alimente la télémétrie `ble_status` (présence du lien).
    private func startRSSIPolling() {
        rssiTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.peripheral?.readRSSI()
        }
        RunLoop.main.add(timer, forMode: .common)
        rssiTimer = timer
    }

    /// Les réponses arrivent en notification sur 0x8002 : la connexion n'est
    /// prête qu'une fois cet abonnement confirmé (sinon les premières
    /// requêtes perdraient leur réponse).
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard isTrusted(peripheral) else { return }
        if let error {
            log.add(.error, "Abonnement \(characteristic.uuid.uuidString) : \(error.localizedDescription)")
        }
        startIfReady(peripheral)
    }

    private func startIfReady(_ peripheral: CBPeripheral) {
        if !didInitialSync, txCharacteristic != nil, replyCharacteristic != nil,
           let ack = ackCharacteristic, ack.isNotifying
        {
            didInitialSync = true
            isReady = true
            startRSSIPolling()
            syncTime()
            requestBattery()
            updateMusicVolume(musicVolume)
            sendMusicState()
            Task { @MainActor in
                await self.loadDeviceInfo()
                // Table 0x2E pour la télémétrie `button` (button_id) —
                // relue à chaque connexion, supporte les remaps externes.
                self.buttonFunctions = (try? await self.readButtons()) ?? self.buttonFunctions
                self.onReady?()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard isTrusted(peripheral) else { return }
        rssi = RSSI.intValue
        telemetryPresenceHandler?(.rssi(RSSI.intValue))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isTrusted(peripheral) else { return }
        if let error {
            log.add(.error, "Lecture \(characteristic.uuid.uuidString) : \(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value, !value.isEmpty else { return }
        let reassembler = reassemblers[characteristic.uuid] ?? {
            let r = FrameReassembler()
            reassemblers[characteristic.uuid] = r
            return r
        }()
        for frame in reassembler.push(chunk: value) {
            handle(frame: frame)
        }
    }
}
