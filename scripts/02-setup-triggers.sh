#!/usr/bin/env bash
# =============================================================================
# 02-setup-triggers.sh — création des déclencheurs Cloud Build
#
# Crée les deux déclencheurs de la chaîne :
#   - dhis2-build       : construction automatique à chaque push sur main
#   - dhis2-deploy-prod : déploiement manuel, AVEC APPROBATION OBLIGATOIRE
#
# Les déclencheurs sont créés dans la RÉGION où le dépôt est connecté
# (europe-west1 par défaut), et non en « global » : une connexion régionale
# relève de la 2e génération de Cloud Build, dont les déclencheurs doivent
# vivre dans la même région que la connexion.
#
# PRÉREQUIS — à faire UNE FOIS, avant d'exécuter ce script :
#
#   1. Le dépôt doit être poussé sur GitHub :
#        git push origin main
#
#   2. Le dépôt GitHub doit être connecté à Cloud Build dans la région visée.
#      Cette étape passe par une autorisation OAuth et ne peut pas être
#      automatisée :
#        https://console.cloud.google.com/cloud-build/triggers/connect
#
# Le script est IDEMPOTENT : un déclencheur existant est laissé en l'état.
#
# Usage :
#   ./scripts/02-setup-triggers.sh
#   REGION=europe-west1 ./scripts/02-setup-triggers.sh
#   DRY_RUN=1 ./scripts/02-setup-triggers.sh
# =============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-alima-dhis2-prod}"
REGION="${REGION:-europe-west1}"
REPO_OWNER="${REPO_OWNER:-gh-alima}"
REPO_NAME="${REPO_NAME:-alima-dhis2}"
BRANCH="${BRANCH:-main}"

BUILD_SA="sa-dhis2-build@${PROJECT_ID}.iam.gserviceaccount.com"
SA_PATH="projects/${PROJECT_ID}/serviceAccounts/${BUILD_SA}"

TRIGGER_BUILD="dhis2-build"
TRIGGER_DEPLOY="dhis2-deploy-prod"

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

trigger_exists() {
  gcloud builds triggers describe "$1" --region="${REGION}" >/dev/null 2>&1
}

command -v gcloud >/dev/null || { echo "gcloud est requis." >&2; exit 1; }

log "Projet ${PROJECT_ID} — région ${REGION} — dépôt ${REPO_OWNER}/${REPO_NAME}"
gcloud config set project "${PROJECT_ID}" >/dev/null
[ "${DRY_RUN}" = "1" ] && echo "  MODE DRY-RUN — aucun déclencheur ne sera créé."

# ── Détection du mode de connexion ───────────────────────────────────────────
# Cloud Build connaît deux générations de liaison au dépôt, qui ne se pilotent
# pas de la même façon :
#
#   2e génération — connexions et dépôts sont des ressources régionales ; le
#                   déclencheur se rattache à une ressource « repository »
#                   complète, via --repository.
#   1re génération — liaison par l'application GitHub Cloud Build ; le
#                   déclencheur désigne le dépôt par --repo-owner/--repo-name.
#
# On cherche d'abord une ressource de 2e génération ; à défaut, on retombe sur
# la 1re, qui est le mode le plus répandu.
log "Recherche du dépôt connecté"

REPO_RESOURCE=""
for CONN in $(gcloud builds connections list --region="${REGION}" \
                --format='value(name)' 2>/dev/null || true); do
  CONN_ID="${CONN##*/}"
  FOUND=$(gcloud builds repositories list \
            --connection="${CONN_ID}" --region="${REGION}" \
            --format='value(name)' 2>/dev/null \
          | grep -E "/repositories/${REPO_NAME}$" | head -1 || true)
  if [ -n "${FOUND}" ]; then
    REPO_RESOURCE="${FOUND}"
    break
  fi
done

if [ -n "${REPO_RESOURCE}" ]; then
  GEN=2
  ok "Connexion de 2e génération"
  ok "Dépôt : ${REPO_RESOURCE}"
else
  GEN=1
  ok "Aucune ressource de 2e génération — bascule en 1re génération"
  ok "Dépôt : ${REPO_OWNER}/${REPO_NAME} (application GitHub Cloud Build)"
  echo ""
  echo "  Si la création échoue avec « repository not found », c'est que le dépôt"
  echo "  n'est pas lié à Cloud Build. Le connecter puis relancer :"
  echo "    https://console.cloud.google.com/cloud-build/triggers/connect?project=${PROJECT_ID}"
fi

# ── 1. Construction ──────────────────────────────────────────────────────────
# Se déclenche à chaque push sur main. Les modifications purement
# documentaires n'entraînent pas de reconstruction : une image identique sous
# un nouveau tag n'apporte rien et brouille l'historique du registre.
log "Déclencheur de construction"

if trigger_exists "${TRIGGER_BUILD}"; then
  skip "${TRIGGER_BUILD}"
