#!/usr/bin/env bash
# =============================================================================
# import-dump.sh — importe un export pg_dump SQL depuis Cloud Storage
#
# Pourquoi ne pas utiliser « gcloud sql import sql » : l'import natif rejoue le
# fichier tel quel et échoue sur
#
#   ERROR: must be owner of extension plpgsql
#
# pg_dump écrit un « COMMENT ON EXTENSION » après chaque « CREATE EXTENSION ».
# Commenter une extension exige d'en être propriétaire — or plpgsql appartient
# au superutilisateur interne, que Cloud SQL n'accorde à personne. Ces deux
# lignes sont sans effet fonctionnel : elles ne portent qu'un libellé.
#
# Les retirer d'un fichier de 24 Go supposerait de le décompresser, le filtrer,
# le recompresser et le renvoyer — plusieurs heures pour deux lignes. Le flux
# est donc filtré à la volée, sans jamais écrire le fichier sur disque.
#
# À exécuter SUR LA VM, en root. L'import dure des heures : le lancer sous
# nohup, sinon une déconnexion SSH l'interrompt.
#
#   sudo nohup /opt/alima/dhis2/scripts/import-dump.sh \
#     gs://alima-dhis2-prod-dhis2-backups/import/dhis-2.35.sql.gz \
#     > /var/log/dhis2-import.log 2>&1 &
#
#   tail -f /var/log/dhis2-import.log
# =============================================================================
set -euo pipefail

GCS_URI="${1:-}"
APP_DIR="${2:-/opt/alima/dhis2}"
PG_CLIENT_IMAGE="${PG_CLIENT_IMAGE:-postgres:16-alpine}"
FORCE="${FORCE:-0}"

[ "$(id -u)" -eq 0 ] || { echo "Ce script doit être exécuté en root." >&2; exit 1; }

if [ -z "${GCS_URI}" ]; then
  echo "Usage : $0 gs://bucket/chemin/export.sql.gz [répertoire_applicatif]" >&2
  exit 1
fi

[ -f "${APP_DIR}/.env" ] || { echo "ERREUR : ${APP_DIR}/.env introuvable." >&2; exit 1; }
set -a; . "${APP_DIR}/.env"; set +a

_psql() {
  docker run --rm -i \
    -e PGPASSWORD="${DHIS2_DATABASE_PASSWORD}" \
    "${PG_CLIENT_IMAGE}" \
    psql -h "${DHIS2_DATABASE_HOST}" -p "${DHIS2_DATABASE_PORT:-5432}" \
         -U "${DHIS2_DATABASE_USER}" -d "${DHIS2_DATABASE_NAME}" "$@"
}

echo "=== Import ==="
echo "  source : ${GCS_URI}"
echo "  cible  : ${DHIS2_DATABASE_NAME}@${DHIS2_DATABASE_HOST}"
echo "  début  : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# Une base non vide fait échouer l'import sur des conflits de clés, des dizaines
# de milliers de lignes plus loin. Mieux vaut refuser tout de suite.
NB=$(_psql -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null | tr -d '[:space:]')
if [ "${NB:-0}" != "0" ] && [ "${FORCE}" != "1" ]; then
  echo "ERREUR : la base ${DHIS2_DATABASE_NAME} contient déjà ${NB} tables." >&2
  echo "" >&2
  echo "  Importer par-dessus produirait des conflits de clés, révélés très tard." >&2
  echo "  Repartir d'une base vide :" >&2
  echo "" >&2
  echo "    gcloud sql databases delete ${DHIS2_DATABASE_NAME} --instance=<instance>" >&2
  echo "    gcloud sql databases create ${DHIS2_DATABASE_NAME} --instance=<instance>" >&2
  echo "" >&2
  echo "  Ou forcer, en connaissance de cause : FORCE=1 $0 ..." >&2
  exit 1
fi

DEBUT=$(date +%s)

# gcloud storage cat diffuse l'objet sans l'écrire sur disque — le disque de la
# VM ne suffirait pas. Le sed retire les deux COMMENT ON EXTENSION.
#
# ON_ERROR_STOP=1 : sans lui, psql poursuivrait après une erreur et laisserait
# une base incomplète en signalant un succès.
gcloud storage cat "${GCS_URI}" \
  | gunzip \
  | sed -e '/^COMMENT ON EXTENSION /d' \
  | _psql -v ON_ERROR_STOP=1 --quiet

FIN=$(date +%s)
DUREE=$(( FIN - DEBUT ))

echo ""
echo "=== Import terminé ==="
printf '  durée : %02dh %02dm %02ds\n' $(( DUREE/3600 )) $(( (DUREE%3600)/60 )) $(( DUREE%60 ))
echo "  fin   : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

echo "=== Contrôle ==="
_psql -c "SELECT count(*) AS tables FROM information_schema.tables WHERE table_schema='public';"
_psql -c "SELECT pg_size_pretty(pg_database_size(current_database())) AS taille;"
_psql -c "SELECT extname FROM pg_extension ORDER BY extname;"

echo ""
echo "Noter la durée ci-dessus : c'est la principale composante de la fenêtre"
echo "de bascule à annoncer."
