import SwiftUI

// Les panneaux de détail : ce qui s'ouvre sous une statistique quand on la
// déplie. Un graphique par clé, aucun texte courant — l'utilisateur a tranché :
// « je veux pas de texte mais par exemple un graph, quelque chose de visuel ».
//
// Restent ici ceux des cartes Montage (session, apps, incidents) et Disques
// (volumes) : les trente jours d'espace libre par volume d'où sort la
// prévision de saturation, et les pics mémoire de chaque session de montage,
// que Pulse collectait sans les afficher. Les panneaux mémoire, GPU, cœurs,
// swap et exports, remplacés par les cartes, ont été retirés le 11/10
// (17-audit-code) : plus rien ne les appelait.
//
// Chaque vue a été écrite contre la source qui produit son chiffre, puis relue
// par un contrôleur chargé d'y trouver les violations des règles dures du
// projet. Les dix ont été corrigées. Parmi ce qui a été rattrapé : un ForEach
// identifié par le rang d'un tableau filtré, qui faisait changer une barre de
// couleur en cours d'animation ; une Color littérale contre la règle n°4 ; un
// « 30 jours » écrit en dur alors que la fenêtre vaut deux jours sur une
// installation neuve ; et des débordements de largeur mesurés sur les données
// réelles de cette machine.
//
// Largeur utile : 312 pt. 360 moins deux fois 14 pt de marge du popover, moins
// deux fois 10 pt de marge du panneau. Au-delà, ça déborde.

/// Ce qui s'ouvre sous la carte « session » : les deux pics de la session en
/// cours, puis le rythme des sept derniers jours.
///
/// `peakMemoryFraction`, `peakMemoryBytes` et `peakSwap` sont mesurés à chaque
/// relevé depuis le premier lancement et n'avaient jamais été dessinés. La
/// carte repliée ne dit que l'instant ; ce qui compte après une journée de
/// montage, c'est le plus haut qu'on ait atteint — et à quel rythme on
/// travaille depuis une semaine.
///
/// Attention à ce que ces pics mesurent : `SessionTracker.observe` les prend
/// sur `MemorySample`, donc sur la MACHINE ENTIÈRE, pas sur l'application de
/// montage. La carte repliée, elle, affiche la mémoire de l'app
/// (`ProcessGroup.footprint`). Deux chiffres voisins, deux sujets : les
/// libellés et la légende le disent, sans quoi le pic se lirait comme celui
/// de Premiere.
struct SessionPanel: View {
    @ObservedObject var sampler: Sampler

    /// Un jour, et les sessions qui y ont COMMENCÉ. Les libellés sont calculés
    /// ici plutôt qu'au tracé : le calendrier est relu une seule fois par rendu.
    private struct Jour: Identifiable {
        var date: Date
        var durees: [TimeInterval]
        var initiale: String
        var nom: String
        var estAujourdhui: Bool
        var id: Double { date.timeIntervalSince1970 }
        var total: TimeInterval { durees.reduce(0, +) }
    }

    /// Assez haut pour lire un rapport de 1 à 10 entre deux journées, assez
    /// court pour rester un détail : le popover grandit vers le bas.
    private let barsHeight: CGFloat = 30

    /// Largeur fixe, et non une colonne étirée sur son septième de panneau :
    /// à 44 pt de large une journée de montage devient un pavé, et la rangée se
    /// lit comme un mur plutôt que comme des barres.
    private let barWidth: CGFloat = 26

    /// Plancher d'échelle. Sans lui, une semaine à trente minutes dessinerait
    /// exactement les mêmes colonnes qu'une semaine de montage : la plus haute
    /// remplit toujours le cadre. Même parade que le plancher d'amplitude des
    /// courbes de volumes.
    ///
    /// C'est bien un PLANCHER : l'échelle reste celle de la journée la plus
    /// longue de la semaine dès qu'elle dépasse 4 h. La légende doit le dire,
    /// sinon une colonne pleine se lirait « 4 h » un jour où elle en vaut 9.
    private let echelleMinimale: TimeInterval = 4 * 3600

    /// Au plus huit blocs par colonne. Chaque bloc a 2 pt de plancher et 1 pt
    /// de séparateur : à partir de onze sessions dans la journée la pile
    /// dépasserait les 30 pt du cadre, et rien ne rogne — la colonne
    /// passerait par-dessus les deux barres de pics. Onze sessions n'a rien
    /// d'absurde ici : Premiere qui plante et qu'on relance, c'est justement
    /// ce que la section Incidents compte. Les plus courtes sont fondues dans
    /// un seul bloc de tête.
    private let maxBlocs = 8

    var body: some View {
        // Une seule lecture du journal par rendu : `recentSessions` prend le
        // verrou du store, et la vue se réévalue à chaque relevé (1,5 s).
        let jours = self.jours
        return VStack(alignment: .leading, spacing: 7) {
            if let session = sampler.session {
                pics(session)
            }
            semaine(jours)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("pics de la machine pendant la session en cours et temps de montage des sept derniers jours")
        .accessibilityValue(spoken(jours))
        // Les pics et la colonne du jour bougent pendant que le popover est
        // ouvert : VoiceOver doit relire, pas garder sa première valeur.
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Pics de la session en cours

    /// Les deux barres partagent l'axe de la courbe du popover : une fraction
    /// de la mémoire PHYSIQUE. Sur une échelle propre, 2 Gio de swap
    /// rempliraient la barre et se liraient comme une saturation.
    ///
    /// « machine » dans le libellé : la carte juste au-dessus affiche
    /// « mémoire » pour l'application de montage seule, et sans ce mot les
    /// deux chiffres se contrediraient à 30 pt d'écart.
    private func pics(_ session: EditingSession) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            pic("pic machine",
                fraction: session.peakMemoryFraction,
                value: Fmt.memory(session.peakMemoryBytes),
                tint: Palette.data)
            // Jauge grise et « aucun » quand rien n'a été écrit : `Meter` garde
            // 2 pt de remplissage minimum, et un moignon orange ferait croire à
            // un peu de swap là où il n'y en a pas eu du tout.
            pic("pic swap",
                fraction: swapFraction(session.peakSwap),
                value: session.peakSwap > 0 ? Fmt.memory(session.peakSwap) : "aucun",
                tint: session.peakSwap > 0 ? Palette.warning : Palette.muted)
        }
    }

