#!/bin/bash
# =============================================================================
# init.sh — entrypoint du conteneur DHIS2 ALIMA
#
# Génère /opt/dhis2/dhis.conf à partir des variables DHIS2_*, puis démarre
# Tomcat. Les blocs optionnels ne sont écrits que si leur drapeau d'activation
# vaut "true" : une fonctionnalité désactivée n'écrit strictement rien.
#
# Référence des propriétés :
#   https://docs.dhis2.org/en/manage/reference/dhisconf.html
# =============================================================================
set -euo pipefail

DHIS2_HOME="${DHIS2_HOME:-/opt/dhis2}"
DHIS2_CONF="${DHIS2_HOME}/dhis.conf"

echo "=== init.sh : génération de ${DHIS2_CONF} ==="

# ---------------------------------------------------------------------------
# Vérification des variables obligatoires
# Échouer ici, avec un message clair, plutôt que de laisser DHIS2 démarrer sur
# une configuration incomplète et échouer 3 minutes plus tard sur une trace
# Hibernate illisible.
# ---------------------------------------------------------------------------
_missing=""
for _var in DHIS2_DATABASE_HOST DHIS2_DATABASE_NAME DHIS2_DATABASE_USER \
            DHIS2_DATABASE_PASSWORD DHIS2_FQDN; do
  if [ -z "$(eval "echo \${${_var}:-}")" ]; then
    _missing="${_missing} ${_var}"
  fi
done
if [ -n "${_missing}" ]; then
  echo "ERREUR : variable(s) obligatoire(s) absente(s) :${_missing}" >&2
  echo "         Voir docker/.env.example pour la liste complète." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Attente de la base de données
# ---------------------------------------------------------------------------
if [ -x /usr/local/bin/wait-for-it.sh ]; then
  /usr/local/bin/wait-for-it.sh \
    "${DHIS2_DATABASE_HOST}" \
    "${DHIS2_DATABASE_PORT:-5432}" \
    "${DHIS2_DB_WAIT_TIMEOUT:-90}"
fi

# ---------------------------------------------------------------------------
# server.https : "on" par défaut, forcé à "off" si INSECURE=true
# INSECURE est réservé au poste de développement.
# ---------------------------------------------------------------------------
_SERVER_HTTPS="${DHIS2_SERVER_HTTPS:-on}"
if [ "${INSECURE:-false}" = "true" ]; then
  _SERVER_HTTPS="off"
  echo "  ATTENTION : INSECURE=true — server.https forcé à off (développement uniquement)"
fi

# ---------------------------------------------------------------------------
# Le fichier contient des secrets en clair : permissions restreintes AVANT
# d'y écrire quoi que ce soit.
# ---------------------------------------------------------------------------
umask 077
: > "${DHIS2_CONF}"
chmod 600 "${DHIS2_CONF}"

# ===========================================================================
# Obligatoire — connexion à la base
# ===========================================================================
cat >> "${DHIS2_CONF}" <<EOF
# Fichier généré automatiquement par init.sh — NE PAS MODIFIER À LA MAIN.
# Toute modification manuelle sera perdue au prochain redémarrage du conteneur.
# Généré le : $(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Connexion à la base de données ---
connection.dialect = org.hibernate.dialect.PostgreSQLDialect
connection.driver_class = org.postgresql.Driver
connection.url = jdbc:postgresql://${DHIS2_DATABASE_HOST}:${DHIS2_DATABASE_PORT:-5432}/${DHIS2_DATABASE_NAME}
connection.username = ${DHIS2_DATABASE_USER}
connection.password = ${DHIS2_DATABASE_PASSWORD}
connection.schema = update
EOF

# ---------------------------------------------------------------------------
# Pool de connexions
# ---------------------------------------------------------------------------
{
  echo ""
  echo "# --- Pool de connexions ---"
  [ -n "${DHIS2_CONNECTION_POOL_MAX_SIZE:-}" ]           && echo "connection.pool.max_size = ${DHIS2_CONNECTION_POOL_MAX_SIZE}"
  [ -n "${DHIS2_CONNECTION_POOL_MAX_IDLE_TIME:-}" ]      && echo "connection.pool.max_idle_time = ${DHIS2_CONNECTION_POOL_MAX_IDLE_TIME}"
  [ -n "${DHIS2_CONNECTION_POOL_TIMEOUT:-}" ]            && echo "connection.pool.timeout = ${DHIS2_CONNECTION_POOL_TIMEOUT}"
  [ -n "${DHIS2_CONNECTION_POOL_VALIDATION_TIMEOUT:-}" ] && echo "connection.pool.validation_timeout = ${DHIS2_CONNECTION_POOL_VALIDATION_TIMEOUT}"
  [ -n "${DHIS2_DB_POOL_TYPE:-}" ]                       && echo "db.pool.type = ${DHIS2_DB_POOL_TYPE}"
  true
} >> "${DHIS2_CONF}"

