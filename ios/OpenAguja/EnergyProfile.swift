import Foundation

/// Profil énergétique des capteurs : fréquence de mesure cardio de la
/// montre (0x5C, `SetHeartRateInterval`) et cadence de synchro
/// d'activité automatique. Source unique de vérité — les écrans ne
/// proposent pas d'intervalle cardio contradictoire.
///
/// Le choix est persisté dans UserDefaults ; la valeur est appliquée à la
/// montre via `WatchSettingsModel.apply(.setHeartRateInterval)` qui mémorise
/// aussi `heartRateIntervalIntent` (utilisé par `HeartRateService` pour
/// restaurer l'intervalle d'origine après une session).
enum EnergyProfile: String, CaseIterable, Identifiable {
    /// Cardio toutes les 60 min, synchro auto si > 6 h.
    case economy
    /// Cardio toutes les 15 min, synchro auto si > 3 h (défaut).
    case balanced
    /// Cardio toutes les 5 min, synchro auto si > 1 h.
    case precise

    static let storageKey = "sensors.profile"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .economy: return String(localized: "Economy")
        case .balanced: return String(localized: "Balanced")
        case .precise: return String(localized: "Precise")
        }
    }

    var symbol: String {
        switch self {
        case .economy: return "battery.25"
        case .balanced: return "battery.50"
        case .precise: return "battery.100"
        }
    }

    /// Intervalle cardio envoyé à la montre (0x5C — valeurs acceptées :
    /// 0 désactive, puis 5/10/15/30/60).
    var heartRateMinutes: UInt8 {
        switch self {
        case .economy: return 60
        case .balanced: return 15
        case .precise: return 5
        }
    }

    /// Âge max de la dernière synchro d'activité pour qu'elle reparte
    /// automatiquement à la connexion (utilisé par `AppDelegate`).
    var autoSyncAge: TimeInterval {
        switch self {
        case .economy: return 6 * 3600
        case .balanced: return 3 * 3600
        case .precise: return 3600
        }
    }

    /// Description affichée sous le sélecteur.
    var detail: String {
        let sync = autoSyncAge >= 3600 ? "\(Int(autoSyncAge / 3600)) h" : "\(Int(autoSyncAge / 60)) min"
        return String(localized: "HR every \(heartRateMinutes) min · auto-sync on connect if older than \(sync)")
    }

    /// Profil persisté (défaut : équilibré).
    static var current: EnergyProfile {
        EnergyProfile(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .balanced
    }

    static func set(_ profile: EnergyProfile) {
        UserDefaults.standard.set(profile.rawValue, forKey: storageKey)
    }

    /// Profil correspondant à un intervalle cardio (repli sur le profil
    /// persisté pour les valeurs héritées hors des trois paliers).
    static func matching(minutes: Int) -> EnergyProfile? {
        allCases.first { $0.heartRateMinutes == minutes }
    }
}