    private func pic(_ label: String, fraction: Double, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 72, alignment: .leading)
            Meter(fraction: fraction, tint: tint, height: 5)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
        }
    }

    /// Le swap rapporté à la mémoire physique, jamais à `swapTotal` : macOS
    /// agrandit ses fichiers de swap à mesure qu'ils se remplissent, et ce
    /// rapport-là resterait collé autour de 90 % quoi qu'il arrive.
    private func swapFraction(_ swap: Double) -> Double {
        let total = Double(sampler.memory.total)
        return total > 0 ? swap / total : 0
    }

    // MARK: - Sept derniers jours

    @ViewBuilder
    private func semaine(_ jours: [Jour]) -> some View {
        let echelle = max(jours.map(\.total).max() ?? 0, echelleMinimale)
        if jours.allSatisfy({ $0.total <= 0 }) {
            Text("aucune session enregistrée sur les sept derniers jours")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: barsHeight, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(jours) { colonne($0, echelle: echelle) }
                }
                .frame(height: barsHeight, alignment: .bottom)
                // Même ligne de base que la courbe mémoire : sans elle, un jour
                // sans montage serait un trou, et non un zéro.
                .background(alignment: .bottom) {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                }
                HStack(spacing: 4) {
                    ForEach(jours) { jour in
                        Text(jour.initiale)
                            .font(.caption2)
                            .foregroundStyle(jour.estAujourdhui ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    /// Une colonne par jour, découpée en blocs : deux ouvertures de Premiere
    /// dans la même journée se voient, là où une barre pleine les confondrait.
    /// Les séparateurs sont retranchés de la hauteur — sinon une journée hachée
    /// paraîtrait plus longue qu'une journée d'un seul tenant.
    ///
    /// Le jour courant est bleu, les précédents gris : c'est la paire de la
    /// rangée de cœurs, et elle évite d'ajouter une légende au dépliant.
    private func colonne(_ jour: Jour, echelle: TimeInterval) -> some View {
        let blocs = self.blocs(jour.durees)
        let hauteur = barsHeight * CGFloat(min(1, jour.total / echelle))
        let utile = max(0, hauteur - CGFloat(max(0, blocs.count - 1)))
        return VStack(spacing: 1) {
            ForEach(Array(blocs.enumerated()), id: \.offset) { _, duree in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(jour.estAujourdhui ? Palette.data : Palette.muted)
                    // Plancher de 2 pt, comme la rangée de cœurs : une session
                    // de dix minutes à côté d'une journée de huit heures ferait
                    // sinon une colonne vide, qui se lirait « rien ce jour-là ».
                    // Le total est borné par `maxBlocs` : 8 × 2 + 7 = 23 pt,
                    // sous les 30 pt du cadre quoi qu'il arrive.
                    .frame(height: max(2, utile * CGFloat(jour.total > 0 ? duree / jour.total : 0)))
            }
        }
        .frame(width: barWidth)
        .frame(maxWidth: .infinity, alignment: .bottom)
        .animation(Motion.value, value: hauteur)
    }

    /// Ramène une journée à huit blocs au plus, en fondant les sessions les
    /// plus courtes en une seule. La somme est conservée : la hauteur totale
    /// de la colonne ne bouge pas, seul le découpage se simplifie — et
    /// l'énoncé VoiceOver continue d'annoncer le vrai nombre de sessions.
    /// `durees` arrive trié par ordre croissant.
    private func blocs(_ durees: [TimeInterval]) -> [TimeInterval] {
        guard durees.count > maxBlocs else { return durees }
        let gardees = Array(durees.suffix(maxBlocs - 1))
        let fondues = durees.prefix(durees.count - (maxBlocs - 1)).reduce(0, +)
        return [fondues] + gardees
    }

    // MARK: - Données

    /// Chaque session est rattachée au jour où elle a COMMENCÉ. Une nuit de
    /// montage qui passe minuit reste une seule session : le journal n'en garde
    /// que les deux bornes, il n'y a rien à découper.
    private var jours: [Jour] {
        let calendrier = Calendar.current
        let aujourdhui = calendrier.startOfDay(for: Date())
        var parJour: [Date: [TimeInterval]] = [:]
        for session in sampler.recentSessions(days: 7) where session.duration > 0 {
            let jour = calendrier.startOfDay(for: Date(timeIntervalSince1970: session.start))
            parJour[jour, default: []].append(session.duration)
        }

        // Les noms de jours viennent du calendrier, mais avec une locale posée :
        // `Calendar.current` suit la LANGUE du système, et Pulse est en français
        // quelle qu'elle soit — sur une machine en anglais la semaine
        // s'afficherait « M T W T F S S ». Seule la locale change, le fuseau
        // reste celui du système, sinon le découpage des journées serait faux.
        var francais = calendrier
        francais.locale = Locale(identifier: "fr_FR")
        let initiales = francais.veryShortStandaloneWeekdaySymbols
        let noms = francais.standaloneWeekdaySymbols

        return (0..<7).reversed().compactMap { recul in
            guard let jour = calendrier.date(byAdding: .day, value: -recul, to: aujourdhui) else { return nil }
            let index = calendrier.component(.weekday, from: jour) - 1
            // Blocs empilés du plus court au plus long : la session principale
            // de la journée se pose sur la ligne de base, là où l'œil compare
            // les colonnes entre elles.
            return Jour(date: jour,
                        durees: (parJour[jour] ?? []).sorted(),
                        initiale: initiales.indices.contains(index) ? initiales[index] : "",
                        nom: recul == 0 ? "aujourd'hui"
                                        : (noms.indices.contains(index) ? noms[index] : ""),
                        estAujourdhui: recul == 0)
        }
    }

    // MARK: - Énoncé

    /// Un graphique muet est inutilisable à VoiceOver : les deux pics et chaque
    /// journée sont énoncés en toutes lettres, avec le nombre de sessions quand
    /// la colonne en empile plusieurs — c'est ce que le découpage montre à l'œil.
    private func spoken(_ jours: [Jour]) -> String {
        var phrases: [String] = []
        if let session = sampler.session {
            let swap = session.peakSwap > 0 ? Fmt.memory(session.peakSwap) : "aucun"
            phrases.append("session \(session.name) : pic de mémoire de la machine "
                         + "\(Fmt.memory(session.peakMemoryBytes)), "
                         + "soit \(Fmt.percent(session.peakMemoryFraction)) de la mémoire physique ; "
                         + "pic de swap \(swap)")
        }
        let actifs = jours.filter { $0.total > 0 }
        if actifs.isEmpty {
            phrases.append("aucune session enregistrée sur les sept derniers jours")
        } else {
            phrases.append("sept derniers jours : " + actifs.map { jour in
                let duree = "\(jour.nom) \(Fmt.duration(jour.total))"
                return jour.durees.count > 1 ? "\(duree) en \(jour.durees.count) sessions" : duree
            }.joined(separator: ", "))
        }
        return phrases.joined(separator: ". ")
    }
}

/// Sept jours de temps au premier plan, une barre par jour.
///
/// Le popover n'affiche que le total du jour alors que `HistoryStore` en
/// conserve quatre-vingt-dix (`appWindow`) : la semaine était déjà collectée,
/// elle n'était nulle part visible. Sept barres suffisent à faire voir un
/// rythme de travail — la grosse journée de montage, le jour creux, le
/// week-end — sans que le dépliant devienne une page.
///
/// REMPLACE la version prose de `AppsPanel` dans ce fichier : il ne peut y
/// avoir qu'une seule déclaration du nom.
struct AppsPanel: View {
    @ObservedObject var sampler: Sampler

    /// Gabarit d'une barre. Un dépliant reste un détail : le popover grandit
    /// vers le bas, et plus haut il finirait sous le bord de l'écran.
    private let hauteurBarre: CGFloat = 54
    /// Largeur imposée, pas un plafond : le gabarit doit garder la même
    /// épaisseur quelle que soit la largeur que le parent propose.
    /// 7 × 26 + 6 × 6 = 218 pt, pour 312 pt utiles dans le panneau.
    private let largeurBarre: CGFloat = 26

    var body: some View {
        // `focusByDay` prend le verrou du store et resomme sept journées :
        // une seule lecture par passe de rendu, pas une par barre.
        graphe(sampler.focusByDay(days: 7))
    }

    @ViewBuilder
    private func graphe(_ jours: [(day: Date, seconds: TimeInterval)]) -> some View {
        let pic = jours.map(\.seconds).max() ?? 0
        if pic <= 0 {
            // Sans pic, les sept barres valent zéro : des creux alignés ne
            // diraient pas pourquoi ils sont vides.
            Text("aucun temps enregistré — le décompte démarre au premier changement d'application")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                // Haut de l'échelle. Sans lui les barres n'ont qu'une forme :
                // on lirait le rythme de la semaine, jamais les heures.
                //
                // « pic de la semaine » et non « pic » : l'étiquette est alignée
                // à droite, donc au-dessus de la colonne d'aujourd'hui, et un
                // « pic 3 h 36 » nu s'y lisait comme la valeur du jour.
                Text("pic de la semaine \(Fmt.duration(pic))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                HStack(alignment: .bottom, spacing: 6) {
                    // Identité par rang, pas par date : au passage de minuit la
                    // fenêtre glisse d'un cran et les barres s'animent vers leur
                    // nouvelle valeur. Indexées par date, elles disparaîtraient
                    // pour réapparaître ailleurs.
                    ForEach(Array(jours.enumerated()), id: \.offset) { _, jour in
                        colonne(jour: jour.day, secondes: jour.seconds, pic: pic)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Temps au premier plan par jour, sept derniers jours : \(enonce(jours))")
            .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func colonne(jour: Date, secondes: TimeInterval, pic: TimeInterval) -> some View {
        let aujourdhui = Calendar.current.isDateInToday(jour)
        // Plancher à 3 pt : une journée de dix minutes face à un pic de six
        // heures ferait moins d'un point de haut et se confondrait avec une
        // journée nulle. Zéro reste zéro — c'est le creux du gabarit qui le dit.
        // `pic` est strictement positif dans cette branche : pas de division
        // par zéro possible.
        let hauteur = secondes > 0 ? max(3, hauteurBarre * CGFloat(secondes / pic)) : 0

        return VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                // Gabarit toujours dessiné : un jour sans montage garde sa
                // colonne, en creux, sinon la semaine paraîtrait plus courte
                // qu'elle ne l'est. Même gris que la piste de `Meter` — il ne
                // code aucune donnée, il borne l'échelle.
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(aujourdhui ? Palette.data : Palette.muted)
                    .frame(height: hauteur)
                    .animation(Motion.value, value: hauteur)
            }
            .frame(width: largeurBarre, height: hauteurBarre)

            // Le jour courant est marqué deux fois, par la teinte ET par la
            // graisse : la couleur seule laisserait un daltonien sans repère.
            Text(Self.abreviation(de: jour))
                .font(aujourdhui ? .caption2.weight(.semibold) : .caption2)
                .foregroundStyle(aujourdhui ? Color.primary : Color.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    /// VoiceOver ne voit rien d'un graphique : chaque jour est énoncé avec sa
    /// durée, et « rien » plutôt que « zéro » pour une journée creuse.
    private func enonce(_ jours: [(day: Date, seconds: TimeInterval)]) -> String {
        jours.map { jour in
            let nom = Calendar.current.isDateInToday(jour.day)
                ? "aujourd'hui"
                : Self.nomDuJour.string(from: jour.day)
            return "\(nom) \(jour.seconds > 0 ? Fmt.duration(jour.seconds) : "rien")"
        }
        .joined(separator: ", ")
    }

    /// Abréviations sur trois lettres, PAS les initiales.
    ///
    /// `veryShortWeekdaySymbols` rend « D L M M J V S » en français : mardi et
    /// mercredi portent la même lettre. Marquer le jour courant ne suffit pas —
    /// il ne lève l'ambiguïté que les mardis et les mercredis, et le reste de la
    /// semaine deux colonnes « M » restent indiscernables, sur un graphique qui
    /// sert justement à désigner un jour. `shortWeekdaySymbols` donne
    /// « lun. mar. mer. » ; le point tombe, la place ne manque pas (44 pt par
    /// colonne pour 312 pt utiles).
    ///
    /// Les symboles sont toujours rangés à partir du dimanche, donc indexés par
    /// `weekday - 1`, quel que soit le premier jour de semaine de l'utilisateur.
    /// Locale forcée en français comme le reste de l'interface : les symboles du
    /// système donneraient « Mon Tue Wed » sur une machine en anglais.
    private static let abreviations: [String] = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        let symboles: [String]? = f.shortWeekdaySymbols
        return (symboles ?? []).map { $0.replacingOccurrences(of: ".", with: "") }
    }()

    private static func abreviation(de jour: Date) -> String {
        let index = Calendar.current.component(.weekday, from: jour) - 1
        guard abreviations.indices.contains(index) else { return "·" }
        return abreviations[index]
    }

    private static let nomDuJour: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.setLocalizedDateFormatFromTemplate("EEEE")
        return f
    }()
}

/// Les incidents journée par journée, sur les 14 jours que relève le sampler.
///
/// La section au-dessus donne le total par nature. Ce qu'un total ne peut pas
/// dire, c'est si huit incidents sont huit journées gâchées ou une seule
/// après-midi — et c'est la seule forme qui change quelque chose au montage :
/// quand ça se groupe, il y a une cause commune à chercher ce jour-là, un
/// projet, un rush, une mise à jour. Le compte global la masque par
/// construction.
struct IncidentsPanel: View {
    @ObservedObject var sampler: Sampler

    /// Une colonne : la journée, ce qu'on y a compté, et la nature qui domine.
    private struct Jour: Identifiable {
        var debut: Date
        var total: Int
        var dominante: IncidentKind?
        var id: Date { debut }
    }

    /// 14 et pas davantage : `Sampler` ne cherche les incidents que sur 14
    /// jours glissants. Des colonnes au-delà seraient vides par construction
    /// et se liraient comme des journées calmes.
    private let fenetre = 14

    /// 44 pt : la rangée de cœurs en fait 22 et se lit très bien ; ici on
    /// compare quatorze colonnes entre elles, il faut le double pour que la
    /// différence entre deux et cinq incidents se voie.
    private let hauteurMax: CGFloat = 44

    /// Le cadre ne se cale pas sur le pic quand le pic est bas : sans ce
    /// plancher, l'unique plantage d'une quinzaine calme se dessine exactement
    /// comme la pire journée du mois — pleine hauteur, cadre saturé. Il faut
    /// quatre incidents dans la même journée pour remplir le cadre.
    private let echelleMin = 4

    var body: some View {
        // Calculé UNE fois et passé aux sous-vues : `jours` regroupe tous les
        // incidents de la quinzaine, et le panneau se réévalue à chaque relevé
        // du sampler, toutes les 1,5 s.
        let jours = self.jours
        let pic = jours.map(\.total).max() ?? 0
        let touchees = jours.filter { $0.total > 0 }.count

        VStack(alignment: .leading, spacing: 5) {
            SectionLabel(title: "incidents par journée",
                         trailing: pic > 0 ? "\(touchees) \(accord("journée", touchees)) sur \(fenetre)" : nil)

            if pic == 0 {
                // Branche défensive : la section se masque quand la liste est
                // vide, donc on n'arrive ici qu'à la marge — un incident daté
                // de la journée partielle qui précède la fenêtre. Mieux vaut
                // une ligne sobre qu'un cadre de colonnes plates.
                note("aucun incident sur les \(fenetre) dernières journées")
            } else {
                barres(jours, pic: pic)
                pied(jours)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Un graphique muet n'existe pas pour VoiceOver : le libellé énonce la
        // répartition que les colonnes donnent à l'œil.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(jours))
    }

    // MARK: - Colonnes

    private func barres(_ jours: [Jour], pic: Int) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(jours) { jour in
                // La hauteur dépend du pic autant que du total : animer sur le
                // seul total laisserait toutes les autres colonnes sauter le
                // jour où le pic change d'échelle.
                let hauteur = hauteur(jour.total, pic: pic)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(teinte(jour.dominante))
                    .frame(height: hauteur)
                    .frame(maxWidth: .infinity)
                    .animation(Motion.value, value: hauteur)
            }
        }
        .frame(height: hauteurMax, alignment: .bottom)
        // La ligne de base, comme sous la courbe mémoire. Sans elle, une
        // journée sans incident ne se distingue pas d'une colonne manquante :
        // le vide doit se voir autant que le plein, c'est la moitié du propos.
        .background(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
    }

    /// Plancher à 4 pt sur les journées non nulles : face à un pic à douze, un
    /// incident isolé mesurerait 3,7 pt et se confondrait avec la ligne de
    /// base. La présence prime sur la proportion exacte — le décompte chiffré
    /// est juste au-dessus, dans la section.
    private func hauteur(_ total: Int, pic: Int) -> CGFloat {
        guard total > 0, pic > 0 else { return 0 }
        return max(4, hauteurMax * CGFloat(total) / CGFloat(max(pic, echelleMin)))
    }

    /// Deux teintes et non trois, alors que `IncidentKind` en compte trois.
    ///
    /// Ce panneau répond « quand », la section au-dessus répond déjà « quoi »,
    /// ligne par ligne et par nature exacte. Et du siège du monteur, un
    /// processus tué par macOS et un plantage font la même chose : Premiere
    /// disparaît. Les distinguer par la couleur ici ferait porter à la teinte
    /// une nuance que la journée, elle, ne porte pas.
    ///
    /// Journée sans incident : `Palette.muted`, jamais peinte — sa colonne
    /// mesure zéro. Aucune couleur hors palette n'entre ici, pas même une
    /// transparente : la règle ne souffre pas d'exception commode.
    private func teinte(_ kind: IncidentKind?) -> Color {
        switch kind {
        case .crash, .jetsam: return Palette.alert
        case nil: return Palette.muted
        }
    }

    // MARK: - Repères

    /// Les deux bornes de l'axe, puis la légende des teintes — une seule
    /// ligne. Sans la date de gauche, quatorze colonnes ne disent pas où elles
    /// commencent ; sans la pastille, le rouge ne dit rien.
    ///
    /// 312 pt de large en tout. Les deux légendes réunies peuvent friser cette
    /// largeur : `fixedSize` les protège, et c'est la date qui s'élide — elle
    /// se déduit du reste, la légende non.
    private func pied(_ jours: [Jour]) -> some View {
        HStack(spacing: 8) {
            Text(jours.first.map { "\(Self.jourCourt.string(from: $0.debut)) → aujourd'hui" } ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if jours.contains(where: { $0.dominante == .crash || $0.dominante == .jetsam }) {
                LegendDot(color: Palette.alert,
                          label: jours.contains { $0.dominante == .jetsam } ? "plantage ou arrêt"
                                                                           : "plantage")
                    .fixedSize()
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Données

    /// Quatorze journées pleines qui finissent aujourd'hui.
    ///
    /// La source, elle, remonte à 14 × 24 h : elle déborde donc sur une
    /// quinzième journée, partielle. Ces quelques incidents-là ne sont pas
    /// dessinés, et c'est voulu — une colonne qui ne couvre qu'une demi-
    /// journée se lirait comme une journée calme. Tout ce que le panneau
    /// annonce porte donc sur les journées effectivement tracées.
    private var jours: [Jour] {
        let calendrier = Calendar.current
        let aujourdhui = calendrier.startOfDay(for: Date())
        let paquets = Dictionary(grouping: sampler.incidents) {
            calendrier.startOfDay(for: $0.date)
        }
        // Reculer par `date(byAdding:)`, jamais par multiples de 86 400 s : au
        // changement d'heure la soustraction dérive d'une heure et range les
        // incidents de la nuit dans la colonne de la veille.
        return (0..<fenetre).reversed().compactMap { recul in
            guard let debut = calendrier.date(byAdding: .day, value: -recul, to: aujourdhui)
            else { return nil }
            let duJour = paquets[debut] ?? []
            return Jour(debut: debut, total: duJour.count, dominante: dominante(duJour))
        }
    }

    /// La nature la plus fréquente de la journée ; à égalité, la plus grave.
    /// Elle ne choisit plus de teinte — plantage et arrêt partagent la même —
    /// mais le mot de la légende.
    private func dominante(_ incidents: [Incident]) -> IncidentKind? {
        var comptes: [IncidentKind: Int] = [:]
        for incident in incidents { comptes[incident.kind, default: 0] += 1 }
        return comptes.max { ($0.value, gravite($0.key)) < ($1.value, gravite($1.key)) }?.key
    }

    private func gravite(_ kind: IncidentKind) -> Int {
        switch kind {
        case .crash: return 2
        case .jetsam: return 1
        }
    }

    private func spoken(_ jours: [Jour]) -> String {
        let total = jours.reduce(0) { $0 + $1.total }
        guard total > 0 else {
            return "incidents par journée : aucun sur les \(fenetre) dernières journées"
        }
        let touchees = jours.filter { $0.total > 0 }.count
        var phrase = "incidents par journée sur \(fenetre) jours : "
            + "\(total) \(accord("incident", total)) "
            + "sur \(touchees) \(accord("journée", touchees))"
        if let pire = plusChargee(jours), pire.total > 1 {
            phrase += ", la plus chargée le \(Self.jourLong.string(from: pire.debut)) "
                + "avec \(pire.total) \(accord("incident", pire.total))"
            if let dominante = pire.dominante { phrase += ", surtout \(dominante.label)" }
        }
        return phrase
    }

    /// La journée la plus chargée, et à égalité la plus RÉCENTE — celle qui
    /// intéresse encore.
    ///
    /// Écrit à la main, pas avec `max(by:)` : à égalité, `max(by:)` garde le
    /// premier élément rencontré (vérifié), donc la journée la plus ANCIENNE,
    /// `jours` allant du plus vieux au plus récent. Le `>=` inverse ce choix.
    private func plusChargee(_ jours: [Jour]) -> Jour? {
        jours.reduce(into: nil as Jour?) { pire, jour in
            if jour.total >= (pire?.total ?? 0) { pire = jour }
        }
    }

    private func accord(_ singulier: String, _ compte: Int) -> String {
        compte > 1 ? singulier + "s" : singulier
    }

    /// Formateurs statiques : en reconstruire un à chaque rendu coûterait plus
    /// cher que tout le reste du panneau réuni.
    ///
    /// Locale forcée en français, comme le reste de l'interface. Laissée à
    /// `Locale.current`, la date suivrait la langue du système : « Sep 8 » au
    /// milieu d'une phrase française sur une machine réglée en anglais.
    private static let jourCourt = formatteur("dMMM")
    private static let jourLong = formatteur("dMMMM")

    private static func formatteur(_ gabarit: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.setLocalizedDateFormatFromTemplate(gabarit)
        return f
    }
}

/// Tracé d'une série sur une grille COMMUNE à plusieurs lignes.
///
/// `LineSeries` étale son tableau sur toute la largeur : deux volumes aux
/// historiques inégaux y occuperaient la même largeur, et le disque branché
/// hier se lirait comme s'il avait trente jours de mesures. Ici les valeurs
/// sont posées sur les slots `from`…`from + values.count - 1` d'une grille de
/// `slots` pas, et rien n'est dessiné en dehors : le vide à gauche est
/// l'information « ce volume n'était pas monté ».
private struct TraceShape: Shape {
    var values: [Double]      // 0…1
    var from: Int
    var slots: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard slots > 1, values.count > 1 else { return path }
        let step = rect.width / CGFloat(slots - 1)
        for (offset, value) in values.enumerated() {
            let clamped = min(1, max(0, value))
            let point = CGPoint(x: rect.minX + CGFloat(from + offset) * step,
                                y: rect.maxY - CGFloat(clamped) * rect.height)
            if offset == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// Panneau « volumes » : l'espace libre de chaque volume sur la fenêtre
/// réellement observée, une ligne par volume, toutes sur le MÊME axe de temps.
struct VolumesPanel: View {
    @ObservedObject var sampler: Sampler

    /// Pas de la grille commune. 48 sur les ~158 pt de tracé disponibles :
    /// au-delà, deux échantillons tombent dans le même pixel.
    private static let slots = 48

    /// Plancher d'observation, le même que celui de la prévision
    /// (`HistoryStore.minObservation`) : en dessous il n'y a pas de tendance
    /// à montrer.
    private static let minimumSpan: TimeInterval = 6 * 3600

    /// Série prête à dessiner, plus les bornes nécessaires pour l'énoncer.
    private struct Trace {
        var values: [Double]      // 0…1, du plus ancien au plus récent
        var from: Int             // premier slot couvert sur la grille commune
        var oldest: Double        // octets libres au premier slot couvert
        var newest: Double        // octets libres au dernier slot couvert
        var span: TimeInterval    // durée effectivement tracée pour CE volume
        var amplitude: Double     // hauteur d'échelle retenue, en octets
        var strict: Bool          // série bâtie hors purgeable
    }

    private struct Row: Identifiable {
        var volume: VolumeSample
        var trace: Trace?
        var id: String { volume.id }
    }

    /// Ce que le panneau a calculé pour CE rendu : les lignes, la fenêtre
    /// commune, et les volumes laissés de côté. Un seul passage sur
    /// l'historique, partagé entre le tracé, la ligne de repère et VoiceOver —
    /// relire trente jours de points trois fois par volume, à chaque relevé,
    /// coûterait le triple pour le même dessin.
    private struct Plot {
        var rows: [Row] = []
        var window: TimeInterval = 0
        var hidden: Int = 0
        var anyTrace: Bool { rows.contains { $0.trace != nil } }
    }

    var body: some View {
        let plot = build()
        return VStack(alignment: .leading, spacing: 5) {
            if plot.rows.isEmpty {
                note("aucun volume monté")
            } else if !plot.anyTrace {
                note("pas encore de tendance — la courbe se lit après six heures de relevés")
            } else {
                ForEach(plot.rows) { row in
                    line(row, height: curveHeight(plot.rows.count))
                }
                footer(plot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("espace libre par volume")
        .accessibilityValue(spokenAll(plot))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Lignes

    /// La courbe se resserre quand les volumes s'accumulent : c'est la hauteur
    /// du panneau qu'on tient, pas celle d'une ligne.
    private func curveHeight(_ count: Int) -> CGFloat {
        count <= 2 ? 30 : (count == 3 ? 24 : 18)
    }

    private func line(_ row: Row, height: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(row.volume.name)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 80, alignment: .leading)

            ZStack {
                if let trace = row.trace {
                    // Trait seul, sans aire remplie : l'échelle verticale est
                    // zoomée sur la variation et ne part pas de zéro. Une aire
                    // sous la courbe se lirait comme une quantité, et cette
                    // quantité serait fausse.
                    TraceShape(values: trace.values, from: trace.from, slots: Self.slots)
                        .stroke(tint(row.volume),
                                style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                } else {
                    Text("relevés en cours")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
            }

            Text(delta(row))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .trailing)
        }
    }

    private func footer(_ plot: Plot) -> some View {
        HStack(spacing: 4) {
            Text(plot.rows.contains { $0.trace?.strict == false }
                 ? "purgeable compris" : "hors purgeable")
            Spacer()
            if plot.hidden > 0 {
                Text(plot.hidden > 1 ? "+ \(plot.hidden) volumes" : "+ 1 volume")
            }
            Text(Fmt.days(plot.window / 86_400))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// Même règle que la ligne repliée au-dessus : rouge à partir de 90 %
    /// d'occupation. Deux états seulement — une troisième teinte demanderait
    /// une légende que ce panneau n'a pas la place de porter.
    private func tint(_ volume: VolumeSample) -> Color {
        volume.usedFraction > 0.9 ? Palette.alert : Palette.data
    }

    /// La VARIATION sur la fenêtre, et non l'espace libre du dernier point.
    ///
    /// La ligne repliée juste au-dessus affiche déjà « N Go libres », sur
    /// `available` — purgeable COMPRIS, relevé il y a moins de trente
    /// secondes. Le dernier point d'historique, lui, est hors purgeable et
    /// vieux de dix minutes au plus. Les deux chiffres côte à côte se
    /// contrediraient de plusieurs dizaines de Go sur le disque de démarrage
    /// sans que rien n'ait été écrit — le piège que `HistoryStore.forecast`
    /// documente déjà. La variation est ce que la courbe montre, et elle ne
    /// concurrence aucun autre chiffre de la fenêtre.
    private func delta(_ row: Row) -> String {
        guard let trace = row.trace else { return "—" }
        let change = trace.newest - trace.oldest
        guard abs(change) >= noise(trace) else { return "stable" }
        return (change < 0 ? "\u{2212}" : "+") + Fmt.bytes(abs(change))
    }

    /// Seuil de bruit indexé sur l'échelle RÉELLEMENT tracée, pas sur la
    /// capacité. Un pour cent d'un disque de 8 To vaut 80 Go : un disque de
    /// rushes qui se remplit de 3 Go par jour pendant un mois serait annoncé
    /// « stable » pendant que la courbe traverse le cadre de haut en bas. Le
    /// sens énoncé doit être celui qu'on voit.
    private func noise(_ trace: Trace) -> Double {
        max(trace.amplitude * 0.05, 100_000_000)
    }

    // MARK: - Séries

    private func build() -> Plot {
        let volumes = sampler.volumes
        guard !volumes.isEmpty else { return Plot() }

        // Quatre volumes au plus : au-delà, un dépliant ferait la hauteur
        // d'une page. La liste est triée disque de démarrage d'abord, donc la
        // coupe tombe sur les montages de passage, pas sur le disque de rushes.
        let shown = Array(volumes.prefix(4))
        let hidden = volumes.count - shown.count

        // Historique lu UNE fois par volume et par rendu.
        var series: [(volume: VolumeSample, points: [DiskPoint], strict: Bool)] = []
        for volume in shown {
            let raw = sampler.volumeHistory(for: volume.historyKey, days: 30)
            // Une seule grandeur par courbe, jamais les deux mélangées.
            //
            // `freeStrict` est un champ ajouté après coup : les points anciens
            // ne le portent pas. `HistoryStore.forecast` compare strict à
            // strict OU libre à libre et refuse le mélange, parce que l'écart
            // entre les deux atteint des dizaines de Go sur le disque de
            // démarrage. Un `freeStrict ?? free` appliqué point par point
            // rouvrirait exactement cette faille : une falaise au jour où le
            // champ est apparu, que personne n'a écrite. On garde donc une
            // seule des deux grandeurs pour toute la courbe.
            let strict = raw.last?.freeStrict != nil
            let points = strict ? raw.filter { $0.freeStrict != nil } : raw
            series.append((volume, points, strict))
        }

        // Fenêtre COMMUNE à toutes les lignes.
        //
        // Sans elle, chaque courbe s'étalait sur son propre intervalle : un
        // disque monté hier et le disque de démarrage occupaient la même
        // largeur sous une seule légende. Empilées, deux lignes se comparent —
        // il faut donc que l'axe horizontal dise la même chose sur chacune.
        let eligible = series.filter { $0.points.count >= 4 }
        guard let start = eligible.compactMap({ $0.points.first?.t }).min(),
              let end = eligible.compactMap({ $0.points.last?.t }).max(),
              end - start >= Self.minimumSpan
        else {
            return Plot(rows: shown.map { Row(volume: $0, trace: nil) },
                        window: 0, hidden: hidden)
        }

        let rows = series.map { Row(volume: $0.volume, trace: trace($0, start: start, end: end)) }
        return Plot(rows: rows, window: end - start, hidden: hidden)
    }

    private func trace(_ entry: (volume: VolumeSample, points: [DiskPoint], strict: Bool),
                       start: Double, end: Double) -> Trace? {
        let points = entry.points
        // Quatre points et six heures au moins pour CE volume. Un disque
        // externe remonté après trois semaines a bien deux points séparés de
        // trois semaines — ils dessineraient une falaise, qui ne serait que la
        // durée du démontage.
        guard points.count >= 4, let first = points.first, let last = points.last else { return nil }
        guard last.t - first.t >= Self.minimumSpan else { return nil }

        let window = end - start
        guard window > 0, Self.slots > 1 else { return nil }
        let step = window / Double(Self.slots - 1)
        guard step > 0 else { return nil }

        func free(_ point: DiskPoint) -> Double {
            entry.strict ? (point.freeStrict ?? point.free) : point.free
        }

        // Slots de la grille commune réellement couverts par ce volume. Hors
        // de sa propre plage on ne dessine rien, et on n'extrapole jamais :
        // `ceil` à gauche, `floor` à droite, donc tout point interpolé tombe
        // entre deux mesures existantes.
        let from = max(0, min(Self.slots - 1, Int(((first.t - start) / step).rounded(.up))))
        let to = max(0, min(Self.slots - 1, Int(((last.t - start) / step).rounded(.down))))
        // Moins de deux pas sur la grille commune : il n'y a pas de trait à
        // tirer, seulement un point. La ligne dira « relevés en cours », ce
        // qui est exact — ce volume n'a rien d'observable à cette échelle.
        guard to > from else { return nil }

        // Rééchantillonnage sur une grille de TEMPS régulière, et non un point
        // sur N : les relevés s'arrêtent avec la machine, et un axe indexé sur
        // les échantillons collerait une semaine de travail contre trois
        // semaines d'arrêt.
        //
        // Les trous sont INTERPOLÉS, jamais comblés par la dernière valeur
        // connue. Sur cette machine, trois semaines sans relevé encadrées par
        // 168 Go et 51 Go donnaient, en valeur reportée, un plateau puis une
        // falaise le dernier jour : le mois de remplissage se lisait comme
        // « 117 Go perdus aujourd'hui ». Relier deux mesures par un segment
        // droit est ce que fait n'importe quelle courbe, et n'invente rien de
        // plus que ce que les deux mesures disent.
        var sampled: [Double] = []
        sampled.reserveCapacity(to - from + 1)
        var index = 0
        for slot in from...to {
            let t = start + step * Double(slot)
            while index + 1 < points.count, points[index + 1].t <= t { index += 1 }
            let before = points[index]
            let after = index + 1 < points.count ? points[index + 1] : before
            let gap = after.t - before.t
            let ratio = gap > 0 ? min(1, max(0, (t - before.t) / gap)) : 0
            sampled.append(free(before) + (free(after) - free(before)) * ratio)
        }
        guard let low = sampled.min(), let high = sampled.max(),
              let oldest = sampled.first, let newest = sampled.last else { return nil }

        // Plancher d'échelle à 2 % de la capacité : sans lui, les quelques Mo
        // de respiration d'un disque stable seraient étirés sur toute la
        // hauteur et se liraient comme un effondrement.
        let amplitude = max(high - low, Double(entry.volume.total) * 0.02, 1)
        let base = (high + low) / 2 - amplitude / 2
        // 8 % de marge en haut et en bas : une courbe collée au bord du cadre
        // suggère un maximum ou un plancher qui n'existent pas.
        let values = sampled.map { ($0 - base) / amplitude * 0.84 + 0.08 }
        return Trace(values: values,
                     from: from,
                     oldest: oldest,
                     newest: newest,
                     span: step * Double(to - from),
                     amplitude: amplitude,
                     strict: entry.strict)
    }

    // MARK: - Énoncé

    private func spokenAll(_ plot: Plot) -> String {
        guard !plot.rows.isEmpty else { return "aucun volume monté" }
        var parts = plot.rows.map(spoken)
        if plot.hidden > 0 {
            parts.append(plot.hidden > 1 ? "\(plot.hidden) autres volumes non tracés"
                                         : "un autre volume non tracé")
        }
        return parts.joined(separator: ". ")
    }

    /// Un graphique muet ne dit rien à VoiceOver : la phrase porte le sens du
    /// dessin — d'où on part, où on en est, dans quel sens ça va.
    private func spoken(_ row: Row) -> String {
        guard let trace = row.trace else {
            return "\(row.volume.name), pas encore de tendance lisible"
        }
        let change = trace.newest - trace.oldest
        let floor = noise(trace)
        let direction: String
        if change < -floor { direction = "se remplit" }
        else if change > floor { direction = "se vide" }
        else { direction = "stable" }
        return "\(row.volume.name), \(direction), "
            + "\(Fmt.bytes(trace.oldest)) libres \(ago(trace.span)), "
            + "\(Fmt.bytes(trace.newest)) au dernier relevé tracé"
    }

    /// « il y a six heures », pas « il y a un jour » : la fenêtre s'ouvre à six
    /// heures, et l'arrondi en jours annoncerait une journée d'historique là
    /// où il y en a un quart.
    private func ago(_ span: TimeInterval) -> String {
        let days = span / 86_400
        if days < 1 { return "il y a \(Int((span / 3600).rounded())) h" }
        let count = Int(days.rounded())
        return count <= 1 ? "il y a un jour" : "il y a \(count) jours"
    }
}
