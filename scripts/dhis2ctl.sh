#!/usr/bin/env bash
# =============================================================================
# dhis2ctl.sh — exploitation courante de DHIS2 sur la VM
#
# Regroupe les gestes du quotidien : état, journaux, arrêt, redémarrage,
# diagnostic. Sans lui, chacun suppose de connaître le chemin du compose, le
# nom des conteneurs et celui des volumes — trois choses qu'on oublie entre
# deux interventions.
#
# À exécuter SUR LA VM, en root :
#   sudo /opt/alima/dhis2/scripts/dhis2ctl.sh <commande>
#
# Le script est déposé sur la VM à chaque déploiement : il suit donc toujours
# la version du dépôt.
# =============================================================================
set -uo pipefail

APP_DIR="${APP_DIR:-/opt/alima/dhis2}"
COMPOSE="docker compose -f ${APP_DIR}/docker-compose.yml"
LOG_VOLUME="dhis2_dhis2-logs"
FILE_VOLUME="dhis2_dhis2-files"

BLEU=$'\033[1;34m'; VERT=$'\033[0;32m'; ROUGE=$'\033[0;31m'; JAUNE=$'\033[0;33m'; RAZ=$'\033[0m'
titre() { printf '\n%s▶ %s%s\n' "${BLEU}" "$*" "${RAZ}"; }
ok()    { printf '  %s✓%s %s\n' "${VERT}" "${RAZ}" "$*"; }
alerte(){ printf '  %s⚠%s %s\n' "${JAUNE}" "${RAZ}" "$*"; }
err()   { printf '  %s✗%s %s\n' "${ROUGE}" "${RAZ}" "$*"; }

besoin_root() {
  [ "$(id -u)" -eq 0 ] || {
    echo "Cette commande doit être exécutée en root : sudo $0 $*" >&2
    exit 1
  }
}

confirmer() {
  # Interruption de service : on demande confirmation, sauf --yes explicite.
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  printf '  %s%s%s Confirmer en tapant « oui » : ' "${JAUNE}" "$1" "${RAZ}"
  read -r REPONSE
  [ "${REPONSE}" = "oui" ] || { echo "  Annulé."; exit 0; }
}

# ── Commandes ────────────────────────────────────────────────────────────────

cmd_status() {
  titre "Conteneurs"
  ${COMPOSE} ps

  titre "Santé"
  for C in dhis2 dhis2-nginx; do
    ETAT=$(docker inspect -f '{{.State.Status}}' "${C}" 2>/dev/null || echo absent)
    SANTE=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}—{{end}}' "${C}" 2>/dev/null || echo "—")
    DEPUIS=$(docker inspect -f '{{.State.StartedAt}}' "${C}" 2>/dev/null | cut -c1-19 || echo "—")
    printf '  %-14s %-12s santé: %-10s depuis: %s\n' "${C}" "${ETAT}" "${SANTE}" "${DEPUIS}"
  done

  titre "Version déployée"
  grep -E '^(IMAGE_TAG|DHIS2_FQDN)=' "${APP_DIR}/.env" 2>/dev/null | sed 's/^/  /' \
    || alerte ".env illisible (exécuter en root)"
}

cmd_logs() {
  SERVICE="${1:-dhis2}"
  shift || true
  titre "Journaux du conteneur ${SERVICE} — Ctrl+C pour quitter"
  ${COMPOSE} logs --tail=100 -f "${SERVICE}" "$@"
}

cmd_applog() {
  # Journaux applicatifs DHIS2, distincts de la sortie du conteneur : c'est là
  # que DHIS2 écrit réellement (cf. dhis.log, dhis-audit.log…).
  FICHIER="${1:-dhis.log}"
  CHEMIN=$(docker volume inspect "${LOG_VOLUME}" --format '{{.Mountpoint}}' 2>/dev/null)
  if [ -z "${CHEMIN}" ]; then
    err "Volume ${LOG_VOLUME} introuvable — la pile a-t-elle déjà démarré ?"
    return 1
  fi
  if [ ! -f "${CHEMIN}/${FICHIER}" ]; then
    err "${FICHIER} absent. Fichiers disponibles :"
    ls -1 "${CHEMIN}" | sed 's/^/    /'
    return 1
  fi
  titre "${CHEMIN}/${FICHIER} — Ctrl+C pour quitter"
  tail -f -n 100 "${CHEMIN}/${FICHIER}"
}

cmd_start() {
  titre "Démarrage"
  ${COMPOSE} up -d --remove-orphans
  ok "Pile démarrée — suivre la montée en service avec : $0 health"
}

cmd_stop() {
  titre "Arrêt de DHIS2"
  alerte "L'application sera INDISPONIBLE jusqu'au prochain démarrage."
  confirmer "Arrêter la production ?"
  # Délai porté à 60 s : Tomcat doit fermer ses connexions à la base.
  ${COMPOSE} down --timeout 60
  ok "Pile arrêtée. Les volumes — dont le magasin de fichiers — sont intacts."
}

cmd_restart() {
  titre "Redémarrage"
  alerte "Interruption de quelques minutes le temps du démarrage de DHIS2."
  confirmer "Redémarrer la production ?"
  ${COMPOSE} down --timeout 60
  ${COMPOSE} up -d --remove-orphans
  ok "Redémarré — suivre la montée en service avec : $0 health"
}

