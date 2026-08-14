#!/usr/bin/env bash
# =============================================================================
# render-env.sh — génère le fichier .env de la VM depuis Secret Manager
#
# Exécuté SUR LA VM par le pipeline de déploiement. Les secrets sont lus par la
# VM avec son propre compte de service : ils ne transitent jamais par Cloud
# Build ni par le dépôt.
#
# Il n'existe qu'un seul environnement hébergé — la production. La validation
# se fait en local (docker compose --profile local), avec un .env rédigé à la
# main depuis docker/.env.example.
#
# Usage :
#   render-env.sh --tag <image-tag> --registry <host/projet/dépôt> \
#                 --output /opt/alima/dhis2/.env
# =============================================================================
set -euo pipefail

IMAGE_TAG=""
REGISTRY=""
OUTPUT="/opt/alima/dhis2/.env"

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)      IMAGE_TAG="$2";   shift 2 ;;
    --registry) REGISTRY="$2";    shift 2 ;;
    --output)   OUTPUT="$2";      shift 2 ;;
    # Accepté et ignoré : conserve la compatibilité avec d'anciens appels.
    --env)      shift 2 ;;
    *) echo "Paramètre inconnu : $1" >&2; exit 1 ;;
  esac
done

if [ -z "${IMAGE_TAG}" ]; then
  echo "ERREUR : --tag est obligatoire." >&2
  exit 1
fi
if [ -z "${REGISTRY}" ]; then
  echo "ERREUR : --registry est obligatoire." >&2
  exit 1
fi

secret() {
  gcloud secrets versions access latest --secret="$1" 2>/dev/null || {
    echo "ERREUR : secret introuvable ou inaccessible : $1" >&2
    exit 1
  }
}

echo "Génération de ${OUTPUT} (production, tag ${IMAGE_TAG})"

DB_HOST="$(secret dhis2-db-host)"
DB_USER="$(secret dhis2-db-user)"
DB_PASSWORD="$(secret dhis2-db-password)"
ENCRYPTION_PASSWORD="$(secret dhis2-encryption-password)"
FQDN="$(secret dhis2-fqdn)"

# Le fichier contient des secrets en clair : permissions restreintes AVANT
# d'écrire quoi que ce soit dedans.
umask 077
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

cat > "${TMP}" <<EOF
# Fichier généré par render-env.sh le $(date -u +%Y-%m-%dT%H:%M:%SZ)
# NE PAS MODIFIER À LA MAIN — régénéré à chaque déploiement.
# Environnement : production

REGISTRY=${REGISTRY}
IMAGE_TAG=${IMAGE_TAG}

DHIS2_DATABASE_HOST=${DB_HOST}
DHIS2_DATABASE_PORT=5432
DHIS2_DATABASE_NAME=dhis2
DHIS2_DATABASE_USER=${DB_USER}
DHIS2_DATABASE_PASSWORD=${DB_PASSWORD}
DHIS2_DB_WAIT_TIMEOUT=120

DHIS2_CONNECTION_POOL_MAX_SIZE=40
DHIS2_CONNECTION_POOL_MAX_IDLE_TIME=7200000
DHIS2_CONNECTION_POOL_TIMEOUT=30000
DHIS2_CONNECTION_POOL_VALIDATION_TIMEOUT=5000
DHIS2_DB_POOL_TYPE=hikari

DHIS2_FQDN=${FQDN}
DHIS2_CONTEXT_PATH=/
DHIS2_SERVER_HTTPS=on

DHIS2_SYSTEM_READ_ONLY_MODE=off
DHIS2_SYSTEM_SESSION_TIMEOUT=3600
DHIS2_SQL_VIEW_TABLE_PROTECTION=on
DHIS2_SQL_VIEW_WRITE_ENABLED=off
DHIS2_SERVER_SIDE_PROGRAM_RULE_EXECUTION=on
DHIS2_SYSTEM_CACHE_MAX_SIZE_FACTOR=0.5
DHIS2_SYSTEM_UPDATE_NOTIFICATIONS=on

DHIS2_ENCRYPTION_PASSWORD=${ENCRYPTION_PASSWORD}

DHIS2_SSO_OPENID_ACTIVATED=false

DHIS2_METRICS_ACTIVE=true
DHIS2_MONITORING_API=on
DHIS2_MONITORING_JVM=on
DHIS2_MONITORING_HIBERNATE=off
DHIS2_MONITORING_DBPOOL=on
DHIS2_MONITORING_UPTIME=on
DHIS2_MONITORING_CPU=on

DHIS2_REDIS_ENABLED=false
DHIS2_ANALYTICS_DB_ACTIVATED=false

# Magasin de fichiers sur disque — volume dhis2-files.
DHIS2_FILESTORE_PROVIDER=filesystem

DHIS2_LOGGING_FILE_MAX_SIZE=100MB
DHIS2_LOGGING_FILE_MAX_ARCHIVES=5
DHIS2_LOGGING_QUERY=off
DHIS2_LOGGING_QUERY_SLOW_THRESHOLD=1000
DHIS2_LOGGING_SESSION_ID=on
DHIS2_LOGGING_LEVEL_DHIS=INFO
DHIS2_LOGGING_LEVEL_SPRING=WARN

DHIS2_APPHUB_BASE_URL=https://apps.dhis2.org
DHIS2_APPHUB_API_URL=https://apps.dhis2.org/api

DHIS2_MAX_SESSIONS_PER_USER=10
DHIS2_MAX_RAM_PERCENTAGE=80.0

TZ=UTC
DEBUG=false
INSECURE=false

TLS_CERT_DIR=/etc/letsencrypt
BACKUP_BUCKET=gs://$(gcloud config get-value project 2>/dev/null)-dhis2-backups
EOF

install -m 600 "${TMP}" "${OUTPUT}"
echo "${OUTPUT} généré ($(wc -l < "${OUTPUT}") lignes, permissions 600)."
