import Foundation

/// Le texte de chaque dépliant, indexé par la clé du contrôle qui le révèle.
///
/// Rédigé contre le code, pas de mémoire. Chaque affirmation a été écrite en
/// lisant la source qui produit le chiffre, puis soumise à un relecteur chargé
/// de la RÉFUTER : les neuf explications ont toutes été corrigées au passage.
/// Ce qui a sauté à ce tamis, et qu'on aurait affiché sans lui : « modérée »
/// présentée comme un verdict du noyau alors que c'est un simple test « swap
/// non vide » ; `Fmt.duration` décrite comme arrondissant alors qu'elle
/// tronque ; « CPU saturé » réservé à Adobe alors que le filtre retombe sur le
/// nom du rapport quand l'identifiant manque ; la fenêtre de tendance donnée
/// pour « les 72 dernières heures » alors qu'elle s'ancre sur le dernier point
/// enregistré.
///
/// Toute modification du calcul d'une de ces valeurs doit se répercuter ici.
/// Un chiffre juste sous une explication fausse est pire qu'un chiffre nu.
enum Explanations {
    static let all: [String: Explanation] = [

        "memoire": Explanation(
            mesure: """
            Le grand chiffre est la mémoire occupée au sens du Moniteur \
            d'activité : ce qu'utilisent les applications, plus la mémoire que \
            le système ne rend pas, plus la mémoire compressée. À côté, la \
            mémoire physique de la machine. La jauge n'est que le rapport des \
            deux. Le « cache fichier » affiché sous la courbe n'entre pas dans \
            ce chiffre : il est compté à part.
            """,
            lecture: """
            Le mot de la pression (« normale », « élevée »…) combine deux \
            choses : le niveau annoncé par le noyau et l'état du swap. « critique » et \
            « élevée » viennent du noyau. « modérée » s'affiche dès qu'il reste \
            quoi que ce soit dans le swap, et « normale » quand il est vide.
            """,
            piege: """
            « modérée » n'est pas un verdict du système : c'est le simple \
            constat qu'il y a des données dans le swap, un octet suffit. Et une \
            jauge haute ne veut pas dire que la machine manque de mémoire — le \
            cache fichier, lui, est repris sans rien demander.
            """),

        "processeur": Explanation(
            mesure: """
            La part du temps où les cœurs ont été occupés entre deux relevés — \
            1,5 s tant que ce panneau est ouvert, 5 s quand il est fermé — et \
            non à l'instant présent. Le chiffre compte chaque cœur une fois : \
            les \(CeMac.performance) cœurs de performance y pèsent donc \
            \(CeMac.part(CeMac.performance)) du total, les \(CeMac.efficacite) \
            cœurs d'efficacité \(CeMac.part(CeMac.efficacite)) ; la légende \
            donne leurs moyennes séparément.
            """,
            lecture: """
            Un E élevé avec un P bas ne peut pas faire monter le grand chiffre : \
            à eux seuls, les \(CeMac.efficacite) cœurs d'efficacité plafonnent \
            à \(CeMac.part(CeMac.efficacite)) du total. Ce chiffre ne déclenche \
            rien : la détection d'export ne regarde que la charge de Media \
            Encoder ou Compressor.
            """,
            piege: """
            Cette tuile et le « processeur » de la carte de session ne sont pas \
            dans la même échelle. Ici, 0 à 100 % pour la machine entière ; là, \
            un pourcentage d'UN cœur, qui monte jusqu'à \(CeMac.coeurs * 100) % \
            sur ce Mac. Une application à 240 % occupe 2,4 cœurs sur \
            \(CeMac.coeurs).
            """),

        "gpu": Explanation(
            mesure: """
            Ce chiffre n'est pas calculé par Pulse : c'est le compteur que \
            publie le pilote graphique, lu sans aucun privilège. Si plusieurs \
            services graphiques répondent, c'est la valeur la plus haute qui est \
            retenue, jamais leur somme.
            """,
            lecture: """
            Les trois légendes viennent de deux seuils fixes : « au repos » \
            jusqu'à 15 %, « lecture ou rendu » au-dessus, « charge soutenue » \
            au-delà de 70 %. Ces seuils sont posés, pas mesurés. Un chiffre élevé \
            n'est traité nulle part comme une alerte. Un tiret ne veut pas dire \
            zéro, mais qu'aucune valeur n'a pu être lue.
            """,
            piege: """
            Ce n'est pas le GPU de Premiere. C'est celui de la machine : \
            n'importe quel autre programme qui dessine ou décode entre dans le \
            même chiffre, et rien ici ne répartit le GPU par application.
            """),

        "reseau": Explanation(
            mesure: """
            Les octets reçus et envoyés par ce Mac sur son réseau principal, \
            additionnés jour par jour et réseau par réseau. Le partage de \
            connexion de l'iPhone se reconnaît à sa passerelle, Starlink à son \
            antenne, qui répond sur le réseau local.
            """,
            lecture: """
            Le partage iPhone est en orange : c'est du forfait mobile. Les \
            volumes sont en gigaoctets décimaux, comme chez les opérateurs. Le \
            trafic passé pendant que Pulse était fermé n'est pas compté.
            """,
            piege: """
            Ce n'est pas la consommation de toute la connexion : la télé, le \
            téléphone ou un autre ordinateur sur la même connexion \
            n'apparaissent pas ici. Seul l'espace client de l'opérateur connaît \
            le total.
            """),

        "export": Explanation(
            mesure: """
            Pulse ne surveille pas Premiere pour détecter un export, mais la \
            charge de l'encodeur — Media Encoder ou Compressor — au-dessus de \
            60 % d'un cœur. Le processeur de Premiere est inutilisable pour ça : \
            mesuré pendant la mise au point de Pulse, son maximum au repos \
            dépassait son maximum pendant un export.
            """,
            lecture: """
            Cette ligne n'apparaît que le temps de l'export ; les exports \
            terminés se retrouvent dans la carte Médias. Le seuil de 60 % est \
            posé entre deux bornes mesurées — encodeur au repos sous 31 %, en \
            export entre 102 et 231 % — mais sur un seul export de 30 s et un \
            seul format.
            """,
            piege: """
            Pas de carte ne veut pas dire pas d'export. Un export lancé \
            directement depuis Premiere ne démarre pas Media Encoder : il n'est \
            donc jamais détecté. Le seul signal qui resterait ne peut être \
            rattaché à Adobe de façon fiable, une visio ferait monter le même \
            compteur.
            """),

        "session": Explanation(
            mesure: """
            La carte apparaît dès qu'une application de montage tourne. Media \
            Encoder et Compressor sont classés « encodage » et n'ouvrent pas de \
            session. « durée » se compte depuis le lancement de l'application, \
            pas depuis le moment où vous vous êtes mis à monter. « mémoire » et \
            « processeur » ne concernent que cette application et ses processus \
            auxiliaires, panneaux d'extension compris.
            """,
            lecture: """
            Le « processeur » de cette carte ne dit pas si Premiere travaille : \
            mesuré pendant la mise au point de Pulse, il allait de 0 à 286 % au \
            repos et de 161 à 282 % pendant un export — les deux plages se \
            recouvrent. C'est pour \
            ça que l'export se détecte sur Media Encoder. « plantages » compte la \
            journée en cours, repart de zéro à minuit, et ne relève que les \
            rapports déposés par Adobe — à ne pas confondre avec la section \
            « incidents » plus bas, qui compte sur 14 jours.
            """,
            piege: """
            « processeur : 480 % » n'est pas 480 % de la machine. Ce \
            pourcentage se compte en cœurs : 100 % = un cœur occupé, 480 % ≈ \
            cinq cœurs sur les \(CeMac.coeurs).
            """),

        "graphe": Explanation(
            mesure: """
            La courbe pleine est la part de la mémoire physique occupée. Les \
            pointillés sont le swap, tracés sur la même échelle que la RAM : \
            \(CeMac.sixiemeDeLaMemoire) de swap sur un Mac de \(CeMac.memoire) \
            occupent donc un sixième de la hauteur, pas toute la hauteur. Un \
            point est enregistré toutes les \
            10 s au plus, et rien n'est gardé au-delà de 60 minutes.
            """,
            lecture: """
            L'axe horizontal aligne des points successifs, pas un temps régulier : \
            après un arrêt de Pulse, deux points voisins peuvent être séparés par \
            un trou. Le swap affiché est une occupation relue à chaque relevé, pas \
            un cumul d'écritures — un pointillé plat signifie que le total n'a pas \
            bougé, pas qu'aucune page n'a été écrite.
            """,
            piege: """
            « cache fichier » n'est pas le cache média de Premiere. Aucun \
            rapport : celui-ci est de la mémoire que macOS reprend seul à \
            l'instant où il en a besoin, l'autre est un dossier de plusieurs \
            gigaoctets sur votre disque, qu'il faut vider à la main. Ce n'est pas \
            non plus de la mémoire à libérer : elle est comptée à part et exclue \
            de la courbe.
            """),

        "coeurs": Explanation(
            mesure: """
            Une barre par cœur logique, \(CeMac.coeurs) sur ce Mac. La hauteur est \
            la part du temps, sur l'intervalle écoulé, pendant laquelle ce cœur \
            n'était pas inactif — de 0 à 100 % de ce seul cœur. Tout y compte : \
            Premiere, Media Encoder, et macOS lui-même.
            """,
            lecture: """
            Rien ici n'est un signal d'alarme : cette section n'a ni seuil ni \
            couleur d'avertissement. Les barres ne restent à plat qu'une seule \
            fois, au tout premier relevé après le lancement — un taux se calcule \
            entre deux mesures, jamais sur une seule.
            """,
            piege: """
            L'en-tête annonce « \(CeMac.performance) P · \(CeMac.efficacite) E », \
            mais les barres sont dans l'ordre inverse : les \(CeMac.efficacite) \
            premières, en gris, sont les cœurs d'efficacité, et les \
            \(CeMac.performance) suivantes, en bleu, ceux de performance.
            """),

        "apps": Explanation(
            mesure: """
            Pulse chronomètre l'application active — une seule à la fois, celle \
            que macOS met au premier plan — et cumule par jour. Pulse ne se \
            compte jamais lui-même. Sont écartés la veille, l'écran verrouillé, \
            et tout intervalle au terme duquel plus rien n'a été touché depuis \
            5 minutes : l'intervalle entier est jeté, pas seulement sa fin.
            """,
            lecture: """
            Le total à droite du titre porte sur toutes les applications du jour, \
            alors que la liste n'en montre que cinq : les barres ne s'additionnent \
            pas jusqu'à ce total. Elles comparent chaque application à la \
            première du classement, ce n'est pas une part de la journée. Les \
            couleurs disent la catégorie et non un niveau, et cette section n'a \
            pas de légende : bleu pour le montage, orange pour l'export et le \
            transcodage, gris pour tout le reste.
            """,
            piege: """
            « Media Encoder : 12 min » ne veut pas dire un export de douze \
            minutes. Le temps n'est compté que pendant que l'application est au \
            premier plan : un export qui tourne derrière pendant que vous \
            continuez dans Premiere crédite Premiere. Ce classement mesure où \
            vous regardez, pas ce que la machine calcule.
            """),

        "incidents": Explanation(
            mesure: """
            Un décompte d'événements sur 14 jours glissants, pas un pourcentage — \
            là où la carte de session, elle, ne compte que la journée. Chaque \
            ligne compte des fichiers laissés par Adobe ou par macOS. « processus \
            tué (mémoire) » veut dire que macOS a fermé d'autorité un programme \
            parce qu'il ne restait plus de mémoire : ce n'est pas un plantage du \
            programme, c'est le système qui tranche. Pulse n'ouvre jamais le \
            contenu de ces rapports.
            """,
            lecture: """
            « processus tué » vaut pour la machine entière, à rapprocher de la \
            mémoire et du swap. Si cette ligne n'apparaît jamais, son dossier \
            source n'est peut-être pas lisible : `--probe` le dit franchement. \
            Aucun incident sur 14 jours : la ligne disparaît du panneau.
            """,
            piege: """
            Un total bas ne veut pas dire que la machine s'est bien tenue. Deux \
            familles de rapports de macOS sont volontairement écartées parce \
            qu'elles décrivent un montage ordinaire : les écritures disque \
            (franchies par n'importe quel export) et l'usage processeur \
            (Premiere à plus de la moitié d'un cœur pendant 3 min). Et les \
            plantages ne sont cherchés que du côté d'Adobe.
            """),

        "volumes": Explanation(
            mesure: """
            « libres », c'est ce que macOS déclare disponible, y compris ce qu'il \
            récupérera seul en cas de besoin. « utilisés » ne s'en déduit pas : ce \
            récupérable y est compté comme occupé, et c'est lui que suit la barre. \
            La vitesse est estimée sur les 72 h précédant le dernier relevé, \
            intervalle par intervalle, en écartant les copies et les effacements \
            en masse. Si les dernières 24 h vont moins vite, c'est leur rythme \
            qui compte : un gros téléchargement terminé ne fait plus annoncer un \
            disque plein.
            """,
            lecture: """
            « plein dans ~N jours » suppose que le rythme se poursuit : ça ignore \
            les rushes que vous vous apprêtez à copier. « tendance en cours de calcul » \
            n'est pas une panne — il faut six heures d'observation calme, et la \
            prévision se tait si le dernier relevé date de plus de deux heures, \
            typiquement un disque débranché.
            """,
            piege: """
            Additionner « utilisés » et « libres » donne plus que la capacité du \
            disque, et ce n'est pas une erreur d'affichage. L'écart est exactement \
            l'espace récupérable, compté comme occupé d'un côté et comme libre de \
            l'autre. C'est lui que nomme la ligne « dont N Go récupérables ».
            """),
    ]
}

