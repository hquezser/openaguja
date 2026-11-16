import SwiftUI

/// Composants partagés calqués sur le `ui.tsx` du prototype :
/// Section (titre + footer), List/Row (tuile icône colorée, label,
/// sous-titre, valeur, chevron), Pill, Segmented, StatusDot, Toast.
/// Les paramètres texte sont des `LocalizedStringKey` : les littéraux
/// et interpolations se localisent via le catalogue, les données
/// utilisateur (noms de modes, lieux…) traversent sans traduction.

// MARK: - Section

/// Section titrée avec footer optionnel (espace avant/après).
struct ZTSection<Content: View>: View {
    var title: LocalizedStringKey? = nil
    var footer: LocalizedStringKey? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(ZTColor.muted)
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .padding(.horizontal, 4)
            }
            content
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(ZTColor.muted)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 20)
    }
}

// MARK: - List & Row

/// Conteneur liste : carte arrondie dont les rangées sont séparées
/// par un trait fin (équivalent du `List` du prototype).
struct ZTList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(ZTColor.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(ZTColor.stroke, lineWidth: 0.5)
        }
    }
}

/// Séparateur fin entre rangées d'une `ZTList`.
struct ZTRowDivider: View {
    var body: some View {
        Divider().overlay(ZTColor.stroke).padding(.leading, 60)
    }
}

/// Tuile icône colorée (carré arrondi ~8 pt, glyphes ~17 pt).
struct ZTIconTile: View {
    let symbol: String
    var tint: Color = ZTColor.primary
    /// Teinte de fond de la tuile ; par défaut l'accent primaire.
    var bg: Color? = nil
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.6, weight: .medium))
            .foregroundStyle(ZTColor.primaryForeground)
            .frame(width: size, height: size)
            .background(bg ?? tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Rangée de liste : icône + label (+ sub) + valeur + chevron / trailing.
struct ZTRow<Trailing: View>: View {
    var icon: String? = nil
    var iconTint: Color = ZTColor.primary
    var iconBg: Color? = nil
    var label: LocalizedStringKey
    var sub: LocalizedStringKey? = nil
    var value: LocalizedStringKey? = nil
    var chevron: Bool = false
    var tone: RowTone = .standard
    var disabled: Bool = false
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    enum RowTone { case standard, accent, danger }

    init(icon: String? = nil, iconTint: Color = ZTColor.primary, iconBg: Color? = nil,
         label: LocalizedStringKey, sub: LocalizedStringKey? = nil, value: LocalizedStringKey? = nil,
         chevron: Bool = false, tone: RowTone = .standard, disabled: Bool = false,
         action: (() -> Void)? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.icon = icon; self.iconTint = iconTint; self.iconBg = iconBg
        self.label = label; self.sub = sub; self.value = value
        self.chevron = chevron; self.tone = tone; self.disabled = disabled
        self.action = action; self.trailing = trailing
    }

    private var labelColor: Color {
        switch tone {
        case .standard: return ZTColor.foreground
        case .accent: return ZTColor.primary
        case .danger: return ZTColor.danger
        }
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .opacity(disabled ? 0.45 : 1)
    }

    private var content: some View {
        HStack(spacing: 12) {
            if let icon {
                ZTIconTile(symbol: icon, tint: iconTint, bg: iconBg)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(labelColor)
                    .multilineTextAlignment(.leading)
                if let sub {
                    Text(sub)
                        .font(.caption)
                        .foregroundStyle(ZTColor.muted)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                Text(value)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(ZTColor.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            trailing()
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ZTColor.muted.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 46)
        .contentShape(Rectangle())
    }
}

// MARK: - Pill

/// Pastille colorée (ok / warn / err / neutral / accent).
struct ZTPill: View {
    enum Tone { case ok, warn, err, neutral, accent }
    let tone: Tone
    let text: LocalizedStringKey

    private var fg: Color {
        switch tone {
        case .ok: return ZTColor.success
        case .warn: return ZTColor.warning
        case .err: return ZTColor.danger
        case .neutral: return ZTColor.muted
        case .accent: return ZTColor.primary
        }
    }

    private var bg: Color {
        switch tone {
        case .ok: return ZTColor.success.opacity(0.15)
        case .warn: return ZTColor.warning.opacity(0.15)
        case .err: return ZTColor.danger.opacity(0.15)
        case .neutral: return ZTColor.secondary
        case .accent: return ZTColor.primary.opacity(0.15)
        }
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(bg, in: Capsule())
    }
}

// MARK: - Segmented

/// Contrôle segmenté (équivalent du `Segmented` du prototype).
struct ZTSegmented<Option: Hashable>: View {
    let options: [(value: Option, label: LocalizedStringKey)]
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { opt in
                let on = selection == opt.value
                Button {
                    selection = opt.value
                } label: {
                    Text(opt.label)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(on ? ZTColor.foreground : ZTColor.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(ZTColor.card)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(ZTColor.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Large title & toast

/// Grand titre d'écran + bouton trailing optionnel.
struct ZTLargeTitle<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: LocalizedStringKey, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(ZTColor.foreground)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
}

/// Bouton circulaire de la grande barre de titre.
struct ZTCircleButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(ZTColor.primary)
                .frame(width: 36, height: 36)
                .background(ZTColor.card, in: Circle())
                .overlay { Circle().strokeBorder(ZTColor.stroke, lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

/// Bannière toast transitoire (fond sombre, texte clair).
struct ZTToast: View {
    let message: LocalizedStringKey?

    var body: some View {
        if let message {
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(ZTColor.background)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(ZTColor.foreground, in: Capsule())
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
