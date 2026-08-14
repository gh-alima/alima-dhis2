#!/usr/bin/env bash
# =============================================================================
# init-database.sh — prépare la base PostgreSQL pour DHIS2
#
# Crée les extensions dont DHIS2 a besoin. Sans elles, le démarrage échoue —
# et l'erreur remonte sous forme d'exception Hibernate, qui ne désigne pas la
# cause réelle.
#
#   postgis    fonctions cartographiques. DHIS2 tente de la créer lui-même au
#              démarrage, mais échoue si le compte applicatif n'en a pas le
#              droit. On ne dépend pas de cette tentative.
#   btree_gin  index trigrammes composés — requis depuis DHIS2 2.38
#   pg_trgm    recherche par trigrammes  — requis depuis DHIS2 2.38
#
# Référence :
#   https://docs.dhis2.org/en/manage/getting-started/manual-install-on-ubuntu.html
#
# Exécuté SUR LA VM, en root : c'est le seul point du dispositif qui atteigne
# Cloud SQL, la base n'ayant qu'une adresse privée. Le client psql passe par un
# conteneur, pour ne rien installer de plus sur la VM.
#
# IDEMPOTENT : « IF NOT EXISTS » sur chaque extension. Le script est rejoué à
# chaque déploiement — une base restaurée depuis une sauvegarde, ou recréée,
# retrouve ainsi ses extensions sans intervention.
#
# Usage : init-database.sh [répertoire_applicatif]
# =============================================================================
set -euo pipefail

APP_DIR="${1:-/opt/alima/dhis2}"
PG_CLIENT_IMAGE="${PG_CLIENT_IMAGE:-postgres:16-alpine}"

[ "$(id -u)" -eq 0 ] || { echo "Ce script doit être exécuté en root." >&2; exit 1; }
[ -f "${APP_DIR}/.env" ] || { echo "ERREUR : ${APP_DIR}/.env introuvable." >&2; exit 1; }

# Le .env est en 600 propriété de root : le sourcer ici évite de faire circuler
# le mot de passe en argument de commande, où il apparaîtrait dans la liste des
# processus.
set -a
# shellcheck disable=SC1091
. "${APP_DIR}/.env"
set +a

for _v in DHIS2_DATABASE_HOST DHIS2_DATABASE_NAME DHIS2_DATABASE_USER DHIS2_DATABASE_PASSWORD; do
  if [ -z "$(eval "echo \${${_v}:-}")" ]; then
    echo "ERREUR : ${_v} absent de ${APP_DIR}/.env" >&2
    exit 1
  fi
done

echo "Base : ${DHIS2_DATABASE_NAME} sur ${DHIS2_DATABASE_HOST}"

_psql() {
  docker run --rm \
    -e PGPASSWORD="${DHIS2_DATABASE_PASSWORD}" \
    "${PG_CLIENT_IMAGE}" \
    psql -h "${DHIS2_DATABASE_HOST}" \
         -p "${DHIS2_DATABASE_PORT:-5432}" \
         -U "${DHIS2_DATABASE_USER}" \
         -d "${DHIS2_DATABASE_NAME}" \
         -v ON_ERROR_STOP=1 -q "$@"
}

echo ""
echo "=== Création des extensions ==="
for EXT in postgis btree_gin pg_trgm; do
  printf '  %-10s ' "${EXT}"
  if _psql -c "CREATE EXTENSION IF NOT EXISTS ${EXT};" >/dev/null 2>/tmp/ext-err.txt; then
    echo "OK"
  else
    echo "ÉCHEC"
    echo "" >&2
    echo "  Réponse de PostgreSQL :" >&2
    sed 's/^/    /' /tmp/ext-err.txt >&2
    echo "" >&2
    echo "  Sur Cloud SQL, la création d'extensions demande le rôle" >&2
    echo "  cloudsqlsuperuser. Les comptes créés par « gcloud sql users create »" >&2
    echo "  l'ont par défaut ; un compte créé en SQL ne l'a pas." >&2
    rm -f /tmp/ext-err.txt
    exit 1
  fi
done
rm -f /tmp/ext-err.txt

echo ""
echo "=== Extensions installées ==="
_psql -c "SELECT extname, extversion FROM pg_extension ORDER BY extname;"
