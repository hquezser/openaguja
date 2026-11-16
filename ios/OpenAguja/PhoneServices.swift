import AVFoundation
import CallKit
import MediaPlayer
import UIKit
import UserNotifications

/// Pilotage du lecteur Apple Music du téléphone. iOS n'offre aucune API
/// pour piloter une autre app (Deezer, Spotify…) : pour celles-là, passer
/// par le webhook HTTP ou un raccourci.
final class MusicController: ObservableObject {
    @Published private(set) var nowPlaying: String?
    @Published private(set) var isPlaying = false

    /// Appelé à chaque changement (titre, lecture/pause) pour la montre.
    var onChange: ((Bool, String) -> Void)?

    private let player = MPMusicPlayerController.systemMusicPlayer

    init() {
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(stateChanged), name: .MPMusicPlayerControllerPlaybackStateDidChange, object: player)
        center.addObserver(self, selector: #selector(stateChanged), name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player)
        refresh()
    }

    func handle(_ actionId: String) {
        switch actionId {
        case "play": player.play()
        case "pause": player.pause()
        case "next": player.skipToNextItem()
        case "previous": player.skipToPreviousItem()
        default: break
        }
    }

    @objc private func stateChanged() {
        refresh()
        onChange?(isPlaying, nowPlaying ?? "")
    }

    private func refresh() {
        isPlaying = player.playbackState == .playing
        let item = player.nowPlayingItem
        nowPlaying = [item?.title, item?.artist].compactMap { $0 }.joined(separator: " — ").nilIfEmpty
    }
}

/// Appels téléphoniques → écran d'appel de la montre. CallKit ne donne ni
/// le nom ni le numéro de l'appelant aux apps tierces : la montre affiche
/// un libellé générique. Actif tant que l'app tourne (y compris réveillée
/// en arrière-plan par la montre).
final class CallMonitor: NSObject, ObservableObject, CXCallObserverDelegate {
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "calls.enabled") }
    }

    var onIncoming: (() -> Void)?
    var onEnded: (() -> Void)?

    private let observer = CXCallObserver()
    private var ringing: Set<UUID> = []

    override init() {
        enabled = UserDefaults.standard.bool(forKey: "calls.enabled")
        super.init()
        observer.setDelegate(self, queue: .main)
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        guard enabled else { return }
        if !call.isOutgoing, !call.hasConnected, !call.hasEnded {
            if ringing.insert(call.uuid).inserted {
                onIncoming?()
            }
        } else if ringing.remove(call.uuid) != nil {
            onEnded?()
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Volume système de l'iPhone (celui de Deezer) : la seule voie publique
/// est le curseur d'un MPVolumeView invisible posé dans la fenêtre.
/// Vérifié le 2026-10-29, y compris iPhone verrouillé.
final class SystemVolume {
    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))

    /// Niveau actuel, 0…1.
    var level: Float { AVAudioSession.sharedInstance().outputVolume }

    /// Pose la vue dans la fenêtre : le curseur n'agit qu'une fois affiché.
    func prepare() {
        guard volumeView.window == nil,
              let window = UIApplication.shared.connectedScenes
              .compactMap({ ($0 as? UIWindowScene)?.windows.first })
              .first
        else { return }
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        window.addSubview(volumeView)
    }

    /// Règle le volume (0…1) ; faux si le curseur est introuvable.
    @discardableResult
    func set(_ value: Float) -> Bool {
        prepare()
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return false }
        let clamped = min(max(value, 0), 1)
        // Le curseur d'une vue tout juste posée ignore la première valeur.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            slider.value = clamped
        }
        return true
    }
}
