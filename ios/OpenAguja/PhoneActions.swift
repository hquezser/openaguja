import AVFoundation
import Foundation
import Photos
import UIKit
import UserNotifications

/// Actions iPhone déclenchées par la montre (cibles de l'onglet Boutons) :
/// l'écran « Appareil photo » prend une photo — la session est armée à la
/// demande partout dans l'app au premier plan, ou depuis l'écran Caméra
/// pour cadrer (iOS interdit la capture en arrière-plan : hors premier
/// plan, une notification invite à ouvrir l'app) ; « Trouver le
/// téléphone » lance une alarme qui ignore le bouton silencieux
/// (catégorie .playback + mode background audio).
final class PhoneActions: NSObject, ObservableObject {
    @Published private(set) var alarmRinging = false
    @Published private(set) var cameraArmed = false
    /// Dernière photo prise via la montre, pour l'affichage.
    @Published private(set) var lastShot: UIImage?

    /// Sonnerie de retrouvaille : arrêt auto si l'utilisateur n'intervient pas.
    private static let alarmAutoStop: TimeInterval = 60

    private var alarmPlayer: AVAudioPlayer?
    private var alarmStopTask: Task<Void, Never>?
    private var torchTimer: Timer?

    private var session: AVCaptureSession?
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "zetime.camera")
    /// Déclencheur montre reçu pendant que la session s'arme.
    private var pendingShot = false
    /// Session armée par un événement (pas l'écran) : relâchée après inactivité.
    private var idleDisarmTask: Task<Void, Never>?

    // MARK: - Routage

    /// Ouvre l'app iOS du lecteur choisi sur l'écran Musique de la montre.
    /// Source « apple » = lecteur système par défaut : rien à ouvrir
    /// (music:// tombe sur l'App Store si l'app Musique n'est pas installée).
    func openPlayer(_ source: String) {
        switch source {
        case "spotify": openApp("spotify://")
        case "deezer": openApp("deezer://")
        default: break
        }
    }

    /// Ouvre l'app iOS du lecteur choisi sur la montre — seulement au
    /// premier plan (UIApplication.open échoue sinon).
    private func openApp(_ url: String) {
        guard UIApplication.shared.applicationState == .active,
              let url = URL(string: url), UIApplication.shared.canOpenURL(url)
        else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Alarme « Trouver le téléphone »

    func startAlarm() {
        guard !alarmRinging else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            // .playback joue malgré le bouton silencieux — c'est tout
            // l'intérêt de la sonnerie de retrouvaille.
            try audio.setCategory(.playback, mode: .default)
            try audio.setActive(true)
            alarmPlayer = try AVAudioPlayer(data: Self.alarmWav())
            alarmPlayer?.numberOfLoops = -1
            alarmPlayer?.volume = 1.0
            alarmPlayer?.play()
            alarmRinging = true
            startTorchFlash()
            alarmStopTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.alarmAutoStop) * 1_000_000_000)
                if !Task.isCancelled { self?.stopAlarm() }
            }
        } catch {
            // Sans session audio pas de son — échec silencieux, le POST
            // webhook part quand même.
        }
    }

    func stopAlarm() {
        alarmStopTask?.cancel()
        alarmStopTask = nil
        torchTimer?.invalidate()
        torchTimer = nil
        setTorch(on: false)
        alarmPlayer?.stop()
        alarmPlayer = nil
        alarmRinging = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Sirène binaire PCM16 mono synthétisée — pas de fichier à embarquer.
    private static func alarmWav() -> Data {
        let rate = 22_050
        let frames = rate * 2 // 2 s : alternance de tons de 0,5 s
        var samples = [UInt8]()
        samples.reserveCapacity(frames * 2)
        for i in 0..<frames {
            let t = Double(i) / Double(rate)
            let freq: Double = (i / (rate / 2)) % 2 == 0 ? 880 : 660
            let s = Int16(sin(2 * .pi * freq * t) * 0.55 * 32767)
            samples.append(UInt8(truncatingIfNeeded: s))
            samples.append(UInt8(truncatingIfNeeded: s >> 8))
        }
        var wav = Data()
        let dataLen = UInt32(samples.count)
        wav.append("RIFF".data(using: .ascii)!)
        wav.appendLE(36 + dataLen)
        wav.append("WAVEfmt ".data(using: .ascii)!)
        wav.appendLE(UInt32(16)) // bloc fmt
        wav.appendLE(UInt16(1)) // PCM
        wav.appendLE(UInt16(1)) // mono
        wav.appendLE(UInt32(rate))
        wav.appendLE(UInt32(rate * 2)) // octets/s
        wav.appendLE(UInt16(2)) // alignement bloc
        wav.appendLE(UInt16(16)) // bits
        wav.append("data".data(using: .ascii)!)
        wav.appendLE(dataLen)
        wav.append(contentsOf: samples)
        return wav
    }

    private func startTorchFlash() {
        torchTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] t in
            guard let self, let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
                t.invalidate()
                return
            }
            self.setTorch(on: device.torchMode != .on, device: device)
        }
    }

    private func setTorch(on: Bool, device: AVCaptureDevice? = nil) {
        let device = device ?? AVCaptureDevice.default(for: .video)
        guard let device, device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    // MARK: - Caméra (télécommande de la montre)

    /// Arme la session : l'écran Caméra passe sa couche d'aperçu ; un
    /// événement montre peut armer sans aperçu (photo « aveugle » au premier
    /// plan — iOS interdit la capture en arrière-plan de toute façon).
    func armCamera(previewLayer: AVCaptureVideoPreviewLayer? = nil) {
        if let session {
            previewLayer?.session = session
            previewLayer?.videoGravity = .resizeAspectFill
            cameraArmed = true
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self, granted else { return }
            self.sessionQueue.async {
                let session = AVCaptureSession()
                session.sessionPreset = .photo
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input), session.canAddOutput(self.photoOutput)
                else { return }
                session.addInput(input)
                session.addOutput(self.photoOutput)
                session.startRunning()
                DispatchQueue.main.async {
                    self.session = session
                    previewLayer?.session = session
                    previewLayer?.videoGravity = .resizeAspectFill
                    self.cameraArmed = true
                    self.scheduleIdleDisarm()
                    if self.pendingShot {
                        self.pendingShot = false
                        self.shoot()
                    }
                }
            }
        }
    }

    func disarmCamera() {
        idleDisarmTask?.cancel()
        idleDisarmTask = nil
        sessionQueue.async { [weak self] in
            self?.session?.stopRunning()
        }
        session = nil
        cameraArmed = false
    }

    /// Session armée par événement : reposée si plus rien ne se passe après
    /// un délai — la caméra consomme de la batterie en continu.
    private func scheduleIdleDisarm() {
        idleDisarmTask?.cancel()
        idleDisarmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled { self?.disarmCamera() }
        }
    }

    /// Appui sur le déclencheur de la montre (ou le bouton de l'écran).
    /// Non armée → on arme d'abord et le tir part dès que la session tourne.
    func shoot() {
        guard let session, session.isRunning else {
            pendingShot = true
            armCamera()
            notifyIfBackgrounded(
                title: String(localized: "Photo requested"),
                body: "The watch wants to trigger the camera — open OpenAguja to take the shot."
            )
            return
        }
        scheduleIdleDisarm()
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    /// Notification de rappel quand un événement arrive alors que l'app n'est
    /// pas visible — iOS interdit toute capture en arrière-plan, on ne peut
    /// que prévenir.
    private func notifyIfBackgrounded(title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}

extension PhoneActions: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard let data = photo.fileDataRepresentation() else { return }
        PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
        if let image = UIImage(data: data) {
            DispatchQueue.main.async { self.lastShot = image }
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
