#!/usr/bin/env python3
"""Chaque test du moteur des règles vu échouer sans sa correction.

    python3 outils/mutations-regles.py          toutes les mutations (~10 min)
    python3 outils/mutations-regles.py 3 17     seulement celles-là

Copie Sources/, Tests/ et Package.swift dans un dossier temporaire (rien ne
touche le dépôt), puis, mutation par mutation : retire UNE correction,
recompile les tests, lance les tests qui la couvrent, vérifie qu'ils
échouent, remet le fichier d'origine. Code de sortie 1 si une mutation
laisse passer son test : ce test ne prouve rien.
"""
import os, shutil, subprocess, sys, tempfile

SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DST = os.path.join(tempfile.gettempdir(), "pulse-mutations-regles")
M = "Sources/Pulse/Rules/Moteur.swift"
R = "Sources/Pulse/Rules/Regle.swift"
L = "Sources/Pulse/Rules/LectureRegles.swift"
S = "Sources/Pulse/Rules/SurveillantRegles.swift"

MUTATIONS = [
    ("durée minimale ignorée", M,
     "if date.timeIntervalSince(depuis) >= regle.duree {", "if true {",
     ["dureeMinimale", "dureeInterrompue"]),
    ("interruption sans remise à zéro", M,
     "            } else {\n                etat.vraiDepuis = nil\n            }\n            etats[cle] = etat",
     "            } else {\n            }\n            etats[cle] = etat",
     ["dureeInterrompue"]),
    ("hystérésis sans marge", M,
     "case .sous:     return (v < regle.seuil, v >= regle.seuil + regle.marge)",
     "case .sous:     return (v < regle.seuil, v >= regle.seuil)",
     ["hysteresisUneNotificationParEpisode"]),
    ("hystérésis sans délai de sortie", M,
     "if date.timeIntervalSince(depuis) >= regle.relache {", "if true {",
     ["hysteresisUneNotificationParEpisode"]),
    ("une notification à chaque relevé de l'épisode", M,
     "if !episode.notifie, entree, permis {", "if entree, permis {",
     ["hysteresisUneNotificationParEpisode"]),
    ("plage horaire ignorée (état)", M,
     "let permis = regle.plage?.contient(date, calendrier: calendrier) ?? true", "let permis = true",
     ["horsPlageDiffereOuTu"]),
    ("plage horaire ignorée (événement)", M,
     "if regle.plage?.contient(date, calendrier: calendrier) ?? true {", "if true {",
     ["horsPlageDiffereOuTu"]),
    ("plage à cheval sur minuit comptée au mauvais jour", R,
     "if minute < fin { return vaut(veille) }", "if minute < fin { return vaut(jour) }",
     ["plageHoraire"]),
    ("pas d'intervalle entre deux notifications", M,
     "if let derniere = derniereNotification, date.timeIntervalSince(derniere) < reglages.intervalle {\n            return (journal, nil)\n        }",
     "",
     ["regroupement"]),
    ("pas de retenue en montage", M,
     "let retenir = reglages.retenirEnMontage && releve.enMontage", "let retenir = false",
     ["retenueEnMontage"]),
    ("une alerte retombée part quand même", M,
     "guard !alerte.evenement, etats[alerte.cle]?.episode?.debut != alerte.date else { return false }",
     "return false",
     ["retombeeAvantDEtreDite"]),
    ("trou de veille ignoré", M,
     "let trou = dernierReleve.map { date.timeIntervalSince($0) > Self.trouMax || date < $0 } ?? false",
     "let trou = false",
     ["trouDeVeille"]),
    ("mesure absente = fin d'épisode", M,
     "if etats[cle]?.episode == nil { etats[cle] = nil }", "etats[cle] = nil",
     ["mesureAbsenteGeleLEpisode"]),
    ("pas de rafale : un épisode par événement", M,
     "            if var episode = etat.episode {\n                episode.nombre += 1",
     "            if var episode = etat.episode, false {\n                episode.nombre += 1",
     ["rafaleDEvenements"]),
    ("le compte de la rafale ne suit pas dans la boîte", M,
     "if let i = boite.firstIndex(where: { $0.cle == cle }) { boite[i].texte = episode.texte }", "",
     ["rafaleRetenueDitLeCompte"]),
    ("pas de référence au premier relevé", L,
     "        if initialise {\n            for incident", "        if true {\n            for incident",
     ["detecteurEvenements"]),
    ("pas de reprise du journal", M,
     "        let parId = Dictionary(regles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })\n        var ouverts",
     "        return\n        let parId = Dictionary(regles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })\n        var ouverts",
     ["repriseSansRedire"]),
    ("une règle éteinte garde ses alertes", M,
     "        boite.removeAll { !actives.contains($0.regle) }\n", "",
     ["extinction"]),
    ("abonné au relevé même sans règle active", S,
     "guard regles.contains(where: \\.active) else {", "guard true else {",
     ["coutNulSansRegleActive"]),
    ("hausse du swap extrapolée sous 5 min", L,
     "guard let ancien = series.first(where: { $0.t >= t - 3600 }), t - ancien.t >= 300 else { return nil }",
     "guard let ancien = series.first(where: { $0.t >= t - 3600 }) else { return nil }",
     ["hausseDuSwap"]),
    ("décodeur strict (règle dure n°2)", R,
     "seuil = c.tolerant(Double.self, .seuil).flatMap { $0.isFinite ? $0 : nil } ?? 0",
     "seuil = try c.decode(Double.self, forKey: .seuil)",
     ["lectureTolerante"]),
    ("un préréglage allumé par défaut", R,
     'Regle(id: "export-termine", nom: "Export terminé",',
     'Regle(id: "export-termine", nom: "Export terminé", active: true,',
     ["prereglagesTousEteints"]),
    ("Premiere au premier plan ne retient rien", L,
     "bundleId.map { AppKind.of(bundleId: $0) == .editing } ?? false", "false",
     ["notificateurInjecte"]),
    ("cloche réservée sans règle qui la demande", S,
     "guard regles.contains(where: { $0.active && $0.barre }) else { return nil }",
     "guard true else { return nil }",
     ["clocheReserveeSeulementSiDemandee"]),
    ("place de la cloche non réservée quand le verdict n'a pas de symbole", "Sources/Pulse/MenuBar/MenuBarContent.swift",
     "let reserves = settings.menuBar.alert != .never || reading.regles != nil",
     "let reserves = settings.menuBar.alert != .never",
     ["clocheReserveeSeulementSiDemandee"]),
    ("le triangle du verdict passe devant la cloche", "Sources/Pulse/MenuBar/MenuBarContent.swift",
     "let alert = reading.regles == true", "let alert = verdict == nil && reading.regles == true",
     ["clocheReserveeSeulementSiDemandee"]),
    ("le disque de rushes pris au plus grand", "Sources/Pulse/Rules/PageRegles.swift",
     "return da != db ? da < db : a.available < b.available", "return a.total < b.total",
     ["disqueDeRushesPlutotQueLePlusGrand"]),
    ("une alerte en attente garde les réglages d'avant", M,
     "            guard let regle = parId[alerte.regle], regle.notification else { return nil }\n"
     "            var a = alerte\n            a.nom = regle.nom\n            a.son = regle.son\n"
     "            a.urgente = regle.urgente\n            return a",
     "            return alerte",
     ["reglagesDuMomentPourUneAlerteEnAttente"]),
]