cmd_health() {
  titre "Attente de l'état healthy"
  bash "${APP_DIR}/scripts/wait-healthy.sh" dhis2 600 "${APP_DIR}/docker-compose.yml"
}

cmd_cert() {
  titre "Certificat TLS"
  CERT=/etc/letsencrypt/live/dhis2/fullchain.pem
  if [ ! -f "${CERT}" ]; then
    err "Certificat absent — Nginx ne peut pas démarrer."
    return 1
  fi
  openssl x509 -in "${CERT}" -noout -subject -dates | sed 's/^/  /'
  FIN=$(openssl x509 -in "${CERT}" -noout -enddate | cut -d= -f2)
  RESTE=$(( ( $(date -d "${FIN}" +%s) - $(date +%s) ) / 86400 ))
  if [ "${RESTE}" -lt 21 ]; then
    alerte "Expire dans ${RESTE} jours — le renouvellement aurait dû avoir lieu."
  else
    ok "Expire dans ${RESTE} jours"
  fi
  printf '  Renouvellement automatique : %s\n' "$(systemctl is-active certbot-renew.timer 2>/dev/null)"
}

cmd_disk() {
  titre "Espace disque"
  df -h / | sed 's/^/  /'

  titre "Taille des volumes"
  for V in "${FILE_VOLUME}" "${LOG_VOLUME}" dhis2_dhis2-home; do
    CHEMIN=$(docker volume inspect "${V}" --format '{{.Mountpoint}}' 2>/dev/null) || continue
    printf '  %-22s %s\n' "${V}" "$(du -sh "${CHEMIN}" 2>/dev/null | cut -f1)"
  done

  titre "Images Docker"
  docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' | grep dhis2 || true
}

cmd_db() {
  # Ouvre une session psql sur Cloud SQL. Le mot de passe est lu depuis .env et
  # transmis par l'environnement, jamais en argument : il apparaîtrait sinon
  # dans la liste des processus.
  set -a; . "${APP_DIR}/.env"; set +a
  titre "psql sur ${DHIS2_DATABASE_NAME}@${DHIS2_DATABASE_HOST} — \\q pour quitter"
  docker run --rm -it \
    -e PGPASSWORD="${DHIS2_DATABASE_PASSWORD}" \
    postgres:16-alpine \
    psql -h "${DHIS2_DATABASE_HOST}" -U "${DHIS2_DATABASE_USER}" -d "${DHIS2_DATABASE_NAME}"
}

cmd_backup() {
  titre "Sauvegarde du magasin de fichiers"
  cd "${APP_DIR}" && ${COMPOSE} --profile backup run --rm backup-filestore
}

cmd_info() {
  titre "DHIS2 — /api/system/info"
  docker exec dhis2 curl -sf http://127.0.0.1:8080/api/system/info 2>/dev/null \
    | head -c 800 | sed 's/^/  /' \
    || alerte "Non lisible sans authentification — c'est normal."
  echo ""

  titre "Ressources"
  docker stats --no-stream --format '  {{.Name}}  CPU {{.CPUPerc}}  RAM {{.MemUsage}}' \
    dhis2 dhis2-nginx 2>/dev/null || true
}

usage() {
  cat <<EOF

  dhis2ctl — exploitation de DHIS2 ALIMA

  Usage : sudo $0 <commande> [arguments]

  ÉTAT
    status              conteneurs, santé, version déployée
    health              attend et vérifie que DHIS2 répond
    info                /api/system/info et consommation CPU/RAM
    cert                certificat TLS et son échéance
    disk                espace disque, taille des volumes et des images

  JOURNAUX
    logs [service]      sortie du conteneur (dhis2 par défaut), en continu
    applog [fichier]    journaux applicatifs DHIS2 (dhis.log par défaut)

  CYCLE DE VIE                       ⚠ interrompent le service
    start               démarre la pile
    stop                arrête la pile — les volumes sont préservés
    restart             arrête puis redémarre

  MAINTENANCE
    db                  session psql sur Cloud SQL
    backup              sauvegarde du magasin de fichiers vers Cloud Storage

  Variables : ASSUME_YES=1 pour ne pas demander confirmation.

  Le déploiement d'une nouvelle version ne se fait PAS ici : il passe par
  Cloud Build, avec approbation. Voir docs/aide-memoire.md.

EOF
}

# ── Aiguillage ───────────────────────────────────────────────────────────────
COMMANDE="${1:-}"
shift || true

case "${COMMANDE}" in
  status)   besoin_root; cmd_status ;;
  logs)     besoin_root; cmd_logs "$@" ;;
  applog)   besoin_root; cmd_applog "$@" ;;
  start)    besoin_root; cmd_start ;;
  stop)     besoin_root; cmd_stop ;;
  restart)  besoin_root; cmd_restart ;;
  health)   besoin_root; cmd_health ;;
  cert)     besoin_root; cmd_cert ;;
  disk)     besoin_root; cmd_disk ;;
  db)       besoin_root; cmd_db ;;
  backup)   besoin_root; cmd_backup ;;
  info)     besoin_root; cmd_info ;;
  ""|-h|--help|help) usage ;;
  *)        echo "Commande inconnue : ${COMMANDE}" >&2; usage; exit 1 ;;
esac