elif [ "${GEN}" = "2" ]; then
  run gcloud builds triggers create github \
    --name="${TRIGGER_BUILD}" \
    --description="Construit dhis2-core et dhis2-nginx à chaque push sur ${BRANCH}" \
    --region="${REGION}" \
    --repository="${REPO_RESOURCE}" \
    --branch-pattern="^${BRANCH}$" \
    --build-config=cloudbuild.yaml \
    --ignored-files="**/*.md" \
    --service-account="${SA_PATH}"
  ok "${TRIGGER_BUILD} — push sur ${BRANCH}, hors **/*.md"
else
  run gcloud builds triggers create github \
    --name="${TRIGGER_BUILD}" \
    --description="Construit dhis2-core et dhis2-nginx à chaque push sur ${BRANCH}" \
    --region="${REGION}" \
    --repo-owner="${REPO_OWNER}" \
    --repo-name="${REPO_NAME}" \
    --branch-pattern="^${BRANCH}$" \
    --build-config=cloudbuild.yaml \
    --ignored-files="**/*.md" \
    --service-account="${SA_PATH}"
  ok "${TRIGGER_BUILD} — push sur ${BRANCH}, hors **/*.md"
fi

# ── 2. Déploiement ───────────────────────────────────────────────────────────
# Manuel et soumis à approbation. C'est LE point de contrôle de la chaîne :
# il vit dans le déclencheur, pas dans le dépôt, et ne peut donc pas être
# contourné par un commit.
log "Déclencheur de déploiement"

if trigger_exists "${TRIGGER_DEPLOY}"; then
  skip "${TRIGGER_DEPLOY}"
elif [ "${GEN}" = "2" ]; then
  run gcloud builds triggers create manual \
    --name="${TRIGGER_DEPLOY}" \
    --description="Déploie un tag existant en PRODUCTION — approbation obligatoire" \
    --region="${REGION}" \
    --repository="${REPO_RESOURCE}" \
    --branch="${BRANCH}" \
    --build-config=cloudbuild-deploy.yaml \
    --require-approval \
    --service-account="${SA_PATH}"
  ok "${TRIGGER_DEPLOY} — manuel, APPROBATION OBLIGATOIRE"
else
  run gcloud builds triggers create manual \
    --name="${TRIGGER_DEPLOY}" \
    --description="Déploie un tag existant en PRODUCTION — approbation obligatoire" \
    --region="${REGION}" \
    --repo="https://github.com/${REPO_OWNER}/${REPO_NAME}" \
    --repo-type=GITHUB \
    --branch="${BRANCH}" \
    --build-config=cloudbuild-deploy.yaml \
    --require-approval \
    --service-account="${SA_PATH}"
  ok "${TRIGGER_DEPLOY} — manuel, APPROBATION OBLIGATOIRE"
fi

# ── 3. Contrôle ──────────────────────────────────────────────────────────────
log "Déclencheurs en place (région ${REGION})"
if [ "${DRY_RUN}" != "1" ]; then
  gcloud builds triggers list --region="${REGION}" \
    --format="table(name,disabled,approvalConfig.approvalRequired:label=APPROBATION)"

  # L'approbation est le garde-fou de la production : on vérifie qu'elle est
  # bien active plutôt que de la supposer.
  APPROVAL=$(gcloud builds triggers describe "${TRIGGER_DEPLOY}" --region="${REGION}" \
    --format='value(approvalConfig.approvalRequired)' 2>/dev/null || echo "")
  case "${APPROVAL}" in
    True|true) ok "Approbation confirmée sur ${TRIGGER_DEPLOY}" ;;
    *)
      echo ""
      echo "  ⚠ ATTENTION : l'approbation n'est PAS active sur ${TRIGGER_DEPLOY}." >&2
      echo "    Un déploiement en production pourrait être lancé sans validation." >&2
      echo "    L'activer : Cloud Build → Déclencheurs → ${TRIGGER_DEPLOY}" >&2
      echo "               → Approbation → Exiger une approbation" >&2
      ;;
  esac
fi

cat <<EOF

  Chaîne en place — région ${REGION}
  ---------------------------------
  push sur ${BRANCH}
     └─▶ ${TRIGGER_BUILD}  (automatique)
            └─▶ images dans Artifact Registry, tag <version>.<date>.<commit>

  validation locale du tag
     └─▶ ${TRIGGER_DEPLOY}  (manuel + APPROBATION)
            └─▶ VM de production

  Lancer un déploiement :
    gcloud builds triggers run ${TRIGGER_DEPLOY} --region=${REGION} \\
      --branch=${BRANCH} --substitutions=_IMAGE_TAG=<tag>

  ⚠ Un « gcloud builds submit » direct contourne l'approbation : c'est l'IAM,
    et non le déclencheur, qui restreint qui peut déployer (cf. §9.3 du mode
    opératoire).

EOF
