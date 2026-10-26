import SwiftUI
import AppKit

/// La carte Réseau enrichie : le débit et le cumul d'avant, puis la
/// connexion (passerelle, Internet, Wi-Fi), le forfait iPhone et les
/// applications qui transfèrent. Le détail de la connexion — adresses, DNS,
/// canal, norme — s'ouvre depuis la carte, comme les 7 derniers jours : un
/// seul historique ouvert à la fois dans tout le panneau.
///
/// Règles dures tenues : aucune teinte sur du texte (n° 6) ; la seule jauge
/// est celle du forfait, sur son vrai dénominateur (n° 7), et n'existe pas
/// tant que le forfait n'est pas réglé ; base 1000 pour les octets (n° 3).
struct CarteReseau: View {
    @ObservedObject var sampler: Sampler
    let context: CardContext
    @ObservedObject private var moniteur = MoniteurReseau.shared
    @ObservedObject private var reglagesApp = SettingsStore.shared
    /// `--edition-forfait` ouvre l'éditeur dans un rendu hors écran, pour le
    /// voir. (`--reglages` est la fenêtre Réglages du socle.)
    @State private var edition = !Persistence.enabled && CommandLine.arguments.contains("--edition-forfait")
    /// L'arrivée du dernier relevé de débit : le miroir défile depuis elle
    /// (chantier 10). Rendus hors écran (`--snapshot`) : immobile ; le banc,
    /// lui, le fait défiler, pour en mesurer le coût.
    @State private var arrivee: Date?

    /// Ceux que le panneau passe à la carte (`context`), tirés du même
    /// `SettingsStore` : un rendu figé peut ainsi donner les siens.
    private var reglages: ReglagesReseau {
        ReglagesReseau(options: context.settings.options)
    }

    var body: some View {
        let net = sampler.network
        Card {
            // Le titre ouvre le débit dans l'historique longue durée (chantier
            // 02), comme le titre des autres cartes (chantier 10).
            HistoryToggle(key: "debit", label: "du débit", spoken: "Réseau",
                          value: net.connected ? net.label : "hors ligne", heading: true, open: context.open) {
                CardTitle(title: "Réseau", symbol: symbole(net), trailing: net.connected ? net.label : "hors ligne",
                          open: context.open.wrappedValue == "debit")
            }
            debit(net)
            if !context.compact {
                jours
                connexion(net)
                forfait(net)
                if nombreApps > 0 { applications }
            }
            // En bas de carte, comme les historiques des cinq autres.
            HistoryPanel(key: "debit", open: context.open.wrappedValue) {
                HistoryChart(keys: ["reseau.envoi", "reseau.reception"], title: "Débit", plotHeight: 34)
            }
        }
        // Par sûreté : le module l'allume déjà à l'ouverture du panneau et
        // l'éteint à la fermeture. Le contenu du panneau, lui, n'existe que
        // pendant l'ouverture : disparue, la carte n'a plus rien à mesurer.
        .onAppear { moniteur.regler(actif: true) }
        .onDisappear { moniteur.regler(actif: false) }
    }

    // MARK: - Débit et cumul (la carte d'avant)