/// La ligne unique affichée sous chaque graphique.
///
/// Un graphique sans légende laisse deviner ce qu'on regarde ; un paragraphe
/// sous un graphique ne se lit pas. Une ligne, donc — et le reste en infobulle.
/// Chaque phrase est un extrait des explications vérifiées ci-dessus : ne la
/// réécris pas sans revérifier la source qui produit le chiffre.
enum Legendes {
    static let all: [String: String] = [
        "memoire": "Le cache fichier est compté à part : il n'entre pas dans le total, macOS le reprend seul.",
        "processeur": "Part des \(CeMac.coeurs) cœurs occupée : les \(CeMac.performance) cœurs P en font \(CeMac.part(CeMac.performance)), les \(CeMac.efficacite) E \(CeMac.part(CeMac.efficacite)).",
        "gpu": "Compteur du pilote graphique, pour la machine entière — pas pour Premiere seul.",
        "coeurs": "Les \(CeMac.efficacite) premières barres sont les cœurs E, malgré l'en-tête « \(CeMac.performance) P · \(CeMac.efficacite) E ».",
        "graphe": "Occupation du swap à son échelle propre, relue à chaque relevé — pas un cumul d'écritures.",
        "session": "Pics de la session en cours, puis la durée des sessions des sept derniers jours.",
        "apps": "Temps au premier plan par jour. Sans rien toucher, le décompte s'arrête après cinq minutes.",
        "incidents": "Rapports écrits par macOS et Adobe, groupés par jour. Pulse n'en lit que l'en-tête.",
        "volumes": "Espace libre au fil du temps — la courbe d'où sort la prévision « plein dans ~N jours ».",
        "reseau": "Ce Mac seulement : les autres appareils sur la même connexion ne sont pas comptés.",
        "export": "Détecté sur la charge de l'encodeur, jamais sur Premiere, dont le repos dépasse l'export.",
        "debit": "Moyenne de chaque tranche : un pic de quelques secondes s'y tasse, il reste dans les 3 dernières minutes.",
    ]
}

/// Les chiffres du Mac où Pulse tourne. Les explications ont été écrites sur
/// le M2 Max d'Isma (12 cœurs, 8 P et 4 E, 32 Go) : envoyées telles quelles,
/// elles annonçaient « douze cœurs » et « 8 P · 4 E » sur le M1 Pro d'un ami,
/// qui en a 10, dont 2 E (26/10).
enum CeMac {
    static let performance = CPUMonitor.performanceCores
    static let efficacite = CPUMonitor.efficiencyCores
    static let coeurs: Int = {
        let parGrappe = CPUMonitor.performanceCores + CPUMonitor.efficiencyCores
        return parGrappe > 0 ? parGrappe : ProcessInfo.processInfo.activeProcessorCount
    }()
    static let memoire = Fmt.memory(ProcessInfo.processInfo.physicalMemory, digits: 0)
    static let sixiemeDeLaMemoire = Fmt.memory(Double(ProcessInfo.processInfo.physicalMemory) / 6)

    /// « 67 % » : la part de `n` cœurs dans le total.
    static func part(_ n: Int) -> String {
        Fmt.percent(coeurs > 0 ? Double(n) / Double(coeurs) : 0)
    }
}
