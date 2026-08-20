# =============================================================================
# Distribution DHIS2 ALIMA
#
# Surcouche mince sur l'image officielle DHIS2. Aucun code applicatif n'est
# modifié : on ajoute une configuration Tomcat/JVM et un entrypoint capable de
# générer dhis.conf à partir de variables d'environnement.
#
# Contexte de construction : la RACINE du dépôt (pas le répertoire docker/).
#   docker build -f docker/Dockerfile .
# =============================================================================

# Version DHIS2 — déclarée ICI et nulle part ailleurs.
# La chaîne CI la lit dans ce fichier pour composer le tag d'image.
ARG DHIS2_VERSION=2.39.10.1
FROM dhis2/core:${DHIS2_VERSION}

# --- Métadonnées OCI : permettent de remonter d'une image en production au
#     commit exact qui l'a produite --------------------------------------------
ARG BUILD_DATE=unspecified
ARG VCS_REF=unspecified
ARG VCS_URL=unspecified
ARG VERSION=unspecified
LABEL org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.title="DHIS2 Distribution ALIMA" \
      org.opencontainers.image.description="DHIS2 pour ALIMA — configuration générée au démarrage" \
      org.opencontainers.image.revision=$VCS_REF \
      org.opencontainers.image.source=$VCS_URL \
      org.opencontainers.image.vendor="ALIMA" \
      org.opencontainers.image.version=$VERSION

USER root

# --- Surcouche Tomcat / JVM --------------------------------------------------
# Note : log4j2.xml n'est PAS surchargé. La journalisation se pilote par les
# propriétés logging.* de dhis.conf (cf. docs/architecture-et-cicd.md §5.3).
# Remplacer la configuration log4j2 de DHIS2 risquerait de casser l'écriture
# des journaux sous DHIS2_HOME.
#
# ⚠ PALIERS DE MIGRATION : server.xml vise Tomcat 9/10 (Java 17, cible 2.41).
#   Les images 2.35.14 et 2.36.x reposent sur Tomcat 8.5 / JDK 8-11 — commenter
#   la ligne ci-dessous pour ces paliers. Ils ne servent qu'à faire migrer le
#   schéma et n'ont pas besoin du réglage fin du connecteur.
#   Cf. docs/architecture-et-cicd.md §9.0
# Palier de migration : surcouche Tomcat neutralisée (cf. create-migration-branch.sh)
# COPY docker/server.xml      /usr/local/tomcat/conf/server.xml
COPY docker/setenv.sh       /usr/local/tomcat/bin/setenv.sh

# --- Entrypoint : génère dhis.conf puis démarre Tomcat -----------------------
COPY docker/init.sh         /usr/local/bin/init.sh
COPY docker/wait-for-it.sh  /usr/local/bin/wait-for-it.sh

# --- Métadonnées DHIS2 ALIMA -------------------------------------------------
COPY configuration/         /opt/dhis2/configuration_dhis2

# --- Marque ALIMA ------------------------------------------------------------
# Déposer le logo dans docker/branding/logo_front.png puis décommenter :
# COPY docker/branding/logo_front.png /usr/local/tomcat/logo_front.png

# --- Droits et bascule vers l'utilisateur non-root de l'image de base --------
# IMPORTANT : ce chown conditionne le bon fonctionnement des volumes nommés.
# Un volume nommé hérite, à sa création, du propriétaire du répertoire
# correspondant dans l'image. Si ce chown disparaît, DHIS2 échoue au démarrage
# sur un volume neuf, avec une erreur d'écriture peu explicite.
RUN chmod +x /usr/local/bin/init.sh /usr/local/bin/wait-for-it.sh \
    && mkdir -p /opt/dhis2/files /opt/dhis2/logs \
    && chown -R 1000:1000 \
        /opt/dhis2 \
        /usr/local/tomcat/conf \
        /usr/local/tomcat/logs \
        /usr/local/tomcat/work \
        /usr/local/tomcat/temp \
        /usr/local/tomcat/webapps

# Outils requis par les etapes suivantes. Aucun n'est garanti present : les
# images de la ligne DHIS2 varient d'une version a l'autre. Releve :
#   2.35.14  ni curl ni wget ni nc ; unzip present
#   2.37.10  unzip absent egalement
# D'ou une installation conditionnelle plutot qu'une hypothese.
#
#   unzip  deplie ROOT.war a la construction (voir l'etape suivante)
#   curl   sonde de disponibilite ; sans lui le conteneur reste indefiniment
#          "health: starting" alors que DHIS2 tourne
#
# L'image cible 2.41 embarque curl : seuls les paliers ont besoin de ceci.
RUN if ! command -v unzip >/dev/null || ! command -v curl >/dev/null; then       apt-get update    && apt-get install -y --no-install-recommends unzip curl    && rm -rf /var/lib/apt/lists/*;     fi  && unzip -v > /dev/null  && curl --version | head -1

# Palier de migration : deplier l'archive a la construction.
#
# L'image livre ROOT.war ET un repertoire webapps/ROOT vide. Tomcat y voit un
# contexte deja deploye, plus recent que l'archive, et ne la decompresse donc
# jamais : il sert un repertoire vide en 500 ms, sans une ligne de DHIS2.
# Corriger unpackWARs ne suffit pas - le repertoire fantome prime.
#
# Deplier ici plutot qu'au demarrage rend le resultat deterministe, accelere
# nettement le demarrage, et evite au conteneur d'ecrire dans webapps.
# Le controle sur dhis-service-setting fait echouer la construction si
# l archive change de forme, plutot que de livrer une image qui demarre sur du
# vide. DHIS2 se configure par annotations : il n a pas de WEB-INF/web.xml.
RUN cd /usr/local/tomcat/webapps \
 && rm -rf ROOT && mkdir ROOT && cd ROOT \
 && unzip -q ../ROOT.war \
 && rm -f ../ROOT.war \
 && ls WEB-INF/lib/dhis-service-setting-*.jar \
 && chown -R 1000:1000 /usr/local/tomcat/webapps

# Connecteur AJP : inutilise - Nginx parle HTTP - et refuse par Tomcat 8.5
# faute de secret, ce qui produit un SEVERE a chaque demarrage. Le retirer
# supprime un message trompeur et une surface d'attaque connue (Ghostcat).
# Notre server.xml, utilise par la cible 2.41, n'en declare aucun.
RUN sed -i '/protocol="AJP\/1.3"/d' /usr/local/tomcat/conf/server.xml

USER 1000

ENV DHIS2_HOME=/opt/dhis2

EXPOSE 8080

CMD ["sh", "-c", "/usr/local/bin/init.sh"]
