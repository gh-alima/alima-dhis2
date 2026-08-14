#!/bin/sh
# =============================================================================
# restore-filestore.sh — restauration du magasin de fichiers DHIS2
#
# ⚠ OPÉRATION DESTRUCTIVE : le contenu actuel du volume dhis2-files est
#   remplacé. Arrêter DHIS2 avant de lancer la restauration.
#
# Usage :
#   docker compose stop dhis2
#   RESTORE_ARCHIVE=filestore_2026-03-15T02-00-00_UTC.tar.gz \
#     docker compose --profile restore run --rm restore-filestore
#   docker compose start dhis2
#
# Sans RESTORE_ARCHIVE, le script liste les archives disponibles et s'arrête.
# =============================================================================
set -eu

TARGET_DIR="${TARGET_DIR:-/data}"
BACKUP_BUCKET="${BACKUP_BUCKET:?BACKUP_BUCKET est obligatoire}"
BACKUP_PREFIX="${BACKUP_PREFIX:-filestore}"
RESTORE_ARCHIVE="${RESTORE_ARCHIVE:-}"

if [ -z "${RESTORE_ARCHIVE}" ]; then
  echo "Aucune archive indiquée. Archives disponibles :"
  echo ""
  gcloud storage ls "${BACKUP_BUCKET}/${BACKUP_PREFIX}/" || true
  echo ""
  echo "Relancer avec : RESTORE_ARCHIVE=<nom-de-l-archive>"
  exit 1
fi

SOURCE="${BACKUP_BUCKET}/${BACKUP_PREFIX}/${RESTORE_ARCHIVE}"
LOCAL="/tmp/${RESTORE_ARCHIVE}"

echo "=== Restauration du magasin de fichiers ==="
echo "Archive : ${SOURCE}"
echo "Cible   : ${TARGET_DIR}"
echo ""

EXISTING="$(find "${TARGET_DIR}" -type f 2>/dev/null | wc -l)"
if [ "${EXISTING}" -gt 0 ]; then
  echo "⚠ ${TARGET_DIR} contient déjà ${EXISTING} fichiers."
  echo "  Ils seront écrasés par le contenu de l'archive."
  echo ""
fi

echo "Téléchargement..."
gcloud storage cp "${SOURCE}" "${LOCAL}"

echo "Extraction..."
tar xzf "${LOCAL}" -C "${TARGET_DIR}"
rm -f "${LOCAL}"

RESTORED="$(find "${TARGET_DIR}" -type f 2>/dev/null | wc -l)"
echo ""
echo "=== Restauration terminée — ${RESTORED} fichiers ==="
echo ""
echo "À vérifier ensuite :"
echo "  1. Redémarrer DHIS2 : docker compose start dhis2"
echo "  2. Ouvrir quelques pièces jointes depuis l'application — la cohérence"
echo "     entre les références en base et les fichiers restaurés ne se voit"
echo "     qu'à l'usage."