# ===========================================================================
# Obligatoire — identité du serveur
# ===========================================================================
cat >> "${DHIS2_CONF}" <<EOF

# --- Identité du serveur ---
server.base.url = ${DHIS2_FQDN}
server.https = ${_SERVER_HTTPS}
EOF

# ===========================================================================
# Système
# ===========================================================================
{
  echo ""
  echo "# --- Système ---"
  [ -n "${DHIS2_SYSTEM_READ_ONLY_MODE:-}" ]       && echo "system.read_only_mode = ${DHIS2_SYSTEM_READ_ONLY_MODE}"
  [ -n "${DHIS2_SYSTEM_SESSION_TIMEOUT:-}" ]      && echo "system.session.timeout = ${DHIS2_SYSTEM_SESSION_TIMEOUT}"
  echo "system.sql_view_table_protection = ${DHIS2_SQL_VIEW_TABLE_PROTECTION:-on}"
  [ -n "${DHIS2_SQL_VIEW_WRITE_ENABLED:-}" ]      && echo "system.sql_view_write_enabled = ${DHIS2_SQL_VIEW_WRITE_ENABLED}"
  echo "system.program_rule.server_execution = ${DHIS2_SERVER_SIDE_PROGRAM_RULE_EXECUTION:-on}"
  [ -n "${DHIS2_SYSTEM_CACHE_MAX_SIZE_FACTOR:-}" ] && echo "system.cache.max_size.factor = ${DHIS2_SYSTEM_CACHE_MAX_SIZE_FACTOR}"
  [ -n "${DHIS2_METADATA_SYNC_REMOTE_SERVERS:-}" ] && echo "metadata.sync.remote_servers_allowed = ${DHIS2_METADATA_SYNC_REMOTE_SERVERS}"
  [ -n "${DHIS2_SYSTEM_UPDATE_NOTIFICATIONS:-}" ]  && echo "system.update_notifications_enabled = ${DHIS2_SYSTEM_UPDATE_NOTIFICATIONS}"
  true
} >> "${DHIS2_CONF}"

# ===========================================================================
# Chiffrement
# ===========================================================================
if [ -n "${DHIS2_ENCRYPTION_PASSWORD:-}" ]; then
  cat >> "${DHIS2_CONF}" <<EOF

# --- Chiffrement ---
encryption.password = ${DHIS2_ENCRYPTION_PASSWORD}
EOF
  echo "  -> Chiffrement : configuré"
fi

# ===========================================================================
# SSO — OpenID générique
# ===========================================================================
if [ "${DHIS2_SSO_OPENID_ACTIVATED:-false}" = "true" ]; then
  cat >> "${DHIS2_CONF}" <<EOF

# --- SSO : OpenID ---
oidc.provider.openid.0.client_id = ${DHIS2_SSO_OPENID_CLIENT_ID}
oidc.provider.openid.0.client_secret = ${DHIS2_SSO_OPENID_CLIENT_SECRET}
oidc.provider.openid.0.authorization_uri = ${DHIS2_SSO_OPENID_AUTHORIZATION_URI}
oidc.provider.openid.0.token_uri = ${DHIS2_SSO_OPENID_TOKEN_URI}
oidc.provider.openid.0.userinfo_uri = ${DHIS2_SSO_OPENID_USERINFO_URI}
oidc.provider.openid.0.jwk_uri = ${DHIS2_SSO_OPENID_JWK_URI}
oidc.provider.openid.0.redirect_url = ${DHIS2_SSO_OPENID_REDIRECT_URL}
oidc.provider.openid.0.mapping_claim = ${DHIS2_SSO_OPENID_MAPPING_CLAIM:-email}
EOF
  echo "  -> SSO OpenID : ACTIVÉ"
