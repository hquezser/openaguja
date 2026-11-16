import Foundation

#if canImport(OpenAgujaCore)
    import OpenAgujaCore // bindings UniFFI (déjà dans le module en typecheck)
#endif

/// Signal de lien BLE produit par `ZeTimeBluetoothManager` pour la
/// télémétrie `ble_status` — jamais émis par la montre elle-même.
enum WatchPresenceSignal: Equatable {
    /// `didConnect` : lien GATT établi.
    case connected
    /// `didDisconnectPeripheral` ou Bluetooth coupé.
    case disconnected
    /// Montre vue en advertisement pendant le scan (présence + RSSI).
    case seen(rssi: Int)
    /// Échantillon RSSI lu sur le lien établi.
    case rssi(Int)
}

/// Capture télémétrie brute : chaque trame BLE complète est décodée par le
/// cœur Rust (`decodeTelemetryEvents`) puis le document JSON est empilé
/// dans `TelemetryUploader`. Les événements de lien (connexion,
/// déconnexion, RSSI) sont générés ici en `ble_status` — CoreBluetooth,
/// pas le protocole watch.
///
/// Aucun traitement au-delà du formatage : les payloads restent ceux des
/// trames (voir `openaguja::telemetry` pour la couverture protocole).
@MainActor
final class TelemetryService {
    let uploader: TelemetryUploader

    private let log: LogStore
    private weak var watch: ZeTimeBluetoothManager?

    init(uploader: TelemetryUploader, log: LogStore) {
        self.uploader = uploader
        self.log = log
    }

    /// Branchement sur le manager BLE — pose les deux handlers une fois.
    func attach(watch: ZeTimeBluetoothManager) {
        self.watch = watch
        watch.telemetryFrameHandler = { [weak self] frame in
            self?.handleFrame(frame)
        }
        watch.telemetryPresenceHandler = { [weak self] signal in
            self?.handlePresence(signal)
        }
    }

    /// Vidange immédiate (reconnexion BLE, retour au premier plan).
    func flush() {
        uploader.flush()
    }

    var queuedCount: Int { uploader.queuedCount }

    // MARK: - Trames watch → événements

    private func handleFrame(_ frame: Data) {
        let now = Date()
        let events = decodeTelemetryEvents(
            frame: frame,
            nowUnix: Int64(now.timeIntervalSince1970),
            utcOffsetSeconds: Int32(TimeZone.current.secondsFromGMT(for: now)),
            buttonFunctions: watch?.buttonFunctions ?? []
        )
        for event in events {
            do {
                uploader.enqueue(try telemetryEventJson(event: event))
            } catch {
                log.add(.error, "Telemetry: JSON impossible: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Lien BLE → ble_status

    private func handlePresence(_ signal: WatchPresenceSignal) {
        var fields: [String: Any] = [:]
        switch signal {
        case .connected:
            fields["state"] = "connected"
        case .disconnected:
            fields["state"] = "disconnected"
        case .seen(let rssi):
            fields["state"] = "seen"
            fields["rssi"] = rssi
        case .rssi(let rssi):
            fields["state"] = "connected"
            fields["rssi"] = rssi
        }
        bleStatus(fields)
    }

    /// `ble_status` est généré côté téléphone : le payload JSON est construit
    /// ici puis encapsulé par `telemetryEventJson` (même schéma que le cœur).
    private func bleStatus(_ fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields),
              let payloadJSON = String(data: data, encoding: .utf8)
        else { return }
        let event = TelemetryEvent(
            timestamp: UInt64(Date().timeIntervalSince1970),
            eventType: .bleStatus,
            payloadJson: payloadJSON
        )
        do {
            uploader.enqueue(try telemetryEventJson(event: event))
        } catch {
            log.add(.error, "Telemetry ble_status: \(error.localizedDescription)")
        }
    }
}
