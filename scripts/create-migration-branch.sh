#!/usr/bin/env bash
# =============================================================================
# create-migration-branch.sh — crée la branche d'un palier de migration
#
# La montée de 2.35 vers 2.41 se fait par paliers : chaque version intermédiaire
# applique ses propres migrations Flyway sur la base, et doit être validée avant
# de passer à la suivante. Une branche par palier donne à chacun une image
# traçable, construite par la même chaîne que la cible.
#
# La branche ne diffère de main que par deux points :
#
#   1. ARG DHIS2_VERSION pointe sur le palier ;
#   2. la surcouche server.xml est NEUTRALISÉE.
#
# Le second point mérite explication. server.xml vise Tomcat 9/10 et Java 17,
# alors que les images des premiers paliers reposent sur Tomcat 8.5 et Java 11.
# Or un palier ne sert qu'à faire migrer le schéma : il ne reçoit aucun trafic,
# n'a pas besoin du réglage fin du connecteur, ni de la restitution d'IP client.
# Le neutraliser sur TOUS les paliers évite d'avoir à vérifier, version par
# version, quelle mouture de Tomcat est embarquée.
#
# Usage :
#   ./scripts/create-migration-branch.sh 2.38.7.0
#   ./scripts/create-migration-branch.sh 2.38.7.0 --avec-server-xml
#   DRY_RUN=1 ./scripts/create-migration-branch.sh 2.38.7.0
# =============================================================================
set -euo pipefail

VERSION="${1:-}"
AVEC_SERVER_XML=0
[ "${2:-}" = "--avec-server-xml" ] && AVEC_SERVER_XML=1

BASE_BRANCH="${BASE_BRANCH:-main}"
DRY_RUN="${DRY_RUN:-0}"
BRANCHE="migration/${VERSION}"

log() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()  { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }

if [ -z "${VERSION}" ]; then
  echo "Usage : $0 <version> [--avec-server-xml]" >&2
  echo "Exemple : $0 2.38.7.0" >&2
  exit 1
fi

# Le format doit correspondre à un tag dhis2/core, sans quoi la construction
# échouera bien plus tard, au « docker pull » de l'image de base.
if ! echo "${VERSION}" | grep -qE '^2\.[0-9]+(\.[0-9]+){1,2}$'; then
  echo "ERREUR : version « ${VERSION} » inattendue." >&2
  echo "  Format attendu : 2.38.7.0, 2.35.14, 2.41.9.1" >&2
  exit 1
fi

# Une branche se crée depuis un arbre propre : sinon les modifications en cours
# la suivraient sans qu'on l'ait voulu.
if [ -n "$(git status --porcelain)" ]; then
  echo "ERREUR : l'arbre de travail contient des modifications non validées." >&2
  git status --short >&2
  exit 1
fi

if git show-ref --verify --quiet "refs/heads/${BRANCHE}"; then
  echo "La branche ${BRANCHE} existe déjà — rien à faire." >&2
  exit 0
fi

log "Palier ${VERSION} — branche ${BRANCHE} depuis ${BASE_BRANCH}"

if [ "${DRY_RUN}" = "1" ]; then
  echo "  [dry-run] git checkout -b ${BRANCHE} ${BASE_BRANCH}"
  echo "  [dry-run] ARG DHIS2_VERSION=${VERSION}"
  [ "${AVEC_SERVER_XML}" = "0" ] && echo "  [dry-run] neutralisation du COPY de server.xml"
  echo "  [dry-run] commit puis retour sur ${BASE_BRANCH}"
  exit 0
fi

DEPART=$(git rev-parse --abbrev-ref HEAD)
git checkout -q -b "${BRANCHE}" "${BASE_BRANCH}"

sed -i "s|^ARG DHIS2_VERSION=.*|ARG DHIS2_VERSION=${VERSION}|" docker/Dockerfile
ok "ARG DHIS2_VERSION=${VERSION}"

if [ "${AVEC_SERVER_XML}" = "0" ]; then
  sed -i "s|^COPY docker/server.xml |# Palier de migration : surcouche Tomcat neutralisée (cf. create-migration-branch.sh)\n# COPY docker/server.xml |" docker/Dockerfile
  ok "COPY de server.xml neutralisé"
else
  ok "COPY de server.xml conservé (--avec-server-xml)"
fi

git add docker/Dockerfile
git commit -q -F- <<EOF
migration: palier DHIS2 ${VERSION}

Branche dédiée au palier ${VERSION} de la montée 2.35 → 2.41. Elle ne diffère
de ${BASE_BRANCH} que par la version de l'image de base$([ "${AVEC_SERVER_XML}" = "0" ] && echo " et par la
neutralisation de la surcouche server.xml, qui vise Tomcat 9/10 alors que les
paliers anciens reposent sur Tomcat 8.5. Un palier ne recevant aucun trafic,
le réglage fin du connecteur n'y a pas d'objet")".

Construction depuis cette branche :
  gcloud builds submit --config=cloudbuild.yaml \\
    --substitutions=_VCS_REF=\$(git rev-parse --short HEAD) \\
    --project=alima-dhis2-prod
EOF

ok "Commit créé sur ${BRANCHE}"
git checkout -q "${DEPART}"
ok "Retour sur ${DEPART}"
