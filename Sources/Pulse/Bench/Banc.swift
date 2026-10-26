import AppKit
import SwiftUI
import Combine
import Darwin

/// `--banc <secondes>` : ce que coûte Pulse, mesuré sur lui-même.
///
/// Le vrai `Sampler`, sans barre de menus ni popover, écriture COUPÉE
/// (`Persistence`, comme `--snapshot`) : rien ne s'ouvre, rien ne s'écrit —
/// les deux sont vérifiés à la fin, pas supposés. Trois phases :
/// - **fermé** : la cadence de tous les jours, panneau jamais ouvert, et le
///   libellé de barre de menus refait comme dans l'app ;
/// - **ouvert** : la cadence de 1,5 s et le contenu du panneau créé comme à
///   l'ouverture (`AppDelegate.makeContent`), hors écran ;
/// - **refermé** : le contenu libéré. Doit retomber au niveau de « fermé » :
///   le 09/10, un panneau refermé coûtait 8,2 % d'un cœur, contre 2,1 % s'il
///   n'avait jamais été ouvert (README).
///
/// Panneau fermé, le banc tourne sur les cœurs d'efficacité, comme l'app
/// (`surCoeursEfficaces`) ; et les tâches lentes du relevé — disques et
/// incidents toutes les 2 min, prévision, identités et écritures toutes les
/// minutes — sont mesurées chacune dans une fenêtre d'un relevé, puis
/// réparties sur leur période (`Sampler.TachesLentes`). Sans ces deux
/// corrections, le banc donnait 0,35 % quand le Pulse installé en dépensait
/// 0,8 (15-audit-perf, 11/10).
///
/// Le temps CPU est le temps cumulé du processus (`getrusage`), pas un
/// échantillon à la `top` : sur 30 s, le même Pulse a donné 5,6 % ou 8,2 %
/// selon le moment. Chaque fenêtre de mesure couvre un nombre entier de
/// relevés et démarre entre deux : un relevé de plus ou de moins pèserait un
/// quart d'une fenêtre de 20 s.
///
/// `--ecrit` garde la persistance active, comme dans l'app : l'historique
/// (`history.json`, la base SQLite, les journaux) s'écrit, et ça se paie.
/// Permis seulement dans un dossier personnel de rechange (voir
/// `maisonDeRechange`), ce que fait `./verifie.sh` : jamais sur les vraies
/// données d'Isma.
@MainActor
enum Banc {
    /// Les compteurs du processus à un instant.
    struct Compteurs {
        /// Horloge monotone, en secondes.
        var horloge: Double
        /// Temps CPU cumulé, utilisateur et système, en secondes.
        var cpu: Double
        /// Réveils d'un fil par une interruption, minuteries comprises :
        /// vérifié, 200 sommeils de 20 ms en donnent exactement 200. Les
        /// réveils « au repos » du noyau (`ri_pkg_idle_wkups`) restent à zéro
        /// sur Apple Silicon : inutilisables ici.
        var reveils: UInt64
        /// Énergie attribuée au processus par le noyau, en nanojoules.
        var energie: UInt64
        /// Mémoire, telle que l'affiche le Moniteur d'activité.
        var empreinte: UInt64
        /// Dont temps CPU sur les cœurs de performance, en secondes
        /// (`ri_user_ptime`, `ri_system_ptime`) : le reste est passé sur les
        /// cœurs d'efficacité, où le même travail coûte deux fois plus.
        var cpuP: Double = 0
        /// Lancement du processus, en temps mach absolu
        /// (`ri_proc_start_abstime`) : son âge écarte un Pulse installé qui
        /// démarre encore.
        var lancement: UInt64 = 0

        /// Les compteurs de ce processus.
        static func lire() -> Compteurs {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let secondes = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            let micro = Double(Int(usage.ru_utime.tv_usec) + Int(usage.ru_stime.tv_usec))
            var compteurs = lire(pid: getpid()) ?? Compteurs(horloge: 0, cpu: 0, reveils: 0, energie: 0, empreinte: 0)
            compteurs.cpu = secondes + micro / 1e6
            return compteurs
        }

