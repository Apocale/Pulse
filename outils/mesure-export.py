#!/usr/bin/env python3
"""Caractérise le signal d'un export Premiere, en vue de le détecter dans Pulse.

Le README établit que la PRÉSENCE de VTEncoderXPCService ne signale rien :
13 instances tournent en permanence à vide pendant une simple lecture de
timeline. Ce qui reste exploitable est leur CONSOMMATION. Reste à savoir si
elle sépare vraiment un export d'une lecture, et à quel seuil.

Cet outil relève cette consommation en continu. Il ne décide rien : il produit
le CSV sur lequel le seuil sera choisi.

    python3 outils/mesure-export.py

Le laisser tourner, faire un export réel, puis Ctrl-C. Le CSV est écrit à côté.

PIÈGE ÉVITÉ — la colonne %CPU de `ps` est une moyenne sur TOUTE la vie du
processus, pas une mesure instantanée. Sur un VTEncoderXPCService vivant depuis
40 minutes, un export de 3 minutes y serait presque invisible. On relève donc
le TEMPS CPU cumulé et on le dérive entre deux relevés, ce qui donne la charge
réelle sur l'intervalle. C'est la même distinction que celle qui vaut à
`pti_total_user` son entrée dans les pièges du README.
"""
import csv, os, shutil, subprocess, sys, time

INTERVALLE = 3.0        # secondes entre deux relevés

# Un fichier par exécution. Deux instances lancées sur le même nom écrivaient
# chacune à son propre décalage : relevés en double, lignes tronquées au milieu
# d'un nombre, et des maxima inventés par le recollement. Arrivé en vrai.
DOSSIER = os.path.dirname(os.path.abspath(__file__))
CSV = os.path.join(DOSSIER, f"mesure-export-{time.strftime('%H%M%S')}.csv")

# Motif cherché dans la ligne de commande -> nom de colonne.
GROUPES = [
    ("VTEncoderXPCService", "encodeur"),
    ("VTDecoderXPCService", "decodeur"),
    ("Adobe Premiere Pro 2026.app", "premiere"),
    ("Adobe Media Encoder 2026.app", "media_encoder"),
]
VOLUMES = [("/", "interne_Go"), ("/Volumes/Ssd 2", "ssd_Go")]


def secondes_cpu(champ):
    """« 68:41.92 » ou « 2:05:30 » -> secondes."""
    parts = champ.split(":")
    try:
        if len(parts) == 2:
            return int(parts[0]) * 60 + float(parts[1])
        if len(parts) == 3:
            return int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
    except ValueError:
        pass
    return 0.0


def releve():
    """pid -> (temps cpu cumulé, groupe). Un pid absent du tour suivant est
    simplement perdu : sa dernière tranche est négligeable devant l'intervalle."""
    out = subprocess.run(["ps", "-Ao", "pid=,time=,command="],
                         capture_output=True, text=True).stdout
    vus = {}
    for ligne in out.splitlines():
        morceaux = ligne.strip().split(None, 2)
        if len(morceaux) < 3:
            continue
        pid, temps, commande = morceaux
        for motif, nom in GROUPES:
            if motif in commande:
                vus[int(pid)] = (secondes_cpu(temps), nom)
                break
    return vus


def main():
    noms = [nom for _, nom in GROUPES]
    colonnes = (["horodatage", "ecoule_s"]
                + [f"cpu_{n}" for n in noms]
                + [f"nb_{n}" for n in noms]
                + [c for _, c in VOLUMES])

    # Deux instances ne se marchent plus dessus, mais deux relevés simultanés
    # du même export restent une confusion inutile : autant le dire.
    miennes = subprocess.run(["pgrep", "-f", "mesure-export.py"],
                             capture_output=True, text=True).stdout.split()
    if len(miennes) > 1:
        print(f"Attention : {len(miennes) - 1} autre(s) relevé(s) déjà en cours.\n")

    print(f"Relevé toutes les {INTERVALLE:.0f} s -> {CSV}")
    print("Lancer un export maintenant, puis Ctrl-C pour arrêter.\n")
    print("   ".join(f"{n:>14}" for n in ["heure"] + noms))

    precedent, t0 = releve(), time.time()
    with open(CSV, "w", newline="", encoding="utf-8") as f:
        plume = csv.writer(f)
        plume.writerow(colonnes)
        try:
            while True:
                time.sleep(INTERVALLE)
                courant = releve()
                maintenant = time.time()
                ecoule = maintenant - t0

                # Dérivée du temps CPU cumulé, en % d'UN cœur — même unité que
                # le Moniteur d'activité et que l'affichage « par application »
                # de Pulse. Peut donc dépasser 100 %.
                charge = {n: 0.0 for n in noms}
                nombre = {n: 0 for n in noms}
                for pid, (cpu, groupe) in courant.items():
                    avant = precedent.get(pid, (0.0, groupe))[0]
                    delta = cpu - avant
                    if delta >= 0:                     # pid recyclé -> on ignore
                        charge[groupe] += delta / INTERVALLE * 100
                    nombre[groupe] += 1

                libres = []
                for chemin, _ in VOLUMES:
                    try:
                        libres.append(round(shutil.disk_usage(chemin).free / 1e9, 2))
                    except OSError:
                        libres.append("")

                plume.writerow([time.strftime("%H:%M:%S"), round(ecoule, 1)]
                               + [round(charge[n], 1) for n in noms]
                               + [nombre[n] for n in noms] + libres)
                f.flush()
                print("   ".join([f"{time.strftime('%H:%M:%S'):>14}"]
                                 + [f"{charge[n]:>10.1f} % " for n in noms]))
                precedent = courant
        except KeyboardInterrupt:
            print(f"\nArrêté. {CSV}")


if __name__ == "__main__":
    sys.exit(main())
