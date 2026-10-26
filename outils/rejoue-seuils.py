#!/usr/bin/env python3
"""Rejoue les seuils des règles 7, 9 et 10 du verdict sur les données de Pulse.

Le journal des verdicts ne garde que le verdict AFFICHÉ (voir
`rejoue-verdicts.py`) : une règle masquée n'y laisse rien, et aucun chiffre.
Les seuils se calibrent donc sur les mesures elles-mêmes, rejouées :

- règle 9 (« plein dans moins de N jours ») : la prévision de remplissage
  (`HistoryStore.forecast`, copiée ici à l'identique) recalculée à chaque
  point des 30 jours de disques de history.json ;
- règle 7 (« le swap monte », hausse sur l'heure) : la série du swap de
  historique.sqlite ;
- règle 10 (processeur au-delà de N %) : la série du processeur total.

Rien n'est lu en place : chaque fichier est d'abord copié dans un dossier
temporaire, et c'est la copie qu'on ouvre — une base SQLite ouverte, même en
lecture, peut écrire son index (`-shm`), et Pulse écrit history.json chaque
minute.

    python3 outils/rejoue-seuils.py

Le 11/10, sur 13 jours de disque interne : seuil de 30 jours actif 43,5 % du
temps ; 14 jours, 26,7 %. Entre 14 et 30 jours, l'échéance annoncée a disparu
24 h plus tard dans 68 à 77 % des cas, et le disque n'était plus plein 3 jours
après que dans 21 à 36 % des cas : la règle 9 passe à 14 jours.
"""
import bisect
import datetime as dt
import json
import os
import shutil
import sqlite3
import statistics
import sys
import tempfile

DOSSIER = os.path.expanduser("~/Library/Application Support/Pulse")

# ── La prévision, copiée de HistoryStore.forecast ──────────────────────────
TENDANCE = 72 * 3600
RECENT = 24 * 3600
OBSERVATION_MIN = 6 * 3600
RUPTURE = 0.05            # 5 % de la capacité d'un coup : opération en masse
DEBIT_MAX = 5e12          # 5 To par jour : une copie, pas un travail
ANCIENNETE_MAX = 2 * 3600


def rythme_calme(points, depuis, masse):
    libere = secondes = 0.0
    for a, b in zip(points, points[1:]):
        if a["t"] < depuis:
            continue
        dt_ = b["t"] - a["t"]
        if dt_ <= 0:
            continue
        if a.get("freeStrict") is not None and b.get("freeStrict") is not None:
            df = b["freeStrict"] - a["freeStrict"]
        else:
            df = b["free"] - a["free"]
        if abs(df) > masse or abs(df) / dt_ * 86400 > DEBIT_MAX:
            continue
        libere += df
        secondes += dt_
    return (libere / secondes if secondes > 0 else 0.0), secondes


def prevision(points, capacite, libre):
    """Jours avant saturation, ou None : même règle que l'app."""
    dernier = points[-1]
    fenetre = [p for p in points if p["t"] >= dernier["t"] - TENDANCE]
    if len(fenetre) < 2:
        return None
    masse = capacite * RUPTURE
    long = rythme_calme(fenetre, dernier["t"] - TENDANCE, masse)
    if long[1] < OBSERVATION_MIN:
        return None
    retenu = long
    court = rythme_calme(fenetre, dernier["t"] - RECENT, masse)
    if court[1] >= OBSERVATION_MIN and court[0] > long[0]:
        retenu = court
    if retenu[0] >= 0:
        return None
    jours = libre / -retenu[0] / 86400
    return jours if 0 <= jours < 400 else None


def capacites():
    """Capacité de chaque volume, lue dans historique.sqlite (bound de sa série)."""
    out = {}
    base = copie("historique.sqlite")
    if not base:
        return out
    c = sqlite3.connect("file:" + base + "?mode=ro", uri=True)
    for cle, nom, borne in c.execute("select key, label, bound from series where key like 'disque.%'"):
        uuid = cle[len("disque."):].rsplit(".", 1)[0]
        if borne:
            out[uuid] = (nom or uuid, borne)
    return out


def regle9(seuils=(30, 21, 14, 10, 7)):
    chemin = copie("history.json")
    if not chemin:
        print("règle 9 : history.json introuvable")
        return
    volumes = json.load(open(chemin)).get("volumes", {})
    print("RÈGLE 9 · prévision rejouée point par point (history.json, 30 jours)")
    for uuid, (nom, capacite) in sorted(capacites().items(), key=lambda kv: kv[1][0]):
        points = sorted(volumes.get(uuid, []), key=lambda p: p["t"])
        if len(points) < 10:
            continue
        serie = [(points[i]["t"], prevision(points[: i + 1], capacite, points[i]["free"]), points[i]["free"])
                 for i in range(1, len(points))]
        total = 0.0
        actif = {s: 0.0 for s in seuils}
        entrees = {s: 0 for s in seuils}
        avant = {s: False for s in seuils}
        for (t, jours, _), suivant in zip(serie, serie[1:] + [None]):
            duree = (suivant[0] - t) if suivant else 0
            if duree > ANCIENNETE_MAX:
                duree = 0                       # Pulse éteint : ni vrai ni faux
            total += duree
            for s in seuils:
                vrai = jours is not None and jours < s
                actif[s] += duree if vrai else 0
                entrees[s] += 1 if vrai and not avant[s] else 0
                avant[s] = vrai
        if total < 86400:
            continue
        print(f"  {nom} : {total / 86400:.1f} jours observés")
        for s in seuils:
            print(f"    seuil {s:>2} j : vrai {100 * actif[s] / total:5.1f} % du temps, {entrees[s]} entrées")
        # Ce que vaut une échéance, par tranche : 24 h plus tard, existe-t-elle
        # encore ? 3 jours plus tard, le disque est-il plus plein ?
        temps = [t for t, _, _ in serie]
        for bas, haut in ((0, 7), (7, 14), (14, 30)):
            disparues = paires = plus_plein = issues = 0
            for t, jours, libre in serie:
                if jours is None or not (bas <= jours < haut):
                    continue
                j = bisect.bisect_left(temps, t + 86400)
                if j < len(serie) and abs(serie[j][0] - t - 86400) < 3 * 3600:
                    paires += 1
                    disparues += serie[j][1] is None
                k = bisect.bisect_left(temps, t + 3 * 86400)
                if k < len(serie) and abs(serie[k][0] - t - 3 * 86400) < 3 * 3600:
                    issues += 1
                    plus_plein += serie[k][2] < libre
            if paires or issues:
                print(f"    échéance de {bas} à {haut} j : disparue 24 h après {disparues}/{paires}, "
                      f"disque plus plein 3 j après {plus_plein}/{issues}")


