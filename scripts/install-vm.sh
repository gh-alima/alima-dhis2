#!/usr/bin/env bash
# =============================================================================
# install-vm.sh — préparation de la VM applicative
#
# À exécuter UNE FOIS sur la VM, en root, après le provisionnement GCP :
#   gcloud compute ssh vm-dhis2-app --zone=europe-west1-b --tunnel-through-iap
#   sudo ./install-vm.sh
#
# Installe Docker, crée les volumes de persistance, configure l'agent Ops pour
# la collecte des journaux applicatifs, et met en place le renouvellement TLS.
# =============================================================================
set -euo pipefail

APP_DIR="/opt/alima/dhis2"
DOMAIN="${DOMAIN:-dhis2.alima.ngo}"
ACME_EMAIL="${ACME_EMAIL:-si@alima.ngo}"

log() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()  { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Ce script doit être exécuté en root (sudo)." >&2; exit 1; }

# ── 1. Système ───────────────────────────────────────────────────────────────
log "Mise à jour du système"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq ca-certificates curl gnupg jq unattended-upgrades
ok "Paquets de base installés"

# Correctifs de sécurité appliqués automatiquement : la VM porte une
# application exposée sur Internet.
dpkg-reconfigure -f noninteractive unattended-upgrades
ok "Mises à jour de sécurité automatiques activées"

# ── 2. Docker ────────────────────────────────────────────────────────────────
log "Installation de Docker"
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  ok "Docker installé"
else
  ok "Docker déjà présent ($(docker --version))"
fi

systemctl enable --now docker

# Journaux des conteneurs bornés : sans cette limite, json-file grossit
# indéfiniment et finit par saturer le disque de la VM.
cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" },
  "live-restore": true
}
JSON
systemctl restart docker
ok "Rotation des journaux de conteneurs configurée"

# ── 3. Google Cloud CLI ──────────────────────────────────────────────────────
# Indispensable sur la VM, et pas seulement pour l'installation : render-env.sh
# l'utilise à CHAQUE déploiement pour lire les secrets. Les images Ubuntu de
# Compute Engine ne l'embarquent pas systématiquement.
log "Google Cloud CLI"
if command -v gcloud >/dev/null 2>&1; then
  ok "gcloud déjà présent ($(gcloud --version 2>/dev/null | head -1))"
else
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    > /etc/apt/sources.list.d/google-cloud-sdk.list
  apt-get update -qq
  apt-get install -y -qq google-cloud-cli
  ok "gcloud installé ($(gcloud --version 2>/dev/null | head -1))"
fi

# Vérifie que le compte de service de la VM peut effectivement lire un secret :
# sans ce droit, chaque déploiement échouerait à la génération du .env.
if gcloud secrets versions access latest --secret=dhis2-db-host >/dev/null 2>&1; then
  ok "Accès aux secrets vérifié"
else
  echo "  ⚠ Lecture du secret dhis2-db-host impossible." >&2
  echo "    Vérifier que la VM tourne bien sous sa-dhis2-vm et que ce compte" >&2
  echo "    porte le rôle roles/secretmanager.secretAccessor." >&2
fi

# ── 4. Authentification au registre ──────────────────────────────────────────
log "Authentification Artifact Registry"
gcloud auth configure-docker europe-west1-docker.pkg.dev --quiet
ok "Docker authentifié auprès d'Artifact Registry"

# ── 5. Volumes de persistance ────────────────────────────────────────────────
# Créés explicitement ici plutôt que laissés à docker compose : on veut qu'ils
# existent avant le premier déploiement et qu'ils survivent à un
# « docker compose down -v » malencontreux sur les autres ressources.
log "Volumes de persistance"
for VOL in dhis2-home dhis2-files dhis2-logs; do
  if docker volume inspect "${VOL}" >/dev/null 2>&1; then
    ok "Volume ${VOL} déjà présent"
  else
    docker volume create "${VOL}" >/dev/null
    ok "Volume ${VOL} créé"
  fi
done

cat <<'WARN'

  ⚠ RAPPEL — le volume dhis2-files contient le magasin de fichiers DHIS2.
    Il n'est PAS couvert par les sauvegardes PostgreSQL. Sa perte rend
    irrécupérables toutes les pièces jointes, quel que soit l'état de la base.
    Sauvegarde : scripts/backup-filestore.sh (hebdomadaire).

