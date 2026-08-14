#!/usr/bin/env bash
# =============================================================================
# 99-cleanup-gcp.sh — suppression de l'infrastructure DHIS2 ALIMA
#
# ⚠⚠⚠  SCRIPT DESTRUCTIF  ⚠⚠⚠
#
# Supprime la VM, la base Cloud SQL, le registre d'images et le réseau.
# Destiné aux environnements de test et au démontage de fin de projet.
#
# NE JAMAIS L'EXÉCUTER SUR LA PRODUCTION SANS SAUVEGARDE VÉRIFIÉE.
#
# Trois garde-fous :
#   - confirmation par saisie du nom du projet ;
#   - le bucket de sauvegardes n'est JAMAIS supprimé automatiquement ;
#   - --keep-data préserve base et sauvegardes (ne détruit que le calcul).
#
# Usage :
#   ./scripts/99-cleanup-gcp.sh                 # tout sauf les sauvegardes
#   ./scripts/99-cleanup-gcp.sh --keep-data     # VM et registre uniquement
#   DRY_RUN=1 ./scripts/99-cleanup-gcp.sh       # affiche sans exécuter
# =============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-alima-dhis2-prod}"
REGION="${REGION:-europe-west1}"
ZONE="${ZONE:-europe-west1-b}"

VPC_NAME="vpc-dhis2"
SUBNET_NAME="subnet-dhis2"
PSA_RANGE_NAME="google-managed-services-${VPC_NAME}"
SQL_INSTANCE="pg16-dhis2-prod"
AR_REPO="dhis2-images"
VM_NAME="vm-dhis2-app"
VM_IP_NAME="ip-dhis2-app"
BACKUP_BUCKET="${PROJECT_ID}-dhis2-backups"

KEEP_DATA=0
[ "${1:-}" = "--keep-data" ] && KEEP_DATA=1

DRY_RUN="${DRY_RUN:-0}"

log()  { printf '\n\033[1;31m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
skip() { printf '  \033[0;33m•\033[0m %s\n' "$*"; }

run() {
  if [ "${DRY_RUN}" = "1" ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@" || skip "échec ou ressource absente : $*"
  fi
}

# ── Confirmation ─────────────────────────────────────────────────────────────
cat <<EOF

  ╔════════════════════════════════════════════════════════════════╗
  ║                     SUPPRESSION D'INFRASTRUCTURE               ║
  ╚════════════════════════════════════════════════════════════════╝

  Projet : ${PROJECT_ID}

  Seront supprimés :
    - VM ${VM_NAME} et ses volumes Docker (magasin de fichiers inclus)
    - Dépôt d'images ${AR_REPO} et toutes ses images
    - Réseau ${VPC_NAME}, règles de pare-feu, peering
EOF

if [ "${KEEP_DATA}" = "1" ]; then
  cat <<EOF
    - Base Cloud SQL ${SQL_INSTANCE} : PRÉSERVÉE (--keep-data)
EOF
else
  cat <<EOF
    - Base Cloud SQL ${SQL_INSTANCE} : SUPPRIMÉE, avec toutes ses données
EOF
fi

cat <<EOF

  PRÉSERVÉS dans tous les cas :
    - Bucket de sauvegardes gs://${BACKUP_BUCKET}
    - Secrets (Secret Manager)

  ⚠ Le magasin de fichiers DHIS2 vit dans un volume de la VM. Sa suppression
    est DÉFINITIVE, et aucune sauvegarde PostgreSQL ne le remplace.
    Vérifier qu'une sauvegarde récente existe :
      gcloud storage ls gs://${BACKUP_BUCKET}/filestore/

EOF

if [ "${DRY_RUN}" != "1" ]; then
  printf '  Pour confirmer, saisir le nom du projet (%s) : ' "${PROJECT_ID}"
  read -r CONFIRM
  if [ "${CONFIRM}" != "${PROJECT_ID}" ]; then
    echo ""
    echo "  Annulé — aucune ressource n'a été supprimée."
    exit 0
  fi
fi

gcloud config set project "${PROJECT_ID}" >/dev/null

# ── VM ───────────────────────────────────────────────────────────────────────
log "VM"
run gcloud compute instances delete "${VM_NAME}" --zone="${ZONE}" --quiet
ok "VM ${VM_NAME}"

# Une adresse statique réservée reste FACTURÉE même détachée de toute VM.
# Elle doit être libérée explicitement, après la suppression de l'instance.
run gcloud compute addresses delete "${VM_IP_NAME}" --region="${REGION}" --quiet
ok "Adresse statique ${VM_IP_NAME}"

run gcloud compute resource-policies delete snap-dhis2-daily --region="${REGION}" --quiet
ok "Politique de snapshots"

# ── Cloud SQL ────────────────────────────────────────────────────────────────
if [ "${KEEP_DATA}" = "1" ]; then
  log "Cloud SQL — préservée (--keep-data)"
  skip "Instance ${SQL_INSTANCE} conservée"
else
  log "Cloud SQL"
  # La protection contre la suppression doit être levée explicitement.
  run gcloud sql instances patch "${SQL_INSTANCE}" --no-deletion-protection --quiet
  run gcloud sql instances delete "${SQL_INSTANCE}" --quiet
  ok "Instance ${SQL_INSTANCE}"
fi

# ── Artifact Registry ────────────────────────────────────────────────────────
log "Artifact Registry"
run gcloud artifacts repositories delete "${AR_REPO}" --location="${REGION}" --quiet
ok "Dépôt ${AR_REPO}"

# ── Réseau ───────────────────────────────────────────────────────────────────
log "Réseau"
for RULE in allow-ssh-iap allow-http-https; do
  run gcloud compute firewall-rules delete "${RULE}" --quiet
done
ok "Règles de pare-feu"

run gcloud services vpc-peerings delete \
  --service=servicenetworking.googleapis.com --network="${VPC_NAME}" --quiet
ok "Peering Private Service Access"

run gcloud compute addresses delete "${PSA_RANGE_NAME}" --global --quiet
ok "Plage réservée"

run gcloud compute networks subnets delete "${SUBNET_NAME}" --region="${REGION}" --quiet
ok "Sous-réseau ${SUBNET_NAME}"

run gcloud compute networks delete "${VPC_NAME}" --quiet
ok "VPC ${VPC_NAME}"

# ── Récapitulatif ────────────────────────────────────────────────────────────
log "Suppression terminée"
cat <<EOF

  Ressources conservées, à supprimer manuellement si nécessaire :

    Sauvegardes  : gcloud storage rm -r gs://${BACKUP_BUCKET}
    Secrets      : gcloud secrets delete dhis2-db-password
                   gcloud secrets delete dhis2-db-user
                   gcloud secrets delete dhis2-encryption-password
    Comptes SA   : sa-dhis2-vm, sa-dhis2-build

  ⚠ Ne supprimer dhis2-encryption-password qu'une fois certain qu'aucune
    sauvegarde ne devra plus jamais être restaurée : sans cette clé, les
    données chiffrées d'un dump restauré sont définitivement illisibles.

EOF
