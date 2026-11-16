#!/usr/bin/env bash
# Crée un snapshot public propre d'OpenAguja : contenu tracké de HEAD
# sans aucun historique git (l'historique du dépôt de travail contient
# des commits signés avec l'email professionnel — il ne doit JAMAIS
# être publié).
#
# Le snapshot obtenu est un dépôt git neuf, branche main, un seul
# commit « Initial public release », identité noreply GitHub.
#
# Usage : scripts/make-public-snapshot.sh <dest-dir>
# Puis :  cd <dest-dir> && scripts/public-check.sh   (doit passer)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

DEST="${1:?usage: $0 <dest-dir>}"
[[ -e "$DEST" ]] && { echo "❌ $DEST existe déjà" >&2; exit 1; }
BRANCH=$(git rev-parse --abbrev-ref HEAD)

echo "== archive du contenu tracké (HEAD de $BRANCH) =="
mkdir -p "$DEST"
git archive HEAD | tar -x -C "$DEST"

cd "$DEST"
git init -b main -q
git add -A
# Identité noreply GitHub — locale à CE dépôt uniquement, la config
# globale de la machine n'est pas touchée.
git -c user.name="Hougo" \
    -c user.email="15942149+hquezser@users.noreply.github.com" \
    commit -q -m "Initial public release of OpenAguja"

echo
echo "Snapshot créé : $DEST"
echo "Branche : main — 1 commit, arbre = HEAD de $BRANCH"
echo
echo "== vérification privacy sur le snapshot =="
# La copie dans le snapshot se replace dans SA propre racine.
"$DEST/scripts/public-check.sh" || {
    echo "❌ Le snapshot contient des motifs interdits — corriger avant publication." >&2
    exit 1
}

echo
echo "Prochaines étapes :"
echo "  1. Relire la liste des fichiers :  git -C \"$DEST\" ls-files"
echo "  2. Créer le dépôt https://github.com/new (public, sans README)"
echo "  3. cd \"$DEST\" && git remote add origin git@github.com:hquezser/openaguja.git"
echo "     && git push -u origin main"
