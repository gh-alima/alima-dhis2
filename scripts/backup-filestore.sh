#!/bin/sh
# =============================================================================
# backup-filestore.sh — sauvegarde du magasin de fichiers DHIS2
#
# POURQUOI CE SCRIPT EXISTE
#   Le dump PostgreSQL ne contient PAS les fichiers. Une base restaurée sans
#   son magasin de fichiers référence des documents introuvables : pièces
#   jointes, images, ressources. Les deux se sauvegardent ensemble et se
#   testent ensemble.
#
# Exécuté dans un conteneur, le volume dhis2-files monté en LECTURE SEULE :
#   docker compose --profile backup run --rm backup-filestore
#
# Planification hebdomadaire (crontab de la VM) :
#   0 2 * * 0 cd /opt/alima/dhis2 && docker compose --profile backup run --rm backup-filestore
# =============================================================================
set -eu

SOURCE_DIR="${SOURCE_DIR:-/data}"
BACKUP_BUCKET="${BACKUP_BUCKET:?BACKUP_BUCKET est obligatoire}"
BACKUP_PREFIX="${BACKUP_PREFIX:-filestore}"

TIMESTAMP="$(date -u +%Y-%m-%dT%H-%M-%S_UTC)"
ARCHIVE="/tmp/${BACKUP_PREFIX}_${TIMESTAMP}.tar.gz"

if [ ! -d "${SOURCE_DIR}" ]; then
  echo "ERREUR : ${SOURCE_DIR} introuvable." >&2
  exit 1
fi

echo "=== Sauvegarde du magasin de fichiers ==="
echo "Source      : ${SOURCE_DIR}"
echo "Destination : ${BACKUP_BUCKET}/${BACKUP_PREFIX}/"

SIZE="$(du -sh "${SOURCE_DIR}" 2>/dev/null | cut -f1)"
COUNT="$(find "${SOURCE_DIR}" -type f 2>/dev/null | wc -l)"
echo "Volumétrie  : ${SIZE} — ${COUNT} fichiers"

# Un magasin vide est suspect : mieux vaut le signaler que de pousser une
# archive vide qui donnerait l'illusion d'une sauvegarde valide.
if [ "${COUNT}" -eq 0 ]; then
  echo "ATTENTION : le magasin de fichiers est vide." >&2
  echo "            Vérifier que le volume dhis2-files est bien monté." >&2
fi

echo "Création de l'archive..."
tar czf "${ARCHIVE}" -C "${SOURCE_DIR}" .

ARCHIVE_SIZE="$(du -sh "${ARCHIVE}" | cut -f1)"
echo "Archive     : ${ARCHIVE_SIZE}"

echo "Transfert vers Cloud Storage..."
gcloud storage cp "${ARCHIVE}" "${BACKUP_BUCKET}/${BACKUP_PREFIX}/"

rm -f "${ARCHIVE}"

echo ""
echo "=== Sauvegarde terminée ==="
echo "${BACKUP_BUCKET}/${BACKUP_PREFIX}/$(basename "${ARCHIVE}")"
echo ""
echo "Rappel : la sauvegarde n'a de valeur que si sa restauration est testée."
echo "         Test de restauration semestriel prévu au contrat de support."