def regle7_et_10():
    base = copie("historique.sqlite")
    if not base:
        print("règles 7 et 10 : historique.sqlite introuvable")
        return
    c = sqlite3.connect("file:" + base + "?mode=ro", uri=True)
    ids = {cle: i for i, cle in c.execute("select id, key from series")}

    def serie(cle):
        if cle not in ids:
            return []
        # Minutes (7 jours) d'abord, points bruts de 10 s (24 h) en relais :
        # la série la plus longue qui existe.
        minutes = c.execute("select t, avg from minute where s=? order by t", (ids[cle],)).fetchall()
        bruts = c.execute("select t, v from raw where s=? order by t", (ids[cle],)).fetchall()
        return minutes if len(minutes) * 60 >= len(bruts) * 10 else bruts

    swap = serie("memoire.swap")
    if swap:
        heures = (swap[-1][0] - swap[0][0]) / 3600
        print(f"\nRÈGLE 7 · hausse du swap sur l'heure ({len(swap)} points, {heures:.1f} h, historique.sqlite)")
        temps = [t for t, _ in swap]
        for gio in (1, 2, 4, 6):
            vrai = n = entrees = 0
            avant = False
            for t, v in swap:
                j = bisect.bisect_left(temps, t - 3600)
                if t - temps[j] < 300:          # moins de 5 min d'historique : rien
                    continue
                n += 1
                cur = (v - swap[j][1]) >= gio * 2 ** 30
                vrai += cur
                entrees += cur and not avant
                avant = cur
            print(f"  seuil +{gio} Go/h : vrai {100 * vrai / max(n, 1):5.1f} % du temps, {entrees} entrées")
        if heures < 72:
            print("  moins de 3 jours de série : à relancer quand l'historique couvre une semaine de montage")

    cpu = serie("cpu.total")
    if cpu:
        heures = (cpu[-1][0] - cpu[0][0]) / 3600
        print(f"\nRÈGLE 10 · processeur total ({len(cpu)} points, {heures:.1f} h, historique.sqlite)")
        for seuil in (0.80, 0.90, 0.95):
            part = sum(1 for _, v in cpu if v > seuil) / len(cpu)
            print(f"  au-dessus de {int(seuil * 100)} % : {100 * part:5.1f} % du temps")
        # La charge de l'app hors montage la plus occupée, en % d'UN cœur :
        # série relevée depuis le 11/10 (chantier 12) pour ce rejeu.
        autre = {}
        if "processeur.hors-montage" in ids:
            # Les deux séries au MÊME étage, pour que leurs instants coïncident :
            # les minutes (7 jours) si l'app en a déjà, sinon les points de 10 s.
            for etage, valeur in (("minute", "avg"), ("raw", "v")):
                lignes = c.execute(f"select t, {valeur} from {etage} where s=? order by t",
                                   (ids["processeur.hors-montage"],)).fetchall()
                if len(lignes) > 10:
                    autre = dict(lignes)
                    cpu = c.execute(f"select t, {valeur} from {etage} where s=? order by t",
                                    (ids["cpu.total"],)).fetchall()
                    break
        if autre:
            communs = [(t, v, autre[t]) for t, v in cpu if t in autre]
            print(f"  avec l'app hors montage la plus chargée ({len(communs)} points communs) :")
            for machine in (0.80, 0.90):
                for app in (100, 200, 300):
                    part = sum(1 for _, v, a in communs if v > machine and a > app) / max(len(communs), 1)
                    print(f"    processeur > {int(machine * 100)} % et app > {app} % d'un cœur : "
                          f"{100 * part:5.1f} % du temps")
        else:
            print("  pas encore de série « processeur.hors-montage » : la moitié « 200 % d'un cœur » "
                  "ne se rejoue pas")


_dossier_copies = tempfile.mkdtemp(prefix="pulse-seuils-")


def copie(nom):
    """Copie le fichier de Pulse dans un dossier temporaire ; rend son chemin."""
    source = os.path.join(DOSSIER, nom)
    if not os.path.exists(source):
        return None
    cible = os.path.join(_dossier_copies, nom)
    if not os.path.exists(cible):
        shutil.copy2(source, cible)
    return cible


def main():
    print(f"données : {DOSSIER} (copiées dans {_dossier_copies}, jamais ouvertes en place)\n")
    regle9()
    regle7_et_10()
    shutil.rmtree(_dossier_copies, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        DOSSIER = sys.argv[1]
    main()
