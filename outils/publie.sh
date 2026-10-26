#!/bin/bash
# Publie Pulse sur GitHub (github.com/Apocale/Pulse) : le code de main, SANS
# son historique, et la version à télécharger.
#
#   outils/publie.sh 1.1     → un commit sur la branche « public » (l'arbre de
#                               main tel quel), poussé en main sur GitHub, puis
#                               la version v1.1 avec Pulse.zip et son empreinte
#
# Pourquoi pas `git push main` : les anciens commits de main portent des noms
# de clients et de proches d'Isma, retirés de l'arbre le 26/10 mais toujours
# dans l'historique. La branche public a le sien : un commit par publication.
# Le crochet .git/hooks/pre-push refuse toute autre poussée vers GitHub.
#
# Les mots à ne jamais publier vivent HORS du dépôt, dans
# .git/info/mots-prives (un mot par ligne) : la publication s'arrête si
# l'arbre en contient un. PULSE_NOTES=<fichier> ajoute un texte en tête des
# notes de la version ; PULSE_COAUTEUR="Nom <adresse>" signe le commit public
# d'une ligne Co-Authored-By.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?usage : outils/publie.sh <version>, par exemple 1.1}"
depot=Apocale/Pulse
distant=github

arret() { echo "publie.sh : $*" >&2; exit 1; }

[ "$(git branch --show-current)" = main ] || arret "le dépôt n'est pas sur main."
[ -z "$(git status --porcelain)" ] || arret "des modifications ne sont pas commitées."
git remote get-url "$distant" >/dev/null 2>&1 \
  || arret "pas de dépôt distant « $distant » : git remote add $distant https://github.com/$depot.git"
[ -x .git/hooks/pre-push ] || arret "le crochet .git/hooks/pre-push manque (docs/chantiers/20-partage.md)."
if gh release view "v$version" --repo "$depot" >/dev/null 2>&1; then arret "la version v$version existe déjà."; fi

# 1. Rien de privé dans ce qui part.
if [ -s .git/info/mots-prives ]; then
  if git grep -n -i -w -F -f .git/info/mots-prives main -- . ':!*.png'; then
    arret "l'arbre de main contient un mot privé (ci-dessus) : rien n'est publié."
  fi
fi

# 2. Les images de la page d'accueil suivent les rendus de référence.
for image in panneau-sombre panneau-clair carte-medias-sombre carte-medias-clair \
             carte-capteurs-sombre carte-capteurs-clair; do
  cmp -s "Tests/References/$image.png" ".github/images/$image.png" \
    || arret ".github/images/$image.png n'est plus le rendu de référence : le recopier depuis Tests/References, commiter."
done

# 3. Tout passe, puis le zip.
./verifie.sh --rapide >/dev/null || arret "./verifie.sh --rapide échoue : rien n'est publié."
outils/distribue.sh

# 4. Le commit public : l'arbre de main, au-dessus de la publication d'avant.
arbre=$(git rev-parse 'main^{tree}')
parent=$(git rev-parse -q --verify refs/heads/public || true)
if [ -n "$parent" ] && [ "$(git rev-parse "$parent^{tree}")" = "$arbre" ]; then
  commit=$parent
else
  # L'adresse « noreply » de GitHub, jamais celle de git config : elle est
  # professionnelle, et un commit public la montrerait.
  email=$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')
  message="Pulse $version"$'\n\n'"Le code de main ($(git rev-parse --short main)), sans son historique (outils/publie.sh)."
  [ -n "${PULSE_COAUTEUR:-}" ] && message+=$'\n\n'"Co-Authored-By: $PULSE_COAUTEUR"
  commit=$(GIT_AUTHOR_NAME=Isma GIT_AUTHOR_EMAIL="$email" GIT_COMMITTER_NAME=Isma GIT_COMMITTER_EMAIL="$email" \
           git commit-tree "$arbre" ${parent:+-p "$parent"} -m "$message")
  git update-ref refs/heads/public "$commit" ${parent:+"$parent"}
fi
# L'identification par `gh` (déjà connecté), le temps de cette poussée
# seulement : la configuration de git n'est pas touchée.
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' \
  push "$distant" refs/heads/public:refs/heads/main

# 5. La version, avec le zip et son empreinte.
empreinte=$(cut -d' ' -f1 .build/distribution/Pulse.zip.sha256)
notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
{
  [ -n "${PULSE_NOTES:-}" ] && { cat "$PULSE_NOTES"; echo; }
  cat <<NOTES
**Installer**, dans le Terminal :

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/$depot/main/installer.sh | bash
\`\`\`

Ou télécharge **Pulse.zip** ci-dessous, puis au premier lancement : Réglages Système › Confidentialité et sécurité › Ouvrir quand même.

Mac à puce Apple (M1 ou plus récent), macOS 14 Sonoma ou plus récent. SHA-256 de Pulse.zip : \`$empreinte\`
NOTES
} > "$notes"
gh release create "v$version" .build/distribution/Pulse.zip .build/distribution/Pulse.zip.sha256 \
  --repo "$depot" --target "$commit" --title "Pulse $version" --notes-file "$notes"
echo "→ https://github.com/$depot/releases/tag/v$version"