        /// Les compteurs d'un autre processus du même utilisateur — le Pulse
        /// installé, mesuré pendant le banc. Les temps de `rusage_info` sont
        /// en unités mach, pas en nanosecondes : 125/3 ns l'unité sur ce M2
        /// Max (piège du README, le même que `pti_total_user`).
        static func lire(pid: pid_t) -> Compteurs? {
            var info = rusage_info_v6()
            let lu = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            } == 0
            guard lu else { return nil }
            let mach = Double(info.ri_user_time &+ info.ri_system_time)
            let machP = Double(info.ri_user_ptime &+ info.ri_system_ptime)
            return Compteurs(horloge: Double(DispatchTime.now().uptimeNanoseconds) / 1e9,
                             cpu: mach * Self.nanosecondesParUnite / 1e9,
                             reveils: info.ri_interrupt_wkups,
                             energie: info.ri_energy_nj,
                             empreinte: info.ri_phys_footprint,
                             cpuP: machP * Self.nanosecondesParUnite / 1e9,
                             lancement: info.ri_proc_start_abstime)
        }

        /// Depuis combien de secondes le processus tourne.
        var age: Double {
            Double(mach_absolute_time() &- lancement) * Self.nanosecondesParUnite / 1e9
        }

        private static let nanosecondesParUnite: Double = {
            var base = mach_timebase_info_data_t()
            mach_timebase_info(&base)
            return Double(base.numer) / Double(base.denom)
        }()
    }

    /// Ce que l'icône de barre de menus coûte en plus, panneau fermé, et que
    /// le banc ne peut pas mesurer : elle ne peut pas apparaître pendant un
    /// banc. Le libellé, lui, est bien refait (`LibelleDeBarre`) ; manque son
    /// affichage par AppKit, une trentaine de fois par minute puisque le débit
    /// change sans cesse.
    ///
    /// 0,45 point jusqu'au 11/10 à 06 h, calé sur l'écart avec le Pulse
    /// installé — mais cet écart venait surtout des cœurs : le banc tournait
    /// sur les cœurs P, l'app sur les cœurs E, où le même travail coûte deux
    /// fois plus (voir `surCoeursEfficaces`). Phases fermées sur les cœurs E,
    /// l'écart tombe à 0,07 point. Au profileur (`sample` sur le Pulse
    /// installé, 120 s), ce que l'app fait et que le banc ne fait pas : le
    /// dessin du bouton dans la transaction Core Animation (76 échantillons
    /// de 1,3 ms), la largeur figée (`fixLengthOnce`, 24), image, infobulle
    /// et libellé VoiceOver posés (~20) — 0,13 % d'un cœur. Puis la barre du
    /// chantier 09 (dessin AppKit, deux fois moins d'affichages) : aux mêmes
    /// secondes, même code des deux côtés, Pulse installé 0,34 % contre
    /// 0,27 % au banc ; sur 4 min, 0,43 % contre 0,36 % tâches lentes
    /// comprises. 0,07 point d'écart, 0,08 retenu. À remesurer si la barre
    /// de menus change.
    static let icone = 0.0008

    /// Panneau fermé, le Pulse installé tourne sur les cœurs d'efficacité :
    /// 97 % de son temps CPU, à 2,4 GHz, environ une instruction par cycle
    /// (relevé le 11/10, `ri_user_ptime`). Le banc, lancé d'un terminal,
    /// tourne dans le groupe de fils de son parent — occupé — et passait 84 à
    /// 99 % de son temps sur les cœurs de performance, à 3,2 GHz et 1,4
    /// instruction par cycle : le même travail (6,9 milliards d'instructions
    /// pour un banc entier, au même compte près) y coûtait 1,1 s de CPU contre
    /// 2,2 s sur les cœurs E. C'était l'essentiel de l'écart entre le banc
    /// et l'app. Les phases fermées tournent donc en arrière-plan Darwin
    /// (`PRIO_DARWIN_BG`), sur les cœurs E comme l'app ; l'ouverture, au
    /// premier plan, comme quand Isma regarde le panneau.
    static func surCoeursEfficaces(_ oui: Bool) {
        setpriority(PRIO_DARWIN_PROCESS, 0, oui ? PRIO_DARWIN_BG : 0)
    }

    /// Un Pulse installé lancé depuis moins longtemps démarre encore : relire
    /// l'historique, s'abonner aux capteurs, premier balayage de tout — 0,2 à
    /// 0,3 s de CPU dans sa première minute (relevé le 11/10 sur cinq
    /// relances). Chaque fusion le relance : mesuré trop tôt, il paraît plus
    /// cher qu'il n'est.
    static let ageMinimalDuTemoin: Double = 120

    /// Le Pulse installé, s'il tourne : mesuré pendant les mêmes secondes, il
    /// dit ce que le banc ne voit pas — l'icône dans la barre de menus.
    static func pulseInstalle() -> pid_t? {
        let mine = getpid()
        return NSRunningApplication.runningApplications(withBundleIdentifier: "com.isma.pulse")
            .map(\.processIdentifier).first { $0 != mine }
    }

    /// Une fenêtre de mesure.
    struct Phase {
        var nom: String
        var debut: Compteurs
        var fin: Compteurs
        /// Occupation de toute la machine pendant la phase, tous cœurs : un
        /// banc lancé pendant un export se lit autrement.
        var machine: Double
        /// Le Pulse installé pendant la même phase, s'il tournait du début à
        /// la fin (un redémarrage entre-temps rendrait l'écart absurde) et
        /// depuis assez longtemps (`ageMinimalDuTemoin`).
        var temoin: (debut: Compteurs, fin: Compteurs)?
        /// Âge du Pulse installé au début de la phase, en secondes.
        var temoinAge: Double?

        var temoinCoeur: Double? {
            guard let temoin, duree > 0, temoin.fin.cpu >= temoin.debut.cpu else { return nil }
            return (temoin.fin.cpu - temoin.debut.cpu) / duree
        }

        var duree: Double { fin.horloge - debut.horloge }
        /// En part d'UN cœur, comme le budget.
        var coeur: Double { duree > 0 ? (fin.cpu - debut.cpu) / duree : 0 }
        /// Temps CPU de la phase, en secondes.
        var cpu: Double { fin.cpu - debut.cpu }
        /// Part du temps CPU passée sur les cœurs de performance.
        var partP: Double { cpu > 0 ? min(1, max(0, (fin.cpuP - debut.cpuP) / cpu)) : 0 }
        var reveilsParSeconde: Double { duree > 0 ? Double(fin.reveils &- debut.reveils) / duree : 0 }
        var milliwatts: Double { duree > 0 ? Double(fin.energie &- debut.energie) / duree / 1e6 : 0 }
    }

    static func run(seconds total: Double, ecrit: Bool = false) {
        let maison = maisonDeRechange()
        if ecrit, maison == nil {
            FileHandle.standardError.write(Data(("--ecrit exige un dossier personnel de rechange "
                + "(CFFIXED_USER_HOME, comme ./verifie.sh) : il écrirait dans les vraies données.\n").utf8))
            exit(2)
        }
        Persistence.enabled = ecrit
        // Aucune icône dans le Dock, aucune activation : le banc n'a rien à
        // montrer. Posé avant toute fenêtre.
        NSApplication.shared.setActivationPolicy(.prohibited)
        let lancement = Compteurs.lire()

        // La cadence choisie par Isma, comme `AppDelegate.apply` : relevé
        // fermé toutes les 5 s par défaut, jamais moins.
        let cadence = SettingsStore.shared.settings.refresh.sanitized
        let periodeFermee = cadence.closedInterval

        // Durées : la chauffe absorbe le démarrage (historique relu, premier
        // balayage des disques et des incidents), puis des fenêtres multiples
        // de 10 s panneau fermé (relevé toutes les 5 s, débit toutes les 2 s)
        // et de 6 s panneau ouvert (1,5 s et 2 s).
        let chauffe = 5.0
        let reste = max(0, total - chauffe)
        let ferme = max(10, (reste * 0.36 / 10).rounded() * 10)
        let ouvert = max(6, (reste * 0.25 / 6).rounded() * 6)

        // Panneau fermé, sur les cœurs E comme l'app (voir `surCoeursEfficaces`).
        surCoeursEfficaces(true)
        // Hors écran, une animation tournerait sans frein : le coût « ouvert »
        // compterait des images que personne ne voit (`Motion.sansAnimation`).
        Motion.sansAnimation = true
        let sampler = Sampler()
        sampler.setIntervals(open: cadence.openInterval, closed: cadence.closedInterval)
        // Comme au lancement de l'app : chaque module apprend que le panneau
        // est fermé et règle sa cadence.
        AppDelegate.panelDidChange(open: false, sampler: sampler)
        let libelle = LibelleDeBarre(sampler)
        let machine = CPUMonitor()
        pompe(chauffe)
        let demarrage = Compteurs.lire()

        // Fermé, jamais ouvert.
        caleEntreDeuxReleves(sampler, periode: periodeFermee)
        let p1 = mesure("fermé", machine) { pompe(ferme) }

        // Les tâches lentes, une fenêtre d'un relevé chacune : rendues dues,
        // elles tournent au relevé de la fenêtre et nulle part ailleurs — la
        // suivante tomberait une ou deux minutes plus tard, après le banc.
        var lentes: [(taches: Sampler.TachesLentes, phase: Phase)] = []
        for taches in Sampler.TachesLentes.allCases {
            caleEntreDeuxReleves(sampler, periode: periodeFermee)
            sampler.rendDues(taches)
            lentes.append((taches, mesure("lentes", machine) { pompe(periodeFermee) }))
        }

        // Ouvert : le contenu est créé comme à l'ouverture, puis gardé en vie
        // dans une fenêtre qui n'est jamais mise à l'écran. L'ouverture et la
        // fermeture comptent dans la phase : c'est le coût d'un coup d'œil.
        // Au premier plan : Isma regarde le panneau.
        caleEntreDeuxReleves(sampler, periode: periodeFermee)
        surCoeursEfficaces(false)
        var panneau = Panneau()
        let p2 = mesure("ouvert", machine) {
            AppDelegate.panelDidChange(open: true, sampler: sampler)
            let t0 = Compteurs.lire().horloge
            let (hote, taille) = creeContenu(sampler)
            panneau.creation = Compteurs.lire().horloge - t0
            panneau.taille = taille
            let t1 = Compteurs.lire().horloge
            _ = rendPanneau(sampler)
            panneau.rendu = Compteurs.lire().horloge - t1
            let fenetre = fenetreCachee(hote, taille: taille)
            pompe(ouvert / 2)
            // Au moment où le risque existe : une fenêtre porte le panneau.
            panneau.fenetresAffichees = fenetresAffichees()
            pompe(ouvert / 2)
            // Refermé : contenu vidé puis lâché, comme `releaseContent`.
            AppDelegate.panelDidChange(open: false, sampler: sampler)
            hote.rootView = AnyView(EmptyView())
            fenetre.contentViewController = nil
        }
        // Le minuteur repart de zéro à la fermeture : la fenêtre suivante
        // démarre à mi-chemin du premier relevé.
        surCoeursEfficaces(true)
        pompe(periodeFermee / 2)
        let p3 = mesure("refermé", machine) { pompe(ferme) }

        // Hors mesure : la création à chaud, caches de polices et d'icônes
        // déjà remplis — celle que vit l'utilisateur aux ouvertures suivantes.
        surCoeursEfficaces(false)
        let t2 = Compteurs.lire().horloge
        let (chaud, _) = creeContenu(sampler)
        panneau.creationChaud = Compteurs.lire().horloge - t2
        chaud.rootView = AnyView(EmptyView())

        rapport(total: total, lancement: lancement, demarrage: demarrage, phases: [p1, p2, p3],
                lentes: lentes, panneau: panneau, libelles: libelle.rendus, maison: ecrit ? maison : nil)
        withExtendedLifetime(libelle) {}
    }

    /// Le dossier personnel de rechange où tourne le banc, s'il y en a un :
    /// `CFFIXED_USER_HOME` posé, et Application Support redirigé ailleurs que
    /// chez Isma. Toutes les données de Pulse passent par
    /// `FileManager.urls(for: .applicationSupportDirectory)`, qui le suit
    /// (vérifié le 11/10 : `urls`, `NSHomeDirectory` et
    /// `homeDirectoryForCurrentUser` y pointent tous trois).
    static func maisonDeRechange() -> String? {
        guard let fixe = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"], !fixe.isEmpty,
              let compte = getpwuid(getuid()) else { return nil }
        // Liens résolus : un dossier « de rechange » qui serait un lien vers
        // le vrai ne passe pas.
        func reel(_ chemin: String) -> String { URL(fileURLWithPath: chemin).resolvingSymlinksInPath().path }
        let vraie = reel(String(cString: compte.pointee.pw_dir))
        let ici = reel(NSHomeDirectory())
        let donnees = reel(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path)
        // La maison de rechange de ./verifie.sh vit, elle, SOUS le dossier
        // d'Isma (dans .build) : c'est sa Bibliothèque qui est interdite.
        guard ici != vraie, !donnees.hasPrefix(vraie + "/Library/") else { return nil }
        return ici
    }

    /// Ce que l'on sait du panneau après l'avoir créé hors écran.
    struct Panneau {
        var taille = CGSize.zero
        /// Vue, mise en page et taille idéale, à la première ouverture.
        var creation = 0.0
        /// La même chose une fois les caches remplis.
        var creationChaud = 0.0
        /// Le panneau entier dessiné en image.
        var rendu = 0.0
        /// Fenêtres de ce processus à l'écran pendant que le panneau existe.
        var fenetresAffichees = -1
    }

    // MARK: - Mesure

    private static func mesure(_ nom: String, _ machine: CPUMonitor, _ travail: () -> Void) -> Phase {
        _ = machine.sample()
        let installe = pulseInstalle()
        let temoinDebut = installe.flatMap { Compteurs.lire(pid: $0) }
        let debut = Compteurs.lire()
        travail()
        let fin = Compteurs.lire()
        var phase = Phase(nom: nom, debut: debut, fin: fin, machine: machine.sample().total)
        phase.temoinAge = temoinDebut?.age
        if let installe, pulseInstalle() == installe, let temoinDebut,
           temoinDebut.age >= ageMinimalDuTemoin,
           let temoinFin = Compteurs.lire(pid: installe) {
            phase.temoin = (temoinDebut, temoinFin)
        }
        return phase
    }

    /// Fait tourner la boucle principale, où le `Sampler` publie ses relevés.
    ///
    /// D'un seul tenant jusqu'à l'échéance, et non par tranches de 50 ms
    /// comme `--snapshot` : chaque tranche réveillerait le processus, vingt
    /// réveils par seconde qu'on mesurerait ensuite comme ceux de Pulse. Le
    /// minuteur à l'échéance garde une source à la boucle : sans aucune,
    /// `run(mode:before:)` rend la main aussitôt et la boucle tourne à vide.
    private static func pompe(_ secondes: Double) {
        let fin = Date().addingTimeInterval(secondes)
        let veille = Timer(fire: fin, interval: 0, repeats: false) { _ in }
        RunLoop.main.add(veille, forMode: .default)
        while Date() < fin { _ = RunLoop.main.run(mode: .default, before: fin) }
        veille.invalidate()
    }

    /// Attend le prochain relevé, puis une demi-période : la fenêtre qui suit
    /// démarre entre deux relevés, loin des deux bords.
    private static func caleEntreDeuxReleves(_ sampler: Sampler, periode: Double) {
        var vu = false
        let abonnement = sampler.$cpu.dropFirst().sink { _ in vu = true }
        let limite = Date().addingTimeInterval(periode * 2)
        while !vu, Date() < limite { _ = RunLoop.main.run(mode: .default, before: limite) }
        abonnement.cancel()
        pompe(periode / 2)
    }

    // MARK: - Le panneau, hors écran

    /// Les gestes de `AppDelegate.makeContent` et de `togglePopover` avant
    /// l'affichage : la vue, sa mise en page, sa taille idéale.
    private static func creeContenu(_ sampler: Sampler) -> (NSHostingController<AnyView>, CGSize) {
        let host = NSHostingController(rootView: AnyView(PopoverView(sampler: sampler)))
        host.sizingOptions = [.preferredContentSize]
        host.view.layoutSubtreeIfNeeded()
        return (host, host.view.fittingSize)
    }

    /// Le panneau entier rendu en image, comme `--snapshot` : le temps de
    /// dessiner chaque pixel une fois.
    private static func rendPanneau(_ sampler: Sampler) -> CGImage? {
        let renderer = ImageRenderer(content: PopoverView(sampler: sampler)
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        var image: CGImage?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { image = renderer.cgImage }
        return image
    }

    /// Une fenêtre qui porte le contenu sans jamais être mise à l'écran :
    /// ni `orderFront`, ni `makeKey`. Comme dans le popover, le contenu vit
    /// dans une fenêtre et suit le sampler — mesuré : sans elle, 2 réveils par
    /// seconde panneau ouvert ; avec elle, 13,5. Hors de toute fenêtre, la vue
    /// ne se mettait plus à jour et le banc aurait mesuré un panneau figé.
    private static func fenetreCachee(_ host: NSHostingController<AnyView>, taille: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: taille),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        return window
    }

    /// Les fenêtres de ce processus effectivement affichées. Doit valoir 0.
    private static func fenetresAffichees() -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return -1 }
        let pid = Int(getpid())
        return list.filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }.count
    }

    // MARK: - Rapport

    private static func rapport(total: Double, lancement: Compteurs, demarrage: Compteurs, phases: [Phase],
                                lentes: [(taches: Sampler.TachesLentes, phase: Phase)] = [],
                                panneau: Panneau, libelles: Int, maison: String? = nil) {
        func pct(_ fraction: Double) -> String { nombre(fraction * 100, 2) + " %" }
        func col(_ texte: String, _ largeur: Int) -> String {
            texte.padding(toLength: largeur, withPad: " ", startingAt: 0)
        }

        // Le budget porte sur tout le temps panneau fermé, avant ET après une
        // ouverture : c'est l'état ordinaire de l'app, ouverte de temps en temps.
        let fermes = phases.filter { $0.nom != "ouvert" }
        let tempsFerme = fermes.reduce(0) { $0 + $1.duree }
        let courant = tempsFerme > 0 ? fermes.reduce(0) { $0 + ($1.fin.cpu - $1.debut.cpu) } / tempsFerme : 0
        // Chaque tâche lente : sa fenêtre moins ce que coûte une fenêtre
        // ordinaire de même durée, réparti sur sa période.
        let couts = lentes.map { l in
            (taches: l.taches, cpu: max(0, l.phase.cpu - courant * l.phase.duree))
        }
        let reparties = couts.reduce(0) { $0 + $1.cpu / $1.taches.periode }
        let budget = courant + reparties
        let tempsP = fermes.reduce(0) { $0 + $1.partP * $1.cpu }
        let tempsCPU = fermes.reduce(0) { $0 + $1.cpu }
        let partP = tempsCPU > 0 ? tempsP / tempsCPU : 0

        print("BANC · \(Int(total)) s · vrai Sampler, rien à l'écran · " + (maison.map { "écriture ACTIVE, dans la maison de rechange \($0)" } ?? "écriture coupée"))
        print("  démarrage  \(nombre(demarrage.cpu - lancement.cpu, 2)) s de CPU dans les \(Int((demarrage.horloge - lancement.horloge).rounded())) premières secondes")
        print("")
        print("  " + col("phase", 10) + col("durée", 7) + col("CPU, 1 cœur", 13) + col("réveils/s", 11)
              + col("puissance", 11) + col("mémoire", 10) + col("machine", 9) + "Pulse installé")
        for p in phases {
            print("  " + col(p.nom, 10) + col("\(Int(p.duree.rounded())) s", 7) + col(pct(p.coeur), 13)
                  + col(nombre(p.reveilsParSeconde, 1), 11) + col(nombre(p.milliwatts, 1) + " mW", 11)
                  + col(Fmt.memory(p.fin.empreinte), 10) + col(Fmt.percent(p.machine), 9)
                  + (p.temoinCoeur.map(pct) ?? "—"))
        }
        // Le Pulse installé, sur les mêmes secondes panneau fermé : ce qu'il
        // dépense en plus, c'est surtout son icône de barre de menus.
        let temoins = fermes.compactMap { p in p.temoinCoeur.map { ($0, p.duree) } }
        let temoin = temoins.count == fermes.count && tempsFerme > 0
            ? temoins.reduce(0) { $0 + $1.0 * $1.1 } / tempsFerme : nil
        let temoinP: Double? = {
            let paires = fermes.compactMap(\.temoin)
            guard paires.count == fermes.count else { return nil }
            let cpu = paires.reduce(0) { $0 + $1.fin.cpu - $1.debut.cpu }
            let p = paires.reduce(0) { $0 + $1.fin.cpuP - $1.debut.cpuP }
            return cpu > 0 ? min(1, max(0, p / cpu)) : nil
        }()
        let plusJeune = fermes.compactMap(\.temoinAge).min()

        print("")
        print("  budget panneau fermé  \(pct(budget + icone)) d'un cœur estimés : \(pct(courant)) au banc (fermé et refermé, \(Int(tempsFerme.rounded())) s) + \(pct(reparties)) de tâches lentes réparties + \(pct(icone)) pour l'icône de barre — plafond 1 %")
        for c in couts {
            print("  tâches lentes         \(c.taches.nom) : \(ms(c.cpu)) toutes les \(Int(c.taches.periode)) s, soit \(pct(c.cpu / c.taches.periode))")
        }
        print("  cœurs                 fermé, \(Int((partP * 100).rounded())) % du temps CPU sur les cœurs P (arrière-plan Darwin : les cœurs E, comme l'app)")
        if let temoin {
            let p = temoinP.map { ", \(Int(($0 * 100).rounded())) % sur les cœurs P" } ?? ""
            print("  Pulse installé        \(pct(temoin)) sur les mêmes secondes, icône comprise (la version de main\(p))")
        } else if let plusJeune, plusJeune < ageMinimalDuTemoin {
            print("  Pulse installé        non comparé : relancé il y a \(Int(plusJeune)) s, il démarre encore (moins de \(Int(ageMinimalDuTemoin)) s)")
        } else {
            print("  Pulse installé        non mesuré (absent, ou relancé pendant le banc)")
        }
        print("  panneau               \(Int(panneau.taille.width)) × \(Int(panneau.taille.height)) pt, créé en \(ms(panneau.creation)) à froid, \(ms(panneau.creationChaud)) à chaud ; dessiné en entier en \(ms(panneau.rendu))")
        print("  libellé de barre      redessiné \(libelles) fois")
        print("  fenêtres à l'écran    \(panneau.fenetresAffichees), panneau ouvert hors écran")

        // Pour ./verifie.sh : une ligne, des points décimaux.
        let p = Dictionary(uniqueKeysWithValues: phases.map { ($0.nom, $0) })
        let champs: [(String, String)] = [
            ("ecrit", maison == nil ? "0" : "1"),
            ("estime", String(format: "%.5f", budget + icone)),
            ("budget", String(format: "%.5f", budget)),
            ("courant", String(format: "%.5f", courant)),
            ("lentes", String(format: "%.5f", reparties)),
            ("coeurs_p", String(format: "%.2f", partP)),
            ("installe", temoin.map { String(format: "%.5f", $0) } ?? "-"),
            ("installe_age", plusJeune.map { String(format: "%.0f", $0) } ?? "-"),
            ("ferme", String(format: "%.5f", p["fermé"]?.coeur ?? 0)),
            ("ouvert", String(format: "%.5f", p["ouvert"]?.coeur ?? 0)),
            ("referme", String(format: "%.5f", p["refermé"]?.coeur ?? 0)),
            ("memoire", "\(p["refermé"]?.fin.empreinte ?? 0)"),
            ("reveils", String(format: "%.2f", p["refermé"]?.reveilsParSeconde ?? 0)),
            ("creation_ms", String(format: "%.0f", panneau.creation * 1000)),
            ("creation_chaud_ms", String(format: "%.0f", panneau.creationChaud * 1000)),
            ("rendu_ms", String(format: "%.0f", panneau.rendu * 1000)),
            ("hauteur_pt", String(format: "%.0f", panneau.taille.height)),
            ("fenetres", "\(panneau.fenetresAffichees)"),
        ]
        print("mesure " + champs.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
    }

    private static func nombre(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    private static func ms(_ seconds: Double) -> String { "\(Int((seconds * 1000).rounded())) ms" }
}

/// Le libellé de barre de menus, refait comme `MenuBarController.refresh` : au
/// plus une fois par seconde, et seulement quand ce qu'il affiche change.
/// Avec le relevé lui-même, c'est tout le travail de Pulse panneau fermé.
@MainActor
final class LibelleDeBarre {
    private(set) var rendus = 0
    private var dernier = Date.distantPast
    private var affiche: [MenuBarContent] = []
    private let historique = MenuBarHistory()
    private let debit = MenuBarRateFilter()
    private var image: NSImage?
    private var abonnement: AnyCancellable?

    init(_ sampler: Sampler) {
        abonnement = sampler.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak sampler] in
                MainActor.assumeIsolated {
                    guard let self, let sampler else { return }
                    self.rafraichit(sampler)
                }
            }
    }

    private func rafraichit(_ sampler: Sampler) {
        guard Date().timeIntervalSince(dernier) >= MenuBarController.minInterval else { return }
        dernier = Date()
        let contenus = MenuBarComposer.contents(sampler, settings: SettingsStore.shared.settings,
                                                history: historique, rates: debit)
        for (index, contenu) in contenus.enumerated() where index >= affiche.count || affiche[index] != contenu {
            image = MenuBarDrawing.image(contenu, scale: 2)
            rendus += 1
        }
        affiche = contenus
    }
}
