#!/usr/bin/env python3
"""Rejoue le journal des verdicts sous un délai de tenue, pour le calibrer.

Le journal (`verdicts.jsonl`) note chaque verdict affiché. Cet outil rejoue
cette suite avec la règle de `VerdictEngine.holdDelay` : un nouveau verdict ne
remplace l'affiché que s'il gagne depuis H secondes, sauf s'il est plus grave
(alerte > avertissement > info > calme) ou si l'affiché était un export fini.

    python3 outils/rejoue-verdicts.py            # H = 300 s, et une échelle
    python3 outils/rejoue-verdicts.py 600        # un autre délai

Le 09/10, sur 16 jours de journal : 35,7 changements par jour sans délai,
7,3 avec 300 s. C'est ce relevé qui a fixé la valeur.

LIMITE CONNUE — le journal ne contient que les verdicts GAGNANTS, pas l'état de
chaque règle : une règle masquée par une plus prioritaire n'y laisse aucune
trace. Le rejeu filtre donc la suite affichée ; il ne peut pas réévaluer une
règle. C'est exact pour un délai posé en sortie du barème — ce qu'est
`holdDelay` — et seulement pour lui.
"""
import datetime as dt
import json
import os
import sys

JOURNAL = os.path.expanduser("~/Library/Application Support/Pulse/verdicts.jsonl")
RANG = {"muted": 0, "data": 1, "warning": 2, "alert": 3}
EXPORT = 11


def seances():
    """Les suites de verdicts, coupées aux lancements et aux arrêts de Pulse."""
    lignes = []
    with open(JOURNAL, encoding="utf-8") as f:
        for ligne in f:
            try:
                lignes.append(json.loads(ligne))
            except ValueError:
                continue  # une ligne abîmée est sautée, pas fatale
    lignes.sort(key=lambda r: r["t"])
    out, cur = [], []
    for r in lignes:
        if r.get("event") in ("start", "stop"):
            if cur:
                out.append((cur, r["t"]))
                cur = []
            continue
        if "rule" in r:
            cur.append((r["t"], r["rule"], RANG.get(r.get("level"), 2)))
    if cur:
        out.append((cur, cur[-1][0]))
    return out


def rejoue(seances, tenue):
    """Nombre de changements de verdict affiché, sous le délai `tenue`."""
    changements = 0
    for suite, fin in seances:
        affiche = suite[0][1:]
        pretendant, depuis = None, None
        for t, regle, rang in suite[1:] + [(fin, None, None)]:
            if pretendant and pretendant[0] != affiche[0]:
                plus_grave = pretendant[1] > affiche[1]
                export_fini = affiche[0] == EXPORT
                if plus_grave or export_fini or t - depuis >= tenue:
                    changements += 1
                    affiche = pretendant
            if regle is None:
                break
            if regle == affiche[0]:
                pretendant = None
                continue
            if pretendant is None or pretendant[0] != regle:
                pretendant, depuis = (regle, rang), t
    return changements


def main():
    s = seances()
    jours = {dt.date.fromtimestamp(t).isoformat() for suite, _ in s for t, _, _ in suite}
    if not jours:
        print("journal vide")
        return
    print(f"{len(jours)} jours de journal ({min(jours)} → {max(jours)})")
    delais = [int(a) for a in sys.argv[1:]] or [0, 60, 120, 300, 600]
    for tenue in delais:
        par_jour = rejoue(s, tenue) / len(jours)
        print(f"  tenue {tenue:>4} s : {par_jour:5.1f} changements de verdict par jour")


if __name__ == "__main__":
    main()