    private func debit(_ net: NetworkSample) -> some View {
        let trail = sampler.networkTrail
        // Plancher de 10 ko/s : sans lui, quelques octets d'un réseau au
        // repos se dessineraient comme des pics.
        let peakUp = max(trail.map(\.txRate).max() ?? 0, 10_000)
        let peakDown = max(trail.map(\.rxRate).max() ?? 0, 10_000)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                taux(net.txRate, "Envoi", Palette.data)
                Spacer()
                taux(net.rxRate, "Réception", Palette.muted)
            }
            VStack(spacing: 3) {
                MirrorBars(up: trail.map { $0.txRate / peakUp }, down: trail.map { $0.rxRate / peakDown },
                           upTint: Palette.data, downTint: Palette.muted, slots: Sampler.networkTrailLength,
                           readout: { slot in
                               // Survol : l'heure du relevé, ses deux débits (chantier 10).
                               let index = slot - (Sampler.networkTrailLength - trail.count)
                               guard index >= 0, index < trail.count else { return nil }
                               let ago = Double(trail.count - 1 - index) * Sampler.networkPeriod
                               return [HoverTime.second(Date().addingTimeInterval(-ago)),
                                       "↑ \(Fmt.bytes(trail[index].txRate))/s",
                                       "↓ \(Fmt.bytes(trail[index].rxRate))/s"]
                           },
                           scroll: arrivee.map { ScrollClock(arrival: $0, period: Sampler.networkPeriod) },
                           spoken: "Débit des 3 dernières minutes : envoi au plus "
                            + "\(Fmt.bytes(trail.map(\.txRate).max() ?? 0)) par seconde, réception au plus "
                            + "\(Fmt.bytes(trail.map(\.rxRate).max() ?? 0)) par seconde")
                    .clipped()
                    .onReceive(sampler.$networkTrail.dropFirst()) { _ in
                        if !CommandLine.arguments.contains("--snapshot") { arrivee = Date() }
                    }
                    .frame(height: 40)
                HStack {
                    Text("max ↑ \(Fmt.rate(trail.map(\.txRate).max() ?? 0, context.display.rateUnit))")
                    Spacer()
                    Text("3 dernières minutes")
                    Spacer()
                    Text("max ↓ \(Fmt.rate(trail.map(\.rxRate).max() ?? 0, context.display.rateUnit))")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func taux(_ value: Double, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Fmt.rate(value, context.display.rateUnit)).font(.title3.monospacedDigit().weight(.medium))
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
        // Le nom d'abord, puis le débit : « Envoi, 5,7 ko/s » (chantier 16).
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(Fmt.rate(value, context.display.rateUnit).replacingOccurrences(of: "/s", with: " par seconde"))
    }

    private var jours: some View {
        let days = sampler.networkHistory(days: 2)
        return VStack(spacing: 3) {
            if let today = days.last { jour("Aujourd'hui", today.usage) }
            if days.count == 2, let yesterday = days.first { jour("Hier", yesterday.usage) }
            HistoryToggle(key: "reseau", label: "de la consommation internet", spoken: "7 derniers jours",
                          open: context.open) {
                HStack {
                    Text("7 derniers jours").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    DisclosureChevron(open: context.open.wrappedValue == "reseau")
                }
            }
            HistoryPanel(key: "reseau", open: context.open.wrappedValue) {
                NetworkPanel(sampler: sampler)
            }
        }
    }

    private func jour(_ name: String, _ usage: [NetworkTracker.Usage]) -> some View {
        let total = usage.reduce(0) { $0 + $1.rx + $1.tx }
        let phone = usage.filter { $0.kind == .hotspot }.reduce(0) { $0 + $1.rx + $1.tx }
        let value = phone > 0 ? "\(Fmt.bytes(total)) · iPhone \(Fmt.bytes(phone))" : Fmt.bytes(total)
        return InfoRow(label: name, value: total > 0 ? value : "—")
    }

    // MARK: - Connexion

    private func connexion(_ net: NetworkSample) -> some View {
        let etat = EtatConnexion.juger(connecte: net.connected, passerelle: moniteur.passerelle,
                                       internet: moniteur.internet)
        let ouvert = context.open.wrappedValue == "connexion"
        return VStack(alignment: .leading, spacing: 3) {
            CardCaption(text: "Connexion")
            HistoryToggle(key: "connexion", label: "de la connexion", spoken: etat.phrase, open: context.open) {
                HStack(spacing: 7) {
                    Image(systemName: etat.symbole)
                        .font(.callout)
                        .foregroundStyle(teinte(etat.niveau))
                        .frame(width: 15)
                        .accessibilityHidden(true)
                    Text(etat.phrase).font(.callout).lineLimit(1)
                    Spacer(minLength: 0)
                    DisclosureChevron(open: ouvert)
                }
            }
            if net.connected {
                let internet = texte(moniteur.internet, vide: moniteur.appsMesurees ? "—" : "…")
                if reglages.pingPasserelle {
                    InfoRow(label: net.kind == .hotspot ? "iPhone · Internet" : "Passerelle · Internet",
                            value: "\(texte(moniteur.passerelle, vide: "…")) · \(internet)")
                } else {
                    // « ~38 ms » se lisait « tilde 38 ms » (chantier 16).
                    InfoRow(label: "Latence Internet", value: internet,
                            spoken: "Latence Internet, " + internet.replacingOccurrences(of: "~", with: "environ "))
                }
                if let wifi = moniteur.wifi {
                    HStack(spacing: 7) {
                        Text("Wi-Fi").font(.callout).foregroundStyle(.secondary)
                        Image(systemName: "wifi", variableValue: Double(wifi.barres) / 4)
                            .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                        Spacer(minLength: 6)
                        Text("\(Self.dbm(wifi.rssi)) · \(wifi.qualite)").font(.callout.monospacedDigit())
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if ouvert {
                DetailPanel(legende: "Mesuré sur place. La latence Internet se lit sur le trafic déjà en cours : aucun octet n'est envoyé pour elle. Le ping de la passerelle se coche dans les réglages.",
                            detail: nil) {
                    DetailConnexion(moniteur: moniteur, ipPublique: reglages.ipPublique)
                }
            }
        }
    }

    /// « 4 ms », « ~21 ms » (passif : le plus court des RTT en cours), et
    /// les pertes quand il y en a.
    private func texte(_ latence: Latence, vide: String) -> String {
        Self.texte(latence, vide: vide)
    }

    static func texte(_ latence: Latence, vide: String) -> String {
        guard let ms = latence.ms else {
            return latence.essais > 0 && latence.perdus == latence.essais ? "sans réponse" : vide
        }
        let approx = latence.source == "trafic en cours" ? "~" : ""
        return "\(approx)\(Self.ms(ms))"
    }

    /// « −68 dBm », avec le vrai signe moins (U+2212), pas un trait d'union.
    nonisolated static func dbm(_ valeur: Int) -> String {
        valeur < 0 ? "\u{2212}\(-valeur) dBm" : "\(valeur) dBm"
    }

    nonisolated static func ms(_ valeur: Double) -> String {
        valeur < 10 ? String(format: "%.1f ms", valeur).replacingOccurrences(of: ".", with: ",")
                    : "\(Int(valeur.rounded())) ms"
    }

    // MARK: - Forfait iPhone

    @ViewBuilder
    private func forfait(_ net: NetworkSample) -> some View {
        let etat = sampler.forfait(reglages)
        let reglages = reglages
        // Rien à dire tant qu'aucun forfait n'est réglé, que le partage
        // iPhone n'a rien consommé sur le cycle et qu'on n'y est pas : une
        // ligne pour le régler, pas une section vide.
        let pertinent = reglages.forfaitGo != nil || etat.consomme > 0 || net.kind == .hotspot
        VStack(alignment: .leading, spacing: 5) {
            if pertinent {
                CardCaption(text: "Forfait iPhone",
                            trailing: reglages.forfaitGo == nil ? "ce Mac seulement" : "renouvelé le \(reglages.jourRenouvellement)")
                if let fraction = etat.fraction, let quota = etat.quota {
                    Meter(fraction: fraction, tint: teinte(etat.niveau), height: 6)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if etat.niveau == .proche || etat.niveau == .depasse {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(teinte(etat.niveau)).accessibilityHidden(true)
                        }
                        Text("\(Fmt.bytes(etat.consomme)) sur \(Fmt.bytes(quota, digits: quota % 1_000_000_000 == 0 ? 0 : 1))")
                            .font(.callout.monospacedDigit())
                        Spacer(minLength: 6)
                        Text(Fmt.percent(fraction)).font(.callout.monospacedDigit().weight(.medium))
                    }
                    .accessibilityElement(children: .combine)
                    let resume = Self.resume(etat)
                    if !resume.isEmpty {
                        Text(resume).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    InfoRow(label: "Depuis le \(Self.jourMois(etat.debut))", value: Fmt.bytes(etat.consomme))
                }
                if etat.parJour.contains(where: { $0.octets > 0 }) {
                    VStack(spacing: 2) {
                        // Violet, la teinte de l'iPhone dans le dépliant des
                        // 7 jours ; l'orange reste réservé à « attention ».
                        ColonnesForfait(jours: etat.parJour, budget: etat.budgetParJour, teinte: Palette.tertiary)
                            .frame(height: 26)
                        HStack {
                            Text(Self.jourMois(etat.debut))
                            Spacer()
                            if etat.budgetParJour != nil { Text("pointillé : budget du jour") }
                            Spacer()
                            Text("aujourd'hui")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Consommation par jour du cycle, partage iPhone")
                    // Les jours où l'iPhone a servi, avec leur total : la
                    // ligne « par jour » de `--probe` (chantier 16).
                    .accessibilityValue(etat.parJour.filter { $0.octets > 0 }
                        .map { "\(Self.jourMois($0.jour)) \(Fmt.bytes(Double($0.octets)))" }
                        .joined(separator: ", "))
                }
            }
            if edition {
                EditeurForfait(reglages: Binding(get: { self.reglages }, set: { ReglagesReseau.enregistrer($0) })) {
                    edition = false
                }
            } else {
                // Une ligne à chevron, comme « 7 derniers jours », et non un
                // lien bleu : la couleur de lien du système tombe à 4,08:1
                // sur la carte sombre (mesuré le 11/10), sous les 4,5:1 du
                // texte. Et un bouton AppKit ne se dessine pas hors écran.
                Button { edition = true } label: {
                    HStack {
                        Text(reglages.forfaitGo == nil ? "Régler le forfait iPhone" : "Modifier le forfait")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        DisclosureChevron(open: false)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pulseRow)
                .accessibilityLabel(reglages.forfaitGo == nil ? "Régler le forfait iPhone" : "Modifier le forfait iPhone")
            }
        }
    }

    static func resume(_ etat: EtatForfait) -> String {
        var parts: [String] = []
        if let reste = etat.reste { parts.append(reste > 0 ? "reste \(Fmt.bytes(reste))" : "forfait épuisé") }
        if let rythme = etat.rythme { parts.append("~\(Fmt.bytes(rythme)) par jour") }
        if let vers = etat.epuiseVers { parts.append("épuisé\u{00A0}vers\u{00A0}le\u{00A0}\(jourMois(vers))\u{00A0}à\u{00A0}ce\u{00A0}rythme") }
        return parts.joined(separator: " · ")
    }

    /// « 1er oct. », « 12 oct. » : l'ordinal du premier jour, comme on
    /// l'écrit en français.
    static func jourMois(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "MMM"
        let jour = Calendar.current.component(.day, from: date)
        return "\(jour == 1 ? "1er" : String(jour))\u{00A0}\(f.string(from: date))"
    }

    // MARK: - Apps

    /// Cinq par défaut, comme le menu réseau d'iStat ; le nombre réglé par
    /// Isma dans la fenêtre Réglages l'emporte.
    private var nombreApps: Int { context.settings.appCount ?? 5 }

    /// Les plus actives, au-dessus de 500 o/s : en dessous, ce sont des
    /// battements de cœur de connexion, pas un transfert.
    private var actives: [SuiviSockets.DebitApp] {
        Array(moniteur.apps.filter { $0.total >= 500 }.prefix(nombreApps))
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardCaption(text: "Apps", trailing: "envoi · réception, par seconde")
            if !SuiviSockets.disponible {
                Text("Débit par app indisponible sur ce macOS").font(.caption).foregroundStyle(.secondary)
            } else if !moniteur.appsMesurees {
                Text("mesure en cours").font(.caption).foregroundStyle(.secondary)
            } else if actives.isEmpty {
                Text("Aucune app ne transfère en ce moment").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(actives) { app in LigneAppReseau(app: app) }
            }
        }
    }

    // MARK: - Outils

    private func teinte(_ niveau: NiveauForfait) -> Color {
        switch niveau {
        case .depasse: return Palette.alert
        case .proche: return Palette.warning
        case .normal, .nonRegle: return Palette.data
        }
    }

    private func teinte(_ niveau: EtatConnexion.Niveau) -> Color {
        switch niveau {
        case .alerte: return Palette.alert
        case .avertissement: return Palette.warning
        case .calme: return Palette.muted
        }
    }

    private func symbole(_ net: NetworkSample) -> String {
        guard net.connected else { return "wifi.slash" }
        switch net.kind {
        case .hotspot:  return "personalhotspot"
        case .starlink: return "antenna.radiowaves.left.and.right"
        case .wifi:     return "wifi"
        case .wired:    return "cable.connector"
        }
    }
}

/// Le détail de la connexion, déplié depuis la carte : tout ce que mesure le
/// moniteur, ligne par ligne, en petit.
struct DetailConnexion: View {
    @ObservedObject var moniteur: MoniteurReseau
    var ipPublique: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            let p = moniteur.passerelle
            ligne("Passerelle", [moniteur.adresses?.passerelle,
                                 p.essais == 0 && p.ms == nil ? "non mesurée" : CarteReseau.texte(p, vide: "mesure en cours"),
                                 p.essais > 0 ? "\(p.perdus) perdu\(p.perdus > 1 ? "s" : "") sur \(p.essais)" : nil])
            let i = moniteur.internet
            ligne("Internet", [CarteReseau.texte(i, vide: moniteur.appsMesurees ? "rien à mesurer" : "mesure en cours"),
                               i.source == "trafic en cours"
                                   ? (i.connexions > 0 ? "plus court de \(i.connexions) connexion\(i.connexions > 1 ? "s" : "")" : nil)
                                   : i.source])
            if let wifi = moniteur.wifi {
                ligne("Signal", [CarteReseau.dbm(wifi.rssi), "bruit \(CarteReseau.dbm(wifi.bruit))", "rapport \(wifi.snr) dB"])
                ligne("Liaison", ["\(Int(wifi.debitLiaison)) Mbit/s", wifi.canal.map { "canal \($0)" }, wifi.bande,
                                  wifi.largeurMHz.map { "\($0) MHz" }])
                if let norme = wifi.norme { ligne("Norme", [norme]) }
            }
            if let a = moniteur.adresses {
                ligne("IP locale", [a.ipv4.map { "\($0) (\(a.interface))" } ?? "aucune"])
                if let v6 = a.ipv6 { ligne("IPv6", [v6]) }
                if !a.dns.isEmpty { ligne("DNS", [a.dns.joined(separator: ", ")]) }
            }
            if ipPublique { ligne("IP publique", [moniteur.ipPublique ?? "demande en cours"]) }
        }
        .accessibilityElement(children: .combine)
    }

    private func ligne(_ nom: String, _ parts: [String?]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(nom).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(parts.compactMap { $0 }.joined(separator: " · "))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption.monospacedDigit())
    }
}

/// Une application : icône, nom, puis l'envoi et la réception en deux
/// colonnes de largeur fixe, alignées d'une ligne à l'autre.
struct LigneAppReseau: View {
    var app: SuiviSockets.DebitApp

    var body: some View {
        HStack(spacing: 7) {
            AppIcon(path: app.chemin).frame(width: 15, height: 15)
            Text(app.id.hasPrefix("exec:") ? Fmt.processName(app.nom) : Fmt.appName(app.nom))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            colonne("↑", app.envoye)
            colonne("↓", app.recu)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue("envoi \(Fmt.bytes(app.envoye)) par seconde, réception \(Fmt.bytes(app.recu)) par seconde")
    }

    /// « — » pour rien, « <1k » sous le kilo-octet : « 0k » se lisait comme
    /// une mesure nulle alors que des octets passaient.
    static func compact(_ debit: Double) -> String {
        if debit <= 0 { return "—" }
        if debit < 1_000 { return "<1k" }
        return Fmt.compactRate(debit).trimmingCharacters(in: CharacterSet(charactersIn: "\u{2007}"))
    }

    private func colonne(_ fleche: String, _ debit: Double) -> some View {
        Text("\(fleche) \(Self.compact(debit))")
            .font(.callout.monospacedDigit())
            .foregroundStyle(debit >= 500 ? .primary : .secondary)
            .frame(width: 58, alignment: .trailing)
    }
}

/// L'indicateur de connexion : une phrase et un symbole, la couleur ne
/// portant jamais le sens seule. Seuils POSÉS, pas mesurés : 2 pings perdus
/// sur les 10 derniers, Internet au-delà de 150 ms.
struct EtatConnexion: Equatable {
    enum Niveau: Equatable { case calme, avertissement, alerte }
    var niveau: Niveau
    var symbole: String
    var phrase: String

    static let internetLent: Double = 150
    static let pertesMax = 2

    static func juger(connecte: Bool, passerelle: Latence, internet: Latence) -> EtatConnexion {
        guard connecte else { return .init(niveau: .alerte, symbole: "wifi.slash", phrase: "Hors ligne") }
        // Une passerelle qui n'a JAMAIS répondu filtre le ping : ce n'est
        // pas une panne, et le trafic en cours dit si Internet passe. Seule
        // une passerelle qui répondait et se tait est une alerte.
        if passerelle.essais > 0, !passerelle.aRepondu {
            return .init(niveau: .calme, symbole: "questionmark.circle",
                         phrase: internet.ms != nil ? "Connecté, passerelle muette au ping" : "Passerelle muette au ping")
        }
        if passerelle.essais > 0, passerelle.ms == nil, passerelle.perdus >= min(pertesMax, passerelle.essais) {
            return .init(niveau: .alerte, symbole: "exclamationmark.triangle.fill",
                         phrase: "La passerelle ne répond plus")
        }
        if passerelle.perdus >= pertesMax {
            return .init(niveau: .avertissement, symbole: "exclamationmark.triangle.fill",
                         phrase: "Liaison instable : \(passerelle.perdus) pings perdus sur \(passerelle.essais)")
        }
        if let ms = internet.ms, ms > internetLent {
            return .init(niveau: .avertissement, symbole: "tortoise.fill",
                         phrase: "Internet lent : \(CarteReseau.ms(ms)) d'aller-retour")
        }
        return .init(niveau: .calme, symbole: "checkmark.circle", phrase: "Connexion stable")
    }
}

/// Une colonne par jour du cycle, à l'échelle du plus gros jour ou du budget
/// journalier s'il est plus haut ; le budget en pointillé : les jours qui le
/// dépassent se voient d'un coup d'œil.
struct ColonnesForfait: View {
    var jours: [EtatForfait.Jour]
    var budget: Double?
    var teinte: Color

    var body: some View {
        Canvas { context, size in
            let haut = max(Double(jours.map(\.octets).max() ?? 0), budget ?? 0, 1)
            let pas = size.width / CGFloat(max(jours.count, 1))
            let largeur = max(1, pas * 0.64)
            for (i, jour) in jours.enumerated() {
                let h = jour.octets == 0 ? 1 : max(1.5, CGFloat(Double(jour.octets) / haut) * (size.height - 1))
                let rect = CGRect(x: CGFloat(i) * pas + (pas - largeur) / 2, y: size.height - h,
                                  width: largeur, height: h)
                context.fill(Path(rect), with: .color(jour.octets == 0 ? Palette.track : teinte))
            }
            if let budget {
                let y = size.height - CGFloat(budget / haut) * (size.height - 1)
                var trait = Path()
                trait.move(to: CGPoint(x: 0, y: y))
                trait.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(trait, with: .color(Palette.muted), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
    }
}

/// Le réglage du forfait dans la carte : le quota par paliers d'opérateur, le
/// jour de renouvellement, et les deux mesures qui sortiraient sur Internet.
/// Les mêmes réglages que la fenêtre Réglages, au même endroit.
struct EditeurForfait: View {
    @Binding var reglages: ReglagesReseau
    var fini: () -> Void

    static let paliers: [Double] = ReglagesReseau.paliers.map(Double.init)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper {
                Text(reglages.forfaitGo.map { "Forfait : \(Fmt.bytes($0 * 1e9, digits: 0))" } ?? "Forfait : non réglé")
                    .font(.callout.monospacedDigit())
            } onIncrement: {
                let actuel = reglages.forfaitGo ?? 0
                reglages.forfaitGo = Self.paliers.first { $0 > actuel } ?? Self.paliers.last
            } onDecrement: {
                let actuel = reglages.forfaitGo ?? 0
                reglages.forfaitGo = Self.paliers.last { $0 < actuel }
            }
            Stepper(value: $reglages.jourRenouvellement, in: 1...31) {
                Text("Renouvelé le \(reglages.jourRenouvellement) du mois").font(.callout.monospacedDigit())
            }
            Toggle("Afficher l'IP publique (sort sur Internet)", isOn: $reglages.ipPublique)
                .font(.caption)
            Toggle("Ping Internet chaque minute (sort sur Internet)", isOn: $reglages.sondeInternet)
                .font(.caption)
            Toggle("Ping de la passerelle (macOS peut demander l'accès au réseau local)", isOn: $reglages.pingPasserelle)
                .font(.caption)
            HStack {
                Text("Ce Mac seulement : l'iPhone et les autres appareils n'y sont pas.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button("OK", action: fini).controlSize(.small)
            }
        }
        .toggleStyle(.checkbox)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
    }
}
