import SwiftUI
import UIKit

/// Design system OpenAguja — tokens repris du prototype Lovable
/// (oklch → sRGB). Accent = orange de marque `#FB981E` dans les deux modes.
enum ZTColor {
    /// Couleur adaptative light/dark à partir d'une paire de teintes.
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark)
                : UIColor(hex: light)
        })
    }

    // MARK: Surfaces & texte
    /// Fond principal des écrans.
    static let background = adaptive(0xF4F4F6, 0x070709)
    /// Texte principal.
    static let foreground = adaptive(0x0B0B0D, 0xF5F5F6)
    /// Cartes groupées.
    static let card = adaptive(0xFFFFFF, 0x161619)
    /// Texte sur carte.
    static let cardForeground = adaptive(0x0B0B0D, 0xF5F5F6)
    /// Cartes secondaires (sous-blocs dans une carte).
    static let cardSecondary = adaptive(0xEBEBED, 0x212125)
    /// Contour subtil des cartes.
    static let stroke = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.08)
            : UIColor(hex: 0xDEDEE0)
    })

    // MARK: Marque / accent
    /// Orange de marque — primaire dans les deux modes.
    static let primary = Color(hex: 0xFB981E)
    /// Texte posé sur l'orange (toujours sombre pour le contraste).
    static let primaryForeground = Color(hex: 0x1B0E04)
    /// Accent (teinte orange claire en light, sombre en dark).
    static let accent = adaptive(0xFFEBD2, 0x422707)
    /// Texte sur accent.
    static let accentForeground = adaptive(0x863F00, 0xFFBE69)
    /// Anneau de focus / sélection.
    static let ring = adaptive(0xE38305, 0xF9A63E)

    // MARK: Sémantique
    /// Sémantique stricte : vert = connecté / OK, orange = attente /
    /// hors-ligne / batterie faible, rouge = déconnecté / erreur.
    static let success = adaptive(0x2EB45C, 0x44D070)
    static let warning = adaptive(0xF68C11, 0xFFA03A)
    static let danger = adaptive(0xEE343B, 0xFC4F4E)
    /// Alias historique du destructif.
    static let destructive = danger
    static let info = adaptive(0x1289E7, 0x4BA3F7)

    // MARK: Sommeil
    static let sleepLight = adaptive(0x7E6EF2, 0x7E6EF2)
    static let sleepDeep = adaptive(0x5234BC, 0x5234BC)
    static let sleepREM = adaptive(0xC49BF3, 0xC49BF3)

    // MARK: Divers
    /// Texte atténué (secondary).
    static let muted = adaptive(0x6E6E73, 0x919198)
    /// Secondaire (remplissage discret).
    static let secondary = adaptive(0xE7E7EA, 0x26262A)
    /// Cadre de l'illustration de montre.
    static let frame = adaptive(0x161618, 0x161618)
    /// Fond de scène (illustrations).
    static let stage = adaptive(0xDDDDE2, 0x1C1C20)

    /// Alias historique de l'accent (beaucoup d'écrans l'utilisent).
    static var accentLegacy: Color { primary }
}

extension Color {
    init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(uiColor: UIColor(hex: hex, alpha: alpha))
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Cartes

/// Carte Bento : fond `ZTColor.card`, coins continus, contour discret.
struct ZTCard<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZTColor.card,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(ZTColor.stroke, lineWidth: 0.5)
            }
    }
}

/// En-tête de carte / section : petit label secondary + contenu optionnel.
struct ZTCardHeader: View {
    let title: String
    var symbol: String? = nil
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ZTColor.accent)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Pastille colorée d'état (connexion, file, HTTP…).
struct ZTStatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// Métrique chiffrée : libellé secondary + valeur en chiffres tabulaires.
struct ZTMetric: View {
    let label: String
    let value: String
    var symbol: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Tuile d'action rapide (grille Bento).
struct ZTActionTile: View {
    let title: String
    let symbol: String
    var tint: Color = ZTColor.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(
                ZTColor.cardSecondary,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Ligne de navigation dans une carte (icône + titre + sous-titre + chevron).
struct ZTNavRow<Destination: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var tint: Color = ZTColor.accent
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.body.weight(.medium))
                        .foregroundStyle(tint)
                        .frame(width: 30, height: 30)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Ligne libellé ↔ contrôle (toggle, picker…) dans une carte.
struct ZTControlRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var tint: Color = ZTColor.accent
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            control()
        }
        .padding(.vertical, 6)
    }
}

/// Ligne simple libellé + valeur (état, compteur…).
struct ZTInfoRow: View {
    let title: String
    let value: String
    var symbol: String? = nil
    var valueTint: Color = .secondary
    var monospaced: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(ZTColor.accent)
                    .frame(width: 30, height: 30)
                    .background(ZTColor.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(title)
                .font(.body)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(valueTint)
                .modifier(MonoDigits(enabled: monospaced))
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 4)
    }
}

private struct MonoDigits: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.monospacedDigit()
        } else {
            content
        }
    }
}

/// Badge pastille (compteur d'alertes sur le sélecteur de segment).
struct ZTBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(ZTColor.danger, in: Capsule())
                .accessibilityLabel("\(count) alert(s)")
        }
    }
}
