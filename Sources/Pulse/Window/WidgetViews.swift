import SwiftUI

/// Les vues des widgets : disque de rushes, mémoire, forfait iPhone.
///
/// Elles n'affichent que `EtatPartage`, déjà mis en mots par l'app : le
/// widget dit au caractère près ce que dit le panneau. Aucune ne mesure.
/// Partagées par l'extension de widgets et par `--snapshot --widget`, qui
/// les rend hors écran.
///
/// Mêmes règles que le panneau : le texte reste `.primary` ou `.secondary`
/// (règle n°6) ; la seule barre est une part d'un total réel — l'occupation
/// d'un volume, la part d'un forfait réglé (règle n°7) ; une teinte n'est
/// jamais seule à porter le sens (règle n°4), le symbole et les mots le
/// disent aussi.
enum WidgetKind: String, CaseIterable {
    case disque, memoire, forfait

    var title: String {
        switch self {
        case .disque:  return "Disque de rushes"
        case .memoire: return "Mémoire"
        case .forfait: return "Partage iPhone"
        }
    }

    var summary: String {
        switch self {
        case .disque:  return "L'espace libre du disque de rushes et le jour où il sera plein."
        case .memoire: return "La mémoire utilisée, la pression et le swap."
        case .forfait: return "Ce que ce Mac a consommé aujourd'hui par le partage iPhone, et sur le forfait."
        }
    }

    var symbol: String {
        switch self {
        case .disque:  return "externaldrive"
        case .memoire: return "memorychip"
        case .forfait: return "personalhotspot"
        }
    }
}

enum WidgetSize: String {
    case petit, moyen

    /// Les tailles des widgets du bureau de macOS 26, en points.
    var points: CGSize {
        switch self {
        case .petit: return CGSize(width: 170, height: 170)
        case .moyen: return CGSize(width: 364, height: 170)
        }
    }
}

/// Les teintes des widgets : celles de `Palette`, mesurées (règle n°4).
/// Redites ici parce que l'extension de widgets ne voit pas l'app.
enum WidgetTint {
    static let data = Color(nsColor: .systemBlue)
    static let alert = Color(nsColor: .systemRed)
    static let warning = Color(nsColor: NSColor(name: "pulseWidgetWarning") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemOrange
            : NSColor(srgbRed: 0.722, green: 0.361, blue: 0.0, alpha: 1)
    })
    static let track = Color.primary.opacity(0.12)

    /// Le fond du widget, posé par le widget lui-même
    /// (`containerBackground`) : celui des cartes du panneau, sur lequel les
    /// teintes ont leur ratio mesuré — #FAFAFA en clair, #1E1E1E en sombre.
    /// Le fond système des widgets (#ECECEC en clair) ferait tomber le bleu
    /// sous 3:1. En mode « teinté » du bureau, macOS remplace tout par du
    /// monochrome : la barre garde sa longueur, les mots disent la valeur.
    static let background = Color(nsColor: NSColor(name: "pulseWidgetBackground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.118, green: 0.118, blue: 0.118, alpha: 1)
            : NSColor(srgbRed: 0.980, green: 0.980, blue: 0.980, alpha: 1)
    })

    /// L'occupation d'un volume : mêmes seuils que la carte Disques et le
    /// verdict (90 % avertissement, 95 % alerte).
    static func volume(_ fraction: Double) -> Color {
        if fraction >= 0.95 { return alert }
        if fraction >= 0.90 { return warning }
        return data
    }

    static func forfait(_ fraction: Double) -> Color {
        if fraction >= 1 { return alert }
        if fraction >= 0.8 { return warning }
        return data
    }
}

/// Le widget, tel que l'extension et `--snapshot` le dessinent.
struct PulseWidgetView: View {
    var kind: WidgetKind
    var size: WidgetSize
    /// Nil : Pulse n'a encore rien écrit (premier lancement, ou Pulse
    /// arrêté depuis longtemps).
    var etat: EtatPartage?
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let etat {
                switch kind {
                case .disque:  disque(etat)
                case .memoire: memoire(etat)
                case .forfait: forfait(etat)
                }
                Spacer(minLength: 0)
                footer(etat)
            } else {
                Spacer(minLength: 0)
                Text("En attente du premier relevé de Pulse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: kind.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(kind.title.uppercased())
                .font(.caption2.weight(.medium))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Depuis quand ces chiffres datent : un widget se rafraîchit toutes
    /// les quelques minutes, il ne doit pas passer pour un direct.
    private func footer(_ etat: EtatPartage) -> some View {
        Text(Self.age(of: etat.date, now: now))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    static func age(of date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "relevé à l'instant" }
        if minutes < 60 { return "relevé il y a \(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "relevé il y a \(hours) h — Pulse tourne-t-il ?" }
        return "relevé il y a \(hours / 24) j — Pulse tourne-t-il ?"
    }

    // MARK: - Disque

    @ViewBuilder
    private func disque(_ etat: EtatPartage) -> some View {
        if let disque = etat.disqueDeRushes {
            Text(disque.nom + (disque.interne && etat.rushes == nil ? " · aucun disque externe" : ""))
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(disque.libre)
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text("libres")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Bar(fraction: disque.occupation, tint: WidgetTint.volume(disque.occupation))
                .accessibilityLabel("occupé à \(disque.occupationTexte)")
            Text("occupé à \(disque.occupationTexte)" + (size == .moyen ? " sur \(disque.total)" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let tendance = disque.tendance {
                Label(tendance, systemImage: disque.joursAvantPlein.map { $0 < 30 ? "exclamationmark.triangle" : "calendar" } ?? "calendar")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        } else {
            Text("Aucun disque relevé")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Mémoire

    @ViewBuilder
    private func memoire(_ etat: EtatPartage) -> some View {
        let m = etat.memoire
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(m.utilisee)
                .font(.title.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
            Text("sur \(m.totale)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        Bar(fraction: m.fraction, tint: WidgetTint.data)
            .accessibilityLabel("mémoire utilisée, \(Int((m.fraction * 100).rounded())) pour cent")
        Text("pression \(m.pression)")
            .font(.callout)
            .foregroundStyle(.primary)
            .lineLimit(1)
        Text(m.swapOctets > 0 ? "swap \(m.swap)" : "aucun swap")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        if size == .moyen {
            Text(etat.verdict.phrase)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Forfait

    @ViewBuilder
    private func forfait(_ etat: EtatPartage) -> some View {
        if let f = etat.forfait {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(f.aujourdhui)
                    .font(.title.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                Text("aujourd'hui")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            if let fraction = f.fraction, let quota = f.quota {
                Bar(fraction: fraction, tint: WidgetTint.forfait(fraction))
                    .accessibilityLabel("\(f.cycle) sur \(quota)")
                Text("\(f.cycle) sur \(quota) ce cycle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("\(f.cycle) ce cycle · forfait non réglé")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let echeance = f.echeance {
                Label(echeance, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        } else {
            Text("Partage iPhone pas encore compté")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Une part d'un total réel, en barre fine.
private struct Bar: View {
    var fraction: Double
    var tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(WidgetTint.track)
                Capsule().fill(tint)
                    .frame(width: max(4, geometry.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }
}