def run(cmd, log):
    with open(log, "w") as f:
        return subprocess.call(cmd, cwd=DST, stdout=f, stderr=subprocess.STDOUT)


def main():
    seules = sys.argv[1:]
    if os.path.isdir(DST):
        shutil.rmtree(os.path.join(DST, "Sources"), ignore_errors=True)
        shutil.rmtree(os.path.join(DST, "Tests"), ignore_errors=True)
    os.makedirs(DST, exist_ok=True)
    for item in ["Sources", "Tests"]:
        shutil.copytree(os.path.join(SRC, item), os.path.join(DST, item))
    shutil.copy(os.path.join(SRC, "Package.swift"), DST)
    logs = os.path.join(DST, "logs")
    os.makedirs(logs, exist_ok=True)
    if run(["swift", "build", "--build-tests"], os.path.join(logs, "base.log")) != 0:
        print("la base ne compile pas"); return 1
    filtre = "|".join(sorted({t for m in MUTATIONS for t in m[4]}))
    if run(["swift", "test", "--skip-build", "--filter", filtre], os.path.join(logs, "base-tests.log")) != 0:
        print("la base échoue : rien à prouver"); return 1
    print("base : tous les tests passent")
    bilan = 0
    for i, (nom, fichier, avant, apres, tests) in enumerate(MUTATIONS):
        if seules and str(i) not in seules:
            continue
        chemin = os.path.join(DST, fichier)
        original = open(chemin).read()
        if original.count(avant) != 1:
            print(f"[{i}] {nom} : motif introuvable ou multiple ({original.count(avant)})"); bilan = 1; continue
        open(chemin, "w").write(original.replace(avant, apres))
        try:
            if run(["swift", "build", "--build-tests"], os.path.join(logs, f"m{i}-build.log")) != 0:
                print(f"[{i}] {nom} : ne compile pas"); bilan = 1; continue
            code = run(["swift", "test", "--skip-build", "--filter", "|".join(tests)], os.path.join(logs, f"m{i}-tests.log"))
            texte = open(os.path.join(logs, f"m{i}-tests.log"), errors="replace").read()
            echoues = [t for t in tests if f"Test {t}() failed" in texte or f"{t}() recorded an issue" in texte]
            if code != 0 and len(echoues) == len(tests):
                print(f"[{i}] {nom} : échoue comme attendu — {', '.join(tests)}")
            else:
                print(f"[{i}] {nom} : NE FAIT PAS ÉCHOUER {', '.join(t for t in tests if t not in echoues)}"); bilan = 1
        finally:
            open(chemin, "w").write(original)
        sys.stdout.flush()
    return bilan


if __name__ == "__main__":
    sys.exit(main())
