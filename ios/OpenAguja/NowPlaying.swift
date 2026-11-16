import Foundation

/// Commandes de lecture envoyées à l'app « À l'écoute » du téléphone
/// (Deezer quand elle joue) via le framework privé MediaRemote. Aucune API
/// publique iOS ne pilote une app tierce : expérimental, possible seulement
/// hors App Store (app installée depuis Xcode), et une mise à jour d'iOS
/// peut le casser sans erreur — `send` rend faux si le symbole manque.
enum NowPlaying {
    enum Command: UInt32 {
        case play = 0
        case pause = 1
        case togglePlayPause = 2
        case next = 4
        case previous = 5
    }

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    private static let sendCommand: SendCommand? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
        else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    static var isAvailable: Bool { sendCommand != nil }

    /// Commande correspondant à une action musique de la montre.
    static func command(for actionId: String) -> Command? {
        switch actionId {
        case "play": return .play
        case "pause": return .pause
        case "next": return .next
        case "previous": return .previous
        default: return nil
        }
    }

    @discardableResult
    static func send(_ command: Command) -> Bool {
        sendCommand?(command.rawValue, nil) ?? false
    }
}
