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
  ok "COPY de server.xml neutralise"

  # Neutraliser server.xml retire aussi unpackWARs="true", que nous etions
  # seuls a declarer : les images officielles portent unpackWARs="false"
  # (verifie sur dhis2/core:2.35.14, server.xml ligne 153). Tomcat sert alors
  # l'application depuis l'archive, et DHIS2 echoue a resoudre ses JAR :
  #
  #   java.io.FileNotFoundException: URL cannot be resolved to absolute file
  #   path ... war:file:/usr/local/tomcat/webapps/ROOT.war*/WEB-INF/lib/...
  #
  # On corrige l'attribut dans le server.xml DE L'IMAGE plutot que d'imposer
  # le notre : une seule valeur change, et la configuration reste celle que la
  # version embarque - ce qui etait tout le propos de la neutralisation.
  cat >> docker/Dockerfile <<'DOCKERFILE'

# Palier de migration : retablir la decompression du WAR.
# Les images officielles portent unpackWARs="false" ; Tomcat sert alors
# l'application depuis l'archive et DHIS2 ne parvient pas a resoudre ses JAR.
# Cf. scripts/create-migration-branch.sh et docs/plan-migration.md.
USER root
RUN sed -i 's/unpackWARs="false"/unpackWARs="true"/' \
      /usr/local/tomcat/conf/server.xml \
 && grep -q 'unpackWARs="true"' /usr/local/tomcat/conf/server.xml
USER 1000
DOCKERFILE
  ok "unpackWARs retabli dans le server.xml de l'image"

  # Surcharge d'execution. Le nom n'est pas libre : Compose charge
  # docker-compose.override.yml automatiquement lorsqu'il est a cote du
  # fichier principal. Le pipeline le televerse s'il existe et efface celui de
  # la VM sinon : la branche suffit a determiner la configuration deployee.
  cat > docker/docker-compose.override.yml <<'OVERRIDE'
# =============================================================================
# docker-compose.override.yml - surcharge du palier de migration
#
# Charge AUTOMATIQUEMENT par Compose - aucune option -f a passer. Ce fichier
# n'existe que sur les branches migration/* ; sur main il est absent, et le
# pipeline efface celui qui subsisterait sur la VM.
#
# Un palier fait migrer le schema et ne recoit aucun trafic. Deux reglages de
# production l'empechent de demarrer :
#
#   read_only    Tomcat decompresse desormais ROOT.war dans webapps/, ce qu'une
#                racine en lecture seule interdit. La cible 2.41 n'a pas ce
#                besoin : son image livre l'application deja depliee.
#
#   healthcheck  /dhis-web-login/ n'existe pas dans les versions anciennes. La
#                sonde echouait sur un DHIS2 pourtant fonctionnel, et Nginx
#                refusait de demarrer derriere une dependance non saine.
# =============================================================================

services:
  dhis2:
    read_only: false
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:8080/api/system/info"]
      # Decompression du WAR puis migrations Flyway : compter large.
      start_period: 1200s
OVERRIDE
  ok "docker/docker-compose.override.yml cree"
else
  ok "COPY de server.xml conserve (--avec-server-xml)"
fi

git add docker/Dockerfile
[ -f docker/docker-compose.override.yml ] && git add docker/docker-compose.override.yml
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