WARN

# ── 6. Arborescence applicative ──────────────────────────────────────────────
log "Arborescence applicative"
mkdir -p "${APP_DIR}/scripts" /var/www/certbot
chmod 750 "${APP_DIR}"
ok "${APP_DIR} prêt"

# ── 7. Certificat TLS ────────────────────────────────────────────────────────
# Nginx refuse de démarrer si les certificats sont absents : ils doivent être
# obtenus AVANT le premier déploiement.
log "Certificat TLS"
if [ -f "/etc/letsencrypt/live/dhis2/fullchain.pem" ]; then
  ok "Certificat déjà en place"
else
  apt-get install -y -qq certbot
  echo "  Obtention du certificat pour ${DOMAIN}..."
  echo "  (le port 80 doit être joignable depuis Internet)"
  certbot certonly --standalone \
    --non-interactive --agree-tos \
    --email "${ACME_EMAIL}" \
    --cert-name dhis2 \
    -d "${DOMAIN}" || {
      echo ""
      echo "  ⚠ Échec de l'obtention du certificat." >&2
      echo "    Vérifier que ${DOMAIN} pointe bien vers l'IP de cette VM" >&2
      echo "    et que le port 80 est ouvert, puis relancer :" >&2
      echo "      certbot certonly --standalone --cert-name dhis2 -d ${DOMAIN}" >&2
      echo ""
    }
fi

# Renouvellement : Nginx doit être arrêté le temps du challenge http-01.
cat > /etc/systemd/system/certbot-renew.service <<EOF
[Unit]
Description=Renouvellement du certificat TLS DHIS2

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet \\
  --pre-hook "docker stop dhis2-nginx" \\
  --post-hook "docker start dhis2-nginx"
EOF

cat > /etc/systemd/system/certbot-renew.timer <<'EOF'
[Unit]
Description=Renouvellement TLS deux fois par jour

[Timer]
OnCalendar=*-*-* 03,15:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now certbot-renew.timer
ok "Renouvellement TLS automatique activé"

# ── 8. Agent Ops ─────────────────────────────────────────────────────────────
# DHIS2 abandonne progressivement la journalisation vers la sortie standard :
# les journaux applicatifs se lisent sous DHIS2_HOME/logs, donc dans le volume
# dhis2-logs. L'agent Ops les collecte directement à cet emplacement.
log "Agent Ops (journaux et métriques)"
if ! systemctl is-active --quiet google-cloud-ops-agent; then
  curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
  bash add-google-cloud-ops-agent-repo.sh --also-install
  rm -f add-google-cloud-ops-agent-repo.sh
fi

VOL_PATH="$(docker volume inspect dhis2-logs --format '{{.Mountpoint}}')"
cat > /etc/google-cloud-ops-agent/config.yaml <<EOF
logging:
  receivers:
    dhis2_app:
      type: files
      # Motif générique plutôt qu'une liste nominative : DHIS2 produit plus de
      # fichiers que les quatre documentés (audit, metadata-sync,
      # push-analysis…) et la liste varie selon les versions. Une énumération
      # figée laisserait des journaux non collectés, sans que rien ne le signale.
      include_paths:
        - ${VOL_PATH}/*.log
  service:
    pipelines:
      dhis2:
        receivers: [dhis2_app]
metrics:
  service:
    pipelines:
      default_pipeline:
        receivers: [hostmetrics]
EOF
systemctl restart google-cloud-ops-agent
ok "Journaux DHIS2 collectés depuis ${VOL_PATH}"

# ── Récapitulatif ────────────────────────────────────────────────────────────
log "VM prête"
cat <<EOF

  Répertoire applicatif : ${APP_DIR}
  Volumes               : dhis2-home, dhis2-files, dhis2-logs
  TLS                   : /etc/letsencrypt/live/dhis2/
  Journaux              : collectés vers Cloud Logging

  Le premier déploiement peut maintenant être lancé depuis Cloud Build :

    gcloud builds submit --config=cloudbuild-deploy.yaml \\
      --substitutions=_IMAGE_TAG=<tag> \\
      --project=alima-dhis2-prod

EOF
