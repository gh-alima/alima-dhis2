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

  # Correctifs de palier ajoutes au Dockerfile. Ils repondent a des ecarts
  # RELEVES sur les images officielles, non supposes :
  #   - 2.35.14 livre ROOT.war et un repertoire ROOT vide ; Tomcat sert le vide
  #   - 2.37.10 ne livre pas d archive du tout, ROOT y est deja depliee
  #   - curl manque en 2.35.14, unzip manque en 2.37.10
  # D ou des tests a chaque etape. Cf. docs/plan-migration.md.
  cat >> docker/Dockerfile <<'DOCKERFILE'

# Preparer l'application deployee par Tomcat.
#
# Les images de la ligne DHIS2 ne sont PAS homogenes — releve, pas suppose :
#
#   2.35.14   ROOT.war + un repertoire ROOT VIDE. Tomcat voit un contexte deja
#             deploye, ne deplie jamais l'archive, et sert le vide en 500 ms.
#             (unpackWARs="false" dans son server.xml, ligne 153.)
#   2.37.10   aucune archive : ROOT est deja depliee. Rien a faire.
#
# D'ou des tests plutot que des hypotheses. Deplier a la construction rend le
# resultat deterministe, accelere le demarrage et evite au conteneur d'ecrire
# dans webapps. Le controle final vaut pour les deux cas : il porte sur le JAR
# dont l'absence provoquait l'echec d'origine
# (« URL cannot be resolved to absolute file path ... war:file: »).
RUN cd /usr/local/tomcat/webapps  && if [ -f ROOT.war ]; then         command -v unzip > /dev/null      || { apt-get update        && apt-get install -y --no-install-recommends unzip        && rm -rf /var/lib/apt/lists/*; } ;         rm -rf ROOT && mkdir ROOT && cd ROOT      && unzip -q ../ROOT.war      && rm -f ../ROOT.war ;     fi  && ls /usr/local/tomcat/webapps/ROOT/WEB-INF/lib/dhis-service-setting-*.jar  && chown -R 1000:1000 /usr/local/tomcat/webapps

# curl, requis par la sonde de disponibilite. Absent de 2.35.14 (comme wget et
# nc), present dans 2.37.10 : la encore, on teste. Sans lui le conteneur reste
# indefiniment "health: starting" alors que DHIS2 fonctionne.
RUN command -v curl > /dev/null  || { apt-get update    && apt-get install -y --no-install-recommends curl    && rm -rf /var/lib/apt/lists/*; }  && curl --version | head -1

# Connecteur AJP : inutilise - Nginx parle HTTP - et refuse par Tomcat 8.5
# faute de secret, ce qui produit un SEVERE a chaque demarrage. Le retirer
# supprime un message trompeur et une surface d'attaque connue (Ghostcat).
# Notre server.xml, utilise par la cible 2.41, n'en declare aucun.
RUN sed -i '/protocol="AJP\/1.3"/d' /usr/local/tomcat/conf/server.xml
# Connecteur AJP : inutilise - Nginx parle HTTP - et refuse par Tomcat 8.5
# faute de secret, ce qui produit un SEVERE trompeur a chaque demarrage.
# Notre server.xml, utilise par la cible 2.41, n en declare aucun.
RUN sed -i '/protocol="AJP\/1.3"/d' /usr/local/tomcat/conf/server.xml

USER 1000
DOCKERFILE
  ok "correctifs de palier ajoutes au Dockerfile"

  # Surcharge d execution. Le nom n est pas libre : Compose charge
  # docker-compose.override.yml automatiquement lorsqu il est a cote du
  # fichier principal. Le pipeline le televerse s il existe et efface celui de
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
#   healthcheck  /dhis-web-login/ n'existe pas dans les versions anciennes.
#                Releve sur 2.35 : seul /dhis-web-commons/security/login.action
#                repond 200, tout le reste redirige en 302. On sonde donc
#                /api/system/ping, present dans toutes les versions, et l'on
#                accepte son 302 : une application vide renverrait 404, ce qui
#                est precisement le cas a detecter. Tant que Flyway travaille,
#                le contexte n'est pas demarre et la sonde reste rouge.
# =============================================================================

services:
  dhis2:
    read_only: false
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:8080/api/system/ping"]
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
