#!/usr/bin/env bash
# =============================================================================
# list-palier-images.sh — resout le tag le plus recent de chaque version
#
# Le jour de la bascule, la migration se rejoue palier par palier. Encore
# faut-il savoir quelle image deployer pour chaque version.
#
# Une table de tags recopiee dans la documentation se perime des la premiere
# reconstruction — c'est arrive une fois. Ce script interroge le registre :
# il ne peut pas mentir.
#
# Les versions sont deduites des branches migration/*, plus la cible declaree
# dans le Dockerfile de main. Ajouter un palier suffit a le faire apparaitre.
#
# Usage :
#   ./scripts/list-palier-images.sh
#   PROJECT=autre-projet ./scripts/list-palier-images.sh
# =============================================================================
set -euo pipefail

PROJECT="${PROJECT:-alima-dhis2-prod}"
IMAGE="${IMAGE:-europe-west1-docker.pkg.dev/${PROJECT}/dhis2-images/dhis2-core}"

command -v gcloud > /dev/null || { echo "gcloud est requis." >&2; exit 1; }

# Versions des paliers, dans l'ordre de la montee.
VERSIONS=$(git branch -r --list 'origin/migration/*' 2>/dev/null \
           | sed 's|.*origin/migration/||' | tr -d ' ' | sort -V)

# Cible : lue dans le Dockerfile de main, seul endroit ou elle est declaree.
CIBLE=$(git show main:docker/Dockerfile 2>/dev/null \
        | sed -n 's/^ARG DHIS2_VERSION=//p' | head -1)

echo "Registre : ${IMAGE}"
echo ""

TAGS=$(gcloud artifacts docker images list "${IMAGE}" \
         --include-tags --format='value(tags)' --project="${PROJECT}" 2>/dev/null \
       | tr ',' '\n' | tr -d ' ' | grep -v '^$' | sort) || {
  echo "ERREUR : registre illisible. Verifier le projet et les droits." >&2
  exit 1
}

MANQUANTS=0
for V in ${VERSIONS} ${CIBLE}; do
  # Les points de la version sont des metacaracteres : les echapper.
  MOTIF=$(printf '%s' "${V}" | sed 's/\./\./g')
  # Le tag vaut <version>.<date>.<seq>.<commit> : l'ordre lexicographique
  # suffit a designer le plus recent, date et sequence etant de largeur fixe.
  DERNIER=$(printf '%s\n' "${TAGS}" | grep "^${MOTIF}\." | tail -1 || true)

  if [ -z "${DERNIER}" ]; then
    printf '  %-12s  ABSENT DU REGISTRE — a reconstruire\n' "${V}"
    MANQUANTS=$((MANQUANTS + 1))
  else
    MARQUE=""
    [ "${V}" = "${CIBLE}" ] && MARQUE="  <- cible"
    printf '  %-12s  %s%s\n' "${V}" "${DERNIER}" "${MARQUE}"
  fi
done

echo ""
if [ "${MANQUANTS}" -gt 0 ]; then
  echo "${MANQUANTS} image(s) manquante(s). Reconstruire depuis la branche concernee :"
  echo "  git checkout migration/<version>"
  echo "  gcloud builds submit --config=cloudbuild.yaml \\"
  echo "    --substitutions=_VCS_REF=\$(git rev-parse --short HEAD) --project=${PROJECT}"
  exit 1
fi
echo "Toutes les images sont presentes."
