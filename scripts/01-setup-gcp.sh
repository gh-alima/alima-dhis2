#!/usr/bin/env bash
# =============================================================================
# 01-setup-gcp.sh — provisionnement de l'infrastructure DHIS2 ALIMA sur GCP
#
# SOURCE DE VÉRITÉ DU PROVISIONNEMENT.
# Toute modification d'infrastructure — y compris faite à la main dans la
# console — doit être répercutée ici. Sans quoi ce fichier devient un document
# de fiction et l'infrastructure n'est plus reproductible.
#
# Le script est IDEMPOTENT : chaque ressource est créée si elle n'existe pas,
# laissée en l'état sinon. Il peut donc être relancé sans risque.
#
# Usage :
#   ./scripts/01-setup-gcp.sh                 # provisionne tout
#   DRY_RUN=1 ./scripts/01-setup-gcp.sh       # affiche sans exécuter
# =============================================================================
set -euo pipefail

# ── Paramètres ───────────────────────────────────────────────────────────────
PROJECT_ID="${PROJECT_ID:-alima-dhis2-prod}"
REGION="${REGION:-europe-west1}"
ZONE="${ZONE:-europe-west1-b}"

VPC_NAME="vpc-dhis2"
SUBNET_NAME="subnet-dhis2"
SUBNET_RANGE="10.10.0.0/24"
PSA_RANGE_NAME="google-managed-services-${VPC_NAME}"

SQL_INSTANCE="pg16-dhis2-prod"
SQL_TIER="db-custom-2-8192"
SQL_DISK_SIZE="100"
SQL_DB_NAME="dhis2"
SQL_DB_USER="dhis"

AR_REPO="dhis2-images"

VM_NAME="vm-dhis2-app"
VM_IP_NAME="ip-dhis2-app"
VM_TYPE="e2-standard-2"
VM_DISK_SIZE="100"
VM_IMAGE_FAMILY="ubuntu-2204-lts"
VM_IMAGE_PROJECT="ubuntu-os-cloud"
VM_SA_NAME="sa-dhis2-vm"

BUILD_SA_NAME="sa-dhis2-build"
BACKUP_BUCKET="${PROJECT_ID}-dhis2-backups"

# ── Utilitaires ──────────────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-0}"

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
skip() { printf '  \033[0;33m•\033[0m %s (existe déjà)\n' "$*"; }