else
  echo "  -> SSO OpenID : désactivé"
fi

# ===========================================================================
# Nœud / cluster
# ===========================================================================
if [ -n "${DHIS2_NODE_ID:-}" ]; then
  cat >> "${DHIS2_CONF}" <<EOF

# --- Nœud ---
node.id = ${DHIS2_NODE_ID}
node.primary_leader = ${DHIS2_NODE_PRIMARY_LEADER:-false}
EOF
  echo "  -> Nœud : id=${DHIS2_NODE_ID}"
fi

# ===========================================================================
# Supervision
# ===========================================================================
if [ "${DHIS2_METRICS_ACTIVE:-false}" = "true" ]; then
  cat >> "${DHIS2_CONF}" <<EOF

# --- Supervision ---
monitoring.api.enabled = ${DHIS2_MONITORING_API:-on}
monitoring.jvm.enabled = ${DHIS2_MONITORING_JVM:-on}
monitoring.hibernate.enabled = ${DHIS2_MONITORING_HIBERNATE:-off}
monitoring.dbpool.enabled = ${DHIS2_MONITORING_DBPOOL:-on}
monitoring.uptime.enabled = ${DHIS2_MONITORING_UPTIME:-on}
monitoring.cpu.enabled = ${DHIS2_MONITORING_CPU:-on}
EOF
  echo "  -> Supervision : ACTIVÉE"
else
  echo "  -> Supervision : désactivée"
fi

# ===========================================================================
# Redis (clustering multi-instances)
# ===========================================================================
if [ "${DHIS2_REDIS_ENABLED:-false}" = "true" ]; then
  cat >> "${DHIS2_CONF}" <<EOF

# --- Redis ---
redis.enabled = true
redis.host = ${DHIS2_REDIS_HOST:-localhost}
redis.port = ${DHIS2_REDIS_PORT:-6379}
redis.use.ssl = ${DHIS2_REDIS_USE_SSL:-off}
EOF
  [ -n "${DHIS2_REDIS_PASSWORD:-}" ] && echo "redis.password = ${DHIS2_REDIS_PASSWORD}" >> "${DHIS2_CONF}"
  echo "  -> Redis : ACTIVÉ (${DHIS2_REDIS_HOST:-localhost}:${DHIS2_REDIS_PORT:-6379})"
else
  echo "  -> Redis : désactivé"
fi

# ===========================================================================
# Base analytique séparée
# ===========================================================================
if [ "${DHIS2_ANALYTICS_DB_ACTIVATED:-false}" = "true" ]; then
  cat >> "${DHIS2_CONF}" <<EOF

# --- Base analytique ---
analytics.connection.driver_class = org.postgresql.Driver
analytics.connection.url = ${DHIS2_ANALYTICS_DB_URL}
analytics.connection.username = ${DHIS2_ANALYTICS_DB_USERNAME}
analytics.connection.password = ${DHIS2_ANALYTICS_DB_PASSWORD}
analytics.table.unlogged = ${DHIS2_ANALYTICS_TABLE_UNLOGGED:-on}
EOF
  [ -n "${DHIS2_ANALYTICS_POOL_MAX_SIZE:-}" ] && echo "analytics.connection.pool.max_size = ${DHIS2_ANALYTICS_POOL_MAX_SIZE}" >> "${DHIS2_CONF}"
  echo "  -> Base analytique séparée : ACTIVÉE"
else
  echo "  -> Base analytique : base principale"
fi

# ===========================================================================
# Magasin de fichiers
#
# ALIMA utilise le fournisseur "filesystem" (défaut) : les fichiers sont
# stockés dans ${DHIS2_HOME}/files, monté sur le volume dhis2-files.
# Le bloc n'est écrit que si un autre fournisseur est demandé.
#
# ATTENTION : changer de fournisseur après la mise en service est une
# opération complexe — les références en base doivent rester cohérentes.
# ===========================================================================
if [ "${DHIS2_FILESTORE_PROVIDER:-filesystem}" != "filesystem" ]; then
  cat >> "${DHIS2_CONF}" <<EOF