run() {
  if [ "${DRY_RUN}" = "1" ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# Exécute une création uniquement si la ressource est absente.
#   ensure <libellé> <commande de vérification...> -- <commande de création...>
ensure() {
  local label="$1"; shift
  local check=() create=() seen=0
  for arg in "$@"; do
    if [ "${arg}" = "--" ]; then seen=1; continue; fi
    if [ "${seen}" = "0" ]; then check+=("${arg}"); else create+=("${arg}"); fi
  done
  if "${check[@]}" >/dev/null 2>&1; then
    skip "${label}"
  else
    run "${create[@]}"
    ok "${label}"
  fi
}

# ── Contrôles préalables ─────────────────────────────────────────────────────
command -v gcloud >/dev/null || { echo "gcloud est requis." >&2; exit 1; }

log "Projet ${PROJECT_ID} — région ${REGION}"
gcloud config set project "${PROJECT_ID}" >/dev/null
[ "${DRY_RUN}" = "1" ] && echo "  MODE DRY-RUN — aucune ressource ne sera créée."

# ── 1. Activation des API ────────────────────────────────────────────────────
log "Activation des API"
run gcloud services enable \
  compute.googleapis.com \
  sqladmin.googleapis.com \
  servicenetworking.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  secretmanager.googleapis.com \
  iap.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  storage.googleapis.com
ok "API activées"

# ── 2. Réseau ────────────────────────────────────────────────────────────────
log "Réseau"

ensure "VPC ${VPC_NAME}" \
  gcloud compute networks describe "${VPC_NAME}" \
  -- gcloud compute networks create "${VPC_NAME}" --subnet-mode=custom

ensure "Sous-réseau ${SUBNET_NAME} (${SUBNET_RANGE})" \
  gcloud compute networks subnets describe "${SUBNET_NAME}" --region="${REGION}" \
  -- gcloud compute networks subnets create "${SUBNET_NAME}" \
       --network="${VPC_NAME}" --region="${REGION}" --range="${SUBNET_RANGE}" \
       --enable-private-ip-google-access

# Private Service Access : c'est ce peering qui permet à Cloud SQL de n'avoir
# QUE des adresses privées.
ensure "Plage réservée pour Private Service Access" \
  gcloud compute addresses describe "${PSA_RANGE_NAME}" --global \
  -- gcloud compute addresses create "${PSA_RANGE_NAME}" \
       --global --purpose=VPC_PEERING --prefix-length=16 --network="${VPC_NAME}"

if gcloud services vpc-peerings list --network="${VPC_NAME}" \
     --format='value(peering)' 2>/dev/null | grep -q servicenetworking; then
  skip "Peering Private Service Access"
else
  run gcloud services vpc-peerings connect \
    --service=servicenetworking.googleapis.com \
    --ranges="${PSA_RANGE_NAME}" --network="${VPC_NAME}"
  ok "Peering Private Service Access"
fi

# ── 3. Pare-feu ──────────────────────────────────────────────────────────────
log "Pare-feu"

# SSH exclusivement via IAP : aucune exposition directe du port 22.
ensure "SSH via IAP uniquement (35.235.240.0/20)" \
  gcloud compute firewall-rules describe allow-ssh-iap \
  -- gcloud compute firewall-rules create allow-ssh-iap \
       --network="${VPC_NAME}" --direction=INGRESS --action=ALLOW \
       --rules=tcp:22 --source-ranges=35.235.240.0/20 \
       --description="SSH via IAP uniquement"

ensure "HTTP/HTTPS entrants (tag http-server)" \
  gcloud compute firewall-rules describe allow-http-https \
  -- gcloud compute firewall-rules create allow-http-https \
       --network="${VPC_NAME}" --direction=INGRESS --action=ALLOW \
       --rules=tcp:80,tcp:443 --source-ranges=0.0.0.0/0 \
       --target-tags=http-server \
       --description="Trafic web entrant vers la VM DHIS2"

# ── 4. Cloud SQL ─────────────────────────────────────────────────────────────
log "Cloud SQL PostgreSQL 16"

if gcloud sql instances describe "${SQL_INSTANCE}" >/dev/null 2>&1; then
  skip "Instance ${SQL_INSTANCE}"
else
  # --edition=ENTERPRISE est OBLIGATOIRE ici. Sans ce drapeau, Cloud SQL crée
  # l'instance en édition ENTERPRISE_PLUS, qui refuse les paliers personnalisés
  # db-custom-* et n'accepte que les db-perf-optimized-*, sensiblement plus
  # coûteux. L'édition ENTERPRISE couvre le besoin d'ALIMA : PITR, sauvegardes
  # automatiques et haute disponibilité optionnelle.
  run gcloud sql instances create "${SQL_INSTANCE}" \
    --database-version=POSTGRES_16 \
    --edition=ENTERPRISE \
    --tier="${SQL_TIER}" \
    --region="${REGION}" \
    --storage-size="${SQL_DISK_SIZE}" \
    --storage-type=SSD \
    --storage-auto-increase \
    --network="projects/${PROJECT_ID}/global/networks/${VPC_NAME}" \
    --no-assign-ip \
    --availability-type=ZONAL \
    --backup-start-time=02:00 \
    --enable-point-in-time-recovery \
    --retained-backups-count=30 \
    --maintenance-window-day=SUN \
    --maintenance-window-hour=3 \
    --database-flags=max_connections=200 \
    --deletion-protection
  ok "Instance ${SQL_INSTANCE} (IP privée, PITR, protection contre la suppression)"
fi

ensure "Base ${SQL_DB_NAME}" \
  gcloud sql databases describe "${SQL_DB_NAME}" --instance="${SQL_INSTANCE}" \
  -- gcloud sql databases create "${SQL_DB_NAME}" --instance="${SQL_INSTANCE}"

# Le mot de passe est généré ici et n'est JAMAIS affiché : il part directement
# dans Secret Manager.
#
# Le secret et l'utilisateur PostgreSQL sont traités en DEUX étapes distinctes.
# Les imbriquer casserait l'idempotence : si le script s'interrompt entre la
# création du secret et celle de l'utilisateur, une relance verrait le secret
# présent, sauterait tout le bloc, et laisserait la base sans compte applicatif.
if gcloud secrets describe dhis2-db-password >/dev/null 2>&1; then
  skip "Secret dhis2-db-password"
elif [ "${DRY_RUN}" = "1" ]; then
  echo "  [dry-run] génération du mot de passe et création du secret"
else
  DB_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
  printf '%s' "${DB_PASSWORD}" | \
    gcloud secrets create dhis2-db-password --data-file=- --replication-policy=automatic
  unset DB_PASSWORD
  ok "Secret dhis2-db-password"
fi

# L'utilisateur PostgreSQL est aligné sur le mot de passe stocké, quel que soit
# l'état précédent : création s'il n'existe pas, réalignement sinon.
if [ "${DRY_RUN}" = "1" ]; then
  echo "  [dry-run] création ou réalignement de l'utilisateur ${SQL_DB_USER}"
else
  DB_PASSWORD=$(gcloud secrets versions access latest --secret=dhis2-db-password)
  if gcloud sql users list --instance="${SQL_INSTANCE}" \
       --format='value(name)' 2>/dev/null | grep -qx "${SQL_DB_USER}"; then
    gcloud sql users set-password "${SQL_DB_USER}" --instance="${SQL_INSTANCE}" \
      --password="${DB_PASSWORD}" >/dev/null
    ok "Utilisateur ${SQL_DB_USER} (mot de passe réaligné sur le secret)"
  else
    gcloud sql users create "${SQL_DB_USER}" --instance="${SQL_INSTANCE}" \
      --password="${DB_PASSWORD}" >/dev/null
    ok "Utilisateur ${SQL_DB_USER} créé"
  fi
  unset DB_PASSWORD
fi

# ── 5. Secrets ───────────────────────────────────────────────────────────────
log "Secret Manager"

ensure "Secret dhis2-db-user" \
  gcloud secrets describe dhis2-db-user \
  -- bash -c "printf '%s' '${SQL_DB_USER}' | gcloud secrets create dhis2-db-user --data-file=- --replication-policy=automatic"

# La clé de chiffrement DHIS2 ne doit JAMAIS changer après la mise en service :
# les données déjà chiffrées deviendraient illisibles.
ensure "Secret dhis2-encryption-password" \
  gcloud secrets describe dhis2-encryption-password \
  -- bash -c "openssl rand -base64 32 | tr -d '/+=' | head -c 32 | gcloud secrets create dhis2-encryption-password --data-file=- --replication-policy=automatic"

# L'IP privée de Cloud SQL n'est connue qu'après création de l'instance. Elle
# est stockée en secret pour que render-env.sh la lise sur la VM, sans que le
# pipeline de déploiement ait à la connaître.
if gcloud secrets describe dhis2-db-host >/dev/null 2>&1; then
  skip "Secret dhis2-db-host"
elif [ "${DRY_RUN}" = "1" ]; then
  echo "  [dry-run] relevé de l'IP privée Cloud SQL et création du secret"
else
  DB_HOST=$(gcloud sql instances describe "${SQL_INSTANCE}" \
    --format="value(ipAddresses[0].ipAddress)")
  if [ -z "${DB_HOST}" ]; then
    echo "  ⚠ IP privée introuvable — créer dhis2-db-host manuellement." >&2
  else
    printf '%s' "${DB_HOST}" | \
      gcloud secrets create dhis2-db-host --data-file=- --replication-policy=automatic
    ok "Secret dhis2-db-host (${DB_HOST})"
  fi
fi

# URL publique de l'instance. Valeur de configuration, stockée avec les autres
# pour que render-env.sh n'ait qu'une seule source à interroger.
ensure "Secret dhis2-fqdn" \
  gcloud secrets describe dhis2-fqdn \
  -- bash -c "printf '%s' '${DHIS2_FQDN:-https://dhis2-test.alima.ngo}' | gcloud secrets create dhis2-fqdn --data-file=- --replication-policy=automatic"

# ── 6. Artifact Registry ─────────────────────────────────────────────────────
log "Artifact Registry"

ensure "Dépôt ${AR_REPO}" \
  gcloud artifacts repositories describe "${AR_REPO}" --location="${REGION}" \
  -- gcloud artifacts repositories create "${AR_REPO}" \
       --repository-format=docker --location="${REGION}" \
       --description="Images DHIS2 ALIMA"

# ⚠ La politique de nettoyage doit préserver tout tag encore susceptible de
#   servir au retour arrière. Un tag purgé = retour arrière impossible.
cat <<'POLICY' > /tmp/ar-cleanup.json
[
  {
    "name": "conserver-versions-recentes",
    "action": {"type": "Keep"},
    "mostRecentVersions": {"keepCount": 10}
  },
  {
    "name": "supprimer-anciennes",
    "action": {"type": "Delete"},
    "condition": {"olderThan": "30d", "tagState": "ANY"}
  }
]
POLICY
run gcloud artifacts repositories set-cleanup-policies "${AR_REPO}" \
  --location="${REGION}" --policy=/tmp/ar-cleanup.json --no-dry-run
ok "Politique de nettoyage (10 versions conservées, purge > 30 jours)"

# ── 7. Comptes de service ────────────────────────────────────────────────────
log "Comptes de service et IAM"

VM_SA="${VM_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
BUILD_SA="${BUILD_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

ensure "Compte de service ${VM_SA_NAME}" \
  gcloud iam service-accounts describe "${VM_SA}" \
  -- gcloud iam service-accounts create "${VM_SA_NAME}" \
       --display-name="VM DHIS2 ALIMA"

ensure "Compte de service ${BUILD_SA_NAME}" \
  gcloud iam service-accounts describe "${BUILD_SA}" \
  -- gcloud iam service-accounts create "${BUILD_SA_NAME}" \
       --display-name="Cloud Build DHIS2 ALIMA"

# La VM lit les secrets elle-même : ils ne transitent jamais par le pipeline.
for ROLE in roles/secretmanager.secretAccessor \
            roles/artifactregistry.reader \
            roles/logging.logWriter \
            roles/monitoring.metricWriter \
            roles/storage.objectAdmin; do
  run gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${VM_SA}" --role="${ROLE}" --condition=None >/dev/null
done
ok "Rôles de la VM (secrets, registre, journaux, métriques, stockage)"

for ROLE in roles/artifactregistry.writer \
            roles/compute.instanceAdmin.v1 \
            roles/iap.tunnelResourceAccessor \
            roles/iam.serviceAccountUser \
            roles/logging.logWriter; do
  run gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${BUILD_SA}" --role="${ROLE}" --condition=None >/dev/null
done
ok "Rôles de Cloud Build (registre, accès VM via IAP)"

# ── 8. Stockage des sauvegardes ──────────────────────────────────────────────
log "Cloud Storage"

if gcloud storage buckets describe "gs://${BACKUP_BUCKET}" >/dev/null 2>&1; then
  skip "Bucket ${BACKUP_BUCKET}"
else
  run gcloud storage buckets create "gs://${BACKUP_BUCKET}" \
    --location="${REGION}" --uniform-bucket-level-access \
    --public-access-prevention
  ok "Bucket ${BACKUP_BUCKET} (accès public interdit)"
fi

# La règle de cycle de vie est appliquée à CHAQUE passage, hors du test
# d'existence du bucket : si elle échouait après la création, la placer dans le
# bloc « else » ferait qu'elle ne serait jamais rejouée — un bucket sans
# rétention accumulerait indéfiniment les sauvegardes, sans que rien ne le
# signale.
#
# Le JSON passe par un fichier réel et non par un heredoc sur /dev/stdin :
# bash matérialise un heredoc dans un fichier temporaire qu'il supprime
# immédiatement, et gcloud échoue en tentant de le relire.
cat <<'LIFECYCLE' > /tmp/bucket-lifecycle.json
{"lifecycle":{"rule":[{"action":{"type":"Delete"},"condition":{"age":30}}]}}
LIFECYCLE
run gcloud storage buckets update "gs://${BACKUP_BUCKET}" \
  --lifecycle-file=/tmp/bucket-lifecycle.json
ok "Rétention des sauvegardes : 30 jours"

# ── 9. VM applicative ────────────────────────────────────────────────────────
log "VM applicative"

# Adresse IP publique STATIQUE.
#
# Statique et non éphémère : une adresse éphémère change à chaque arrêt/démarrage
# de la VM, ce qui casserait l'enregistrement DNS — et donc le renouvellement du
# certificat TLS, qui repose sur un challenge HTTP vers ce même nom.
#
# L'exposition reste maîtrisée par le pare-feu : seuls 80 et 443 sont ouverts
# depuis Internet (règle allow-http-https, tag http-server). Le port 22 n'est
# joignable que depuis la plage IAP — une adresse publique n'ouvre donc pas SSH.
ensure "Adresse IP statique ${VM_IP_NAME}" \
  gcloud compute addresses describe "${VM_IP_NAME}" --region="${REGION}" \
  -- gcloud compute addresses create "${VM_IP_NAME}" --region="${REGION}"

if [ "${DRY_RUN}" = "1" ]; then
  VM_IP="<adresse-statique-réservée>"
else
  VM_IP=$(gcloud compute addresses describe "${VM_IP_NAME}" \
    --region="${REGION}" --format='value(address)')
  ok "Adresse publique : ${VM_IP}"
fi

if gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" >/dev/null 2>&1; then
  skip "VM ${VM_NAME}"

  # Rattrapage : VM créée par une version antérieure du script, sans adresse
  # publique. On la lui attache plutôt que d'exiger une recréation.
  if [ "${DRY_RUN}" != "1" ]; then
    CURRENT_IP=$(gcloud compute instances describe "${VM_NAME}" --zone="${ZONE}" \
      --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)
    if [ -z "${CURRENT_IP}" ]; then
      gcloud compute instances add-access-config "${VM_NAME}" --zone="${ZONE}" \
        --address="${VM_IP}" >/dev/null
      ok "Adresse ${VM_IP} rattachée à la VM existante"
    fi
  fi
else
  run gcloud compute instances create "${VM_NAME}" \
    --zone="${ZONE}" \
    --machine-type="${VM_TYPE}" \
    --subnet="${SUBNET_NAME}" \
    --address="${VM_IP}" \
    --image-family="${VM_IMAGE_FAMILY}" \
    --image-project="${VM_IMAGE_PROJECT}" \
    --boot-disk-size="${VM_DISK_SIZE}GB" \
    --boot-disk-type=pd-ssd \
    --tags=http-server \
    --service-account="${VM_SA}" \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
    --metadata=enable-oslogin=TRUE
  ok "VM ${VM_NAME} (adresse statique ${VM_IP}, disque SSD)"
fi

# Snapshots quotidiens du disque : ils couvrent les volumes Docker, donc le
# magasin de fichiers et les journaux.
ensure "Politique de snapshots quotidiens" \
  gcloud compute resource-policies describe snap-dhis2-daily --region="${REGION}" \
  -- gcloud compute resource-policies create snapshot-schedule snap-dhis2-daily \
       --region="${REGION}" --max-retention-days=14 \
       --daily-schedule --start-time=01:00 \
       --on-source-disk-delete=keep-auto-snapshots

run gcloud compute disks add-resource-policies "${VM_NAME}" \
  --zone="${ZONE}" --resource-policies=snap-dhis2-daily 2>/dev/null || true

# ── Récapitulatif ────────────────────────────────────────────────────────────
# Un enregistrement DNS de type A porte un nom d'hôte, pas une URL : on retire
# le schéma et tout chemin éventuel de DHIS2_FQDN.
DHIS2_HOSTNAME="${DHIS2_FQDN:-https://dhis2-test.alima.ngo}"
DHIS2_HOSTNAME="${DHIS2_HOSTNAME#*://}"
DHIS2_HOSTNAME="${DHIS2_HOSTNAME%%/*}"

log "Provisionnement terminé"
cat <<EOF

  Projet          : ${PROJECT_ID}
  VPC / sous-rés. : ${VPC_NAME} / ${SUBNET_NAME} (${SUBNET_RANGE})
  Cloud SQL       : ${SQL_INSTANCE} (PostgreSQL 16, IP privée uniquement)
  Registre        : ${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}
  VM              : ${VM_NAME} (${VM_TYPE})
  Adresse publique: ${VM_IP}  (statique)
  Sauvegardes     : gs://${BACKUP_BUCKET}

  Étapes suivantes
  ----------------
  1. ENREGISTREMENT DNS — à faire en premier, tout le reste en dépend :

       Enregistrement A :  ${DHIS2_HOSTNAME}  ──▶  ${VM_IP}

     Créer un enregistrement A pointant vers cette adresse, puis attendre la
     propagation. Vérifier avant de continuer :
       dig +short <domaine>

     Sans DNS résolu, certbot ne peut pas émettre le certificat, et sans
     certificat Nginx refuse de démarrer.

  2. Installation sur la VM :
       gcloud compute ssh ${VM_NAME} --zone=${ZONE} --tunnel-through-iap
       # puis, sur la VM : sudo DOMAIN=<domaine> ./install-vm.sh

  3. IP privée de la base (déjà stockée dans le secret dhis2-db-host) :
       gcloud sql instances describe ${SQL_INSTANCE} \\
         --format="value(ipAddresses[0].ipAddress)"

  4. Déclencheurs Cloud Build à créer dans la console :
       - construction : push sur main, cloudbuild.yaml, exclusion **/*.md
       - déploiement prod : manuel, cloudbuild-deploy.yaml,
         APPROBATION MANUELLE ACTIVÉE

EOF