# --- Magasin de fichiers ---
filestore.provider = ${DHIS2_FILESTORE_PROVIDER}
filestore.container = ${DHIS2_FILESTORE_CONTAINER}
filestore.location = ${DHIS2_FILESTORE_LOCATION}
EOF
  [ -n "${DHIS2_FILESTORE_ENDPOINT:-}" ] && echo "filestore.endpoint = ${DHIS2_FILESTORE_ENDPOINT}" >> "${DHIS2_CONF}"
  [ -n "${DHIS2_FILESTORE_IDENTITY:-}" ] && echo "filestore.identity = ${DHIS2_FILESTORE_IDENTITY}" >> "${DHIS2_CONF}"
  [ -n "${DHIS2_FILESTORE_SECRET:-}" ]   && echo "filestore.secret = ${DHIS2_FILESTORE_SECRET}" >> "${DHIS2_CONF}"
  echo "  -> Magasin de fichiers : ${DHIS2_FILESTORE_PROVIDER}"
else
  echo "  -> Magasin de fichiers : filesystem (${DHIS2_HOME}/files)"
fi

# ===========================================================================
# Journalisation
#
# La rotation est configurée explicitement : la valeur par défaut
# logging.file.max_archives = 0 n'offre aucune garantie de dimensionnement du
# volume dhis2-logs.
# ===========================================================================
{
  echo ""
  echo "# --- Journalisation ---"
  echo "logging.file.max_size = ${DHIS2_LOGGING_FILE_MAX_SIZE:-100MB}"
  echo "logging.file.max_archives = ${DHIS2_LOGGING_FILE_MAX_ARCHIVES:-5}"
  [ -n "${DHIS2_LOGGING_QUERY:-}" ]                && echo "logging.query = ${DHIS2_LOGGING_QUERY}"
  [ -n "${DHIS2_LOGGING_QUERY_SLOW_THRESHOLD:-}" ] && echo "logging.query.slow_threshold = ${DHIS2_LOGGING_QUERY_SLOW_THRESHOLD}"
  [ -n "${DHIS2_LOGGING_SESSION_ID:-}" ]           && echo "logging.session_id = ${DHIS2_LOGGING_SESSION_ID}"
  echo "logging.level.org.hisp.dhis = ${DHIS2_LOGGING_LEVEL_DHIS:-INFO}"
  echo "logging.level.org.springframework = ${DHIS2_LOGGING_LEVEL_SPRING:-WARN}"
} >> "${DHIS2_CONF}"

# ===========================================================================
# App Hub
# ===========================================================================
if [ -n "${DHIS2_APPHUB_BASE_URL:-}" ] || [ -n "${DHIS2_APPHUB_API_URL:-}" ]; then
  {
    echo ""
    echo "# --- App Hub ---"
    [ -n "${DHIS2_APPHUB_BASE_URL:-}" ] && echo "apphub.base.url = ${DHIS2_APPHUB_BASE_URL}"
    [ -n "${DHIS2_APPHUB_API_URL:-}" ]  && echo "apphub.api.url = ${DHIS2_APPHUB_API_URL}"
    true
  } >> "${DHIS2_CONF}"
fi

# ===========================================================================
# Sessions
# ===========================================================================
if [ -n "${DHIS2_MAX_SESSIONS_PER_USER:-}" ]; then
  cat >> "${DHIS2_CONF}" <<EOF

# --- Sessions ---
max.sessions.per_user = ${DHIS2_MAX_SESSIONS_PER_USER}
EOF
fi

# ===========================================================================
# API Route
# ===========================================================================
if [ -n "${DHIS2_ROUTE_REMOTE_SERVERS_ALLOWED:-}" ]; then
  cat >> "${DHIS2_CONF}" <<EOF

# --- API Route ---
route.remote_servers_allowed = ${DHIS2_ROUTE_REMOTE_SERVERS_ALLOWED}
EOF
fi

echo "=== init.sh : ${DHIS2_CONF} généré ($(wc -l < "${DHIS2_CONF}") lignes) ==="
echo ""

# ---------------------------------------------------------------------------
# Démarrage de Tomcat
# ---------------------------------------------------------------------------
if [ "${DEBUG:-false}" = "true" ]; then
  echo "=== Démarrage de Tomcat en mode DEBUG (JPDA, port 8000) ==="
  exec catalina.sh jpda run
else
  echo "=== Démarrage de Tomcat ==="
  exec catalina.sh run
fi
