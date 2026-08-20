# Architecture technique et chaîne CI/CD — DHIS2 ALIMA

Document de référence pour la conception de l'image Docker DHIS2, de la chaîne de
construction/déploiement et de la gestion de la configuration.

| | |
|---|---|
| **Objet** | Migration DHIS2 ALIMA 2.35 → 2.41 |
| **Infrastructure** | GCP `alima-dhis2-prod`, région `europe-west1` |
| **Statut** | En service depuis le 14 août 2026 — <https://dhis2-test.alima.ngo> |
| **Version** | 1.3 |

---

## 1. Objet

Ce document explique **comment DHIS2 est empaqueté, configuré, construit et déployé**, et
pourquoi ces choix ont été faits. Il s'adresse à qui doit intervenir sur la chaîne
elle-même — la modifier, la reproduire, ou comprendre une décision avant de la remettre
en cause.

Pour l'exploitation courante, voir [`aide-memoire.md`](aide-memoire.md). Pour créer
l'infrastructure, voir [`provisionnement-gcp.md`](provisionnement-gcp.md) — et
`scripts/01-setup-gcp.sh`, qui en est la source de vérité.

---

## 2. Principe directeur : une image, plusieurs environnements

L'ensemble de la conception découle d'une règle unique :

> **L'artefact déployé en production est bit pour bit celui qui a été testé en recette.**

Concrètement :

- L'image Docker ne contient **aucune valeur spécifique à un environnement** : ni URL,
  ni nom de base, ni mot de passe, ni activation de fonctionnalité.
- Toute la configuration est injectée **au démarrage du conteneur**, par variables
  d'environnement.
- Une image est **construite une fois**, puis **promue** de test vers production par son
  tag, sans reconstruction.

Ce que cela apporte : ce qui est validé en recette est exactement ce qui part en
production, le retour arrière est une simple redésignation de tag, et un secret ne peut
pas se retrouver figé dans une couche d'image.

---

## 3. Stratégie d'image

### 3.1 Modèle en couches

| Couche | Contenu | Change entre environnements ? |
|---|---|---|
| **Base** | `dhis2/core:<version>` — image officielle DHIS2, non modifiée | Non — figée par le tag de version |
| **Surcouche de configuration** | Entrypoint, configuration Tomcat, JVM, journalisation, métadonnées et éléments de marque ALIMA | Non — figée à la construction |
| **Configuration d'exécution** | `dhis.conf` généré au démarrage à partir des variables d'environnement | Oui — à chaque environnement |

Aucun code applicatif DHIS2 n'est modifié. On se repose intégralement sur la chaîne de
construction officielle DHIS2 (multi-architecture, Java 17 pour la 2.41) et on n'y ajoute
qu'une surcouche de configuration mince.

### 3.2 Image `dhis2-web`

```dockerfile
ARG DHIS2_VERSION=2.41.x
FROM dhis2/core:${DHIS2_VERSION}

ARG BUILD_DATE=unspecified
ARG VCS_REF=unspecified
ARG VCS_URL=unspecified
ARG VERSION=unspecified
LABEL org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.title="DHIS2 Distribution ALIMA" \
      org.opencontainers.image.revision=$VCS_REF \
      org.opencontainers.image.source=$VCS_URL \
      org.opencontainers.image.vendor="ALIMA" \
      org.opencontainers.image.version=$VERSION

USER root

# Surcouche Tomcat / JVM / journalisation
COPY docker/server.xml     /usr/local/tomcat/conf/
COPY docker/log4j2.xml     /usr/local/tomcat/conf/
COPY docker/setenv.sh      /usr/local/tomcat/bin/setenv.sh

# Entrypoint : génère dhis.conf puis démarre Tomcat
COPY docker/init.sh        /usr/local/bin/init.sh
COPY docker/wait-for-it.sh /usr/local/bin/wait-for-it.sh

# Métadonnées et marque ALIMA
COPY configuration/        /opt/dhis2/configuration_dhis2
COPY docker/logo_front.png /usr/local/tomcat/

RUN chmod +x /usr/local/bin/init.sh /usr/local/bin/wait-for-it.sh \
    && mkdir -p /opt/dhis2 \
    && chown -R 1000:1000 /opt/dhis2 /usr/local/tomcat/conf \
       /usr/local/tomcat/logs /usr/local/tomcat/work \
       /usr/local/tomcat/temp /usr/local/tomcat/webapps

USER 1000

CMD ["sh", "-c", "/usr/local/bin/init.sh"]
```

Deux points structurants :

- **Version DHIS2 déclarée une seule fois**, dans `ARG DHIS2_VERSION`. La chaîne CI la
  lit dans le Dockerfile pour composer le tag d'image — elle n'est jamais saisie deux fois.
- **Exécution non-root** : on réutilise l'utilisateur uid/gid 1000 déjà présent dans
  l'image de base plutôt que d'en créer un nouveau, en ajustant simplement les
  propriétaires des répertoires que Tomcat doit écrire.

Les libellés OCI (`revision`, `created`, `version`) permettent de remonter d'une image en
production au commit exact qui l'a produite.

### 3.3 Reverse proxy Nginx

Nginx tourne sur la VM aux côtés du conteneur DHIS2 et assure :

- la **terminaison TLS** (certificat ALIMA) ;
- la compression gzip des réponses JSON/JS/CSS (déterminante pour la réactivité des
  tableaux de bord analytiques) ;
- les en-têtes de sécurité : `Strict-Transport-Security`, `X-Frame-Options`,
  `X-Content-Type-Options`, `Referrer-Policy` ;
- le dimensionnement des tampons proxy et des délais d'attente, réglés pour les requêtes
  analytiques longues et les téléversements (`client_max_body_size 50M`).

Nginx est un conteneur distinct de DHIS2 : un correctif de sécurité Nginx peut être
appliqué sans reconstruire ni redémarrer l'application.

**Modèle de privilèges.** Le processus maître s'exécute en root, les workers sous
l'utilisateur `nginx`. Ce n'est pas un relâchement mais une contrainte de certbot : il
place `live/` et `archive/` en `0700` propriété de root, si bien qu'un processus non-root
ne peut même pas traverser ces répertoires — y compris pour lire `fullchain.pem`, pourtant
en `0644`. Ouvrir ces répertoires exposerait la clé privée : l'inverse du but recherché.

Trois capacités sont donc rendues au maître, et trois seulement : `CHOWN` pour attribuer
les répertoires temporaires, `SETUID` et `SETGID` pour abaisser les privilèges des
workers. Tout le reste est retiré (`cap_drop: ALL`), la racine du conteneur reste en
lecture seule, et **les seuls processus exposés au trafic réseau — les workers — ne sont
pas privilégiés**.

---

## 4. Configuration au démarrage

### 4.1 Le script `init.sh`

C'est la pièce centrale de la surcouche. L'image officielle `dhis2/core` ne sait pas
produire son `dhis.conf` à partir de variables d'environnement ; `init.sh` comble ce
manque. À chaque démarrage de conteneur, il :

1. attend que la base de données soit joignable (`wait-for-it.sh`, délai maximal 60 s) ;
2. assemble `/opt/dhis2/dhis.conf` bloc par bloc à partir des variables `DHIS2_*` ;
3. n'écrit un bloc optionnel que si son **drapeau d'activation** vaut `true` ;
4. démarre Tomcat (`catalina.sh run`, ou `catalina.sh jpda run` si `DEBUG=true`).

Le fichier généré porte un en-tête indiquant qu'il est produit automatiquement, avec son
horodatage — pour éviter toute modification manuelle sur la VM.

### 4.2 Blocs de configuration

| Bloc | Conditionné par | Contenu |
|---|---|---|
| Connexion base | *toujours* | `connection.url`, `connection.username`, `connection.password`, `connection.schema = update` |
| Pool de connexions | variables présentes | `connection.pool.max_size`, `max_idle_time`, `timeout`, `db.pool.type` |
| Identité serveur | *toujours* | `server.base.url`, `server.https` |
| Système | variables présentes | mode lecture seule, expiration de session, protection des vues SQL, exécution serveur des règles de programme, facteur de cache |
| Chiffrement | `DHIS2_ENCRYPTION_PASSWORD` défini | `encryption.password` |
| SSO OpenID | `DHIS2_SSO_OPENID_ACTIVATED=true` | bloc `oidc.provider.openid.0.*` complet |
| Nœud / cluster | `DHIS2_NODE_ID` défini | `node.id`, `node.primary_leader` |
| Supervision | `DHIS2_METRICS_ACTIVE=true` | points de mesure API, JVM, pool BDD, uptime, CPU |
| Redis | `DHIS2_REDIS_ENABLED=true` | hôte, port, mot de passe, SSL |
| Base analytique séparée | `DHIS2_ANALYTICS_DB_ACTIVATED=true` | URL, identifiants, tables non journalisées |
| Stockage de fichiers | `DHIS2_FILESTORE_PROVIDER != filesystem` | fournisseur, conteneur, emplacement, identifiants — **non écrit chez ALIMA**, le fournisseur retenu est `filesystem` (§5.2) |
| Journalisation | variables présentes | taille et rotation des fichiers, journalisation des requêtes, niveaux |
| App Hub | variables présentes | URL de base et d'API |
| Sessions | `DHIS2_MAX_SESSIONS_PER_USER` défini | sessions simultanées par utilisateur |
| API Route | variable présente | serveurs distants autorisés |

Le principe des **drapeaux booléens** rend chaque fonctionnalité activable et testable
indépendamment, sans reconstruction d'image. Une fonctionnalité désactivée n'écrit
strictement rien dans `dhis.conf` — pas de propriété vide susceptible de dérouter DHIS2.

Un mode `INSECURE=true` force `server.https = off` ; il est réservé au poste de
développement et ne doit jamais figurer dans la configuration d'un environnement serveur.

### 4.3 Dimensionnement de la JVM

Le fichier `setenv.sh`, lu par Tomcat au démarrage, n'utilise **pas** de `-Xmx` figé :

```sh
JAVA_OPTS="-XX:MaxRAMPercentage=80.0"
JAVA_OPTS="${JAVA_OPTS} -XX:+UseG1GC"
JAVA_OPTS="${JAVA_OPTS} -XX:+UseStringDeduplication"
JAVA_OPTS="${JAVA_OPTS} -Dfile.encoding=UTF-8"
JAVA_OPTS="${JAVA_OPTS} -Ddhis2.home=/opt/dhis2"
```

La JVM détecte la mémoire allouée au conteneur et dimensionne son tas à 80 % de
celle-ci. Redimensionner la VM ou la limite mémoire du conteneur suffit : aucune
modification d'image, aucun risque d'un `-Xmx` devenu incohérent avec la machine.

Une variable d'échappement `DHIS2_EXTRA_JAVA_OPTS` permet d'ajouter ponctuellement des
options JVM sans toucher à l'image.

---

## 5. Architecture de déploiement

```
Utilisateurs ──HTTPS──▶ Nginx (443, TLS)
                          │ localhost:8080
                          ▼
                   DHIS2 / Tomcat (Java 17)
                          │ IP privée (VPC, Private Service Access)
                          ▼
                Cloud SQL PostgreSQL 16
```

Les deux conteneurs sont pilotés par `docker compose` sur `vm-dhis2-app`
(e2-standard-2, Ubuntu 22.04). La base n'a **aucune IP publique** ; SSH n'est accessible
que via IAP.

### 5.1 `DHIS2_HOME` et persistance

Tout ce que DHIS2 écrit durablement se trouve sous **`DHIS2_HOME`**, soit `/opt/dhis2`
par défaut sous Linux :

```
/opt/dhis2/
├── dhis.conf          généré au démarrage par init.sh
├── files/             magasin de fichiers (filestore) — documents, images, pièces jointes
└── logs/              journaux applicatifs DHIS2
    ├── dhis.log                    journal principal (inclut les traitements de fond)
    ├── dhis-audit.log              journal d'audit
    ├── dhis-analytics-table.log    génération des tables analytiques
    ├── dhis-data-exchange.log      échanges de données
    ├── dhis-data-sync.log          synchronisations
    ├── dhis-metadata-sync.log      synchronisation des métadonnées
    └── dhis-push-analysis.log      analyses poussées
```

> Liste relevée sur une instance 2.41.9.1 réelle. Elle dépasse les quatre
> fichiers documentés par DHIS2 et varie d'une version à l'autre : la collecte
> des journaux utilise donc un motif `*.log`, jamais une énumération figée.

Ces répertoires **doivent survivre** au remplacement du conteneur — ce qui est précisément
ce qui se produit à chaque déploiement. D'où trois volumes Docker nommés.

### 5.2 Volumes Docker

| Volume | Point de montage | Contenu | Sauvegarde | Critique ? |
|---|---|---|---|---|
| `dhis2-home` | `/opt/dhis2` | `dhis.conf` généré | non | non — regénéré à chaque démarrage |
| `dhis2-files` | `/opt/dhis2/files` | magasin de fichiers | **oui — hebdomadaire vers Cloud Storage + snapshot quotidien** | **oui — irrécupérable si perdu** |
| `dhis2-logs` | `/opt/dhis2/logs` | journaux applicatifs | non — rotation en place | non |

> **Nom effectif des volumes.** Compose préfixe les volumes du nom de projet. Celui-ci
> est fixé à `dhis2` en tête du `docker-compose.yml` : les volumes s'appellent donc
> `dhis2_dhis2-home`, `dhis2_dhis2-files` et `dhis2_dhis2-logs`, identiquement en local et
> sur la VM. Sans ce nom fixé, il variait selon le répertoire de travail, et toute
> référence externe — agent Ops, sauvegardes, diagnostic — dépendait de l'endroit d'où
> l'on travaillait.

Trois volumes plutôt qu'un seul, parce que leurs **cycles de vie diffèrent** : les
fichiers sont irremplaçables et doivent être sauvegardés ; les journaux sont volumineux,
rotatifs et jetables ; `dhis.conf` est reconstruit à chaque démarrage. Les mélanger
reviendrait soit à sauvegarder des gigaoctets de journaux inutiles, soit à faire courir
un risque au magasin de fichiers.

**Le magasin de fichiers reste sur disque** (`DHIS2_FILESTORE_PROVIDER=filesystem`) :
tant que DHIS2 tourne sur une seule VM, le stockage objet n'apporte rien qu'un snapshot
de disque persistant ne couvre déjà. Ce choix doit toutefois être fait **maintenant, pas
plus tard** : la documentation DHIS2 avertit que déplacer les fichiers d'un fournisseur
de stockage à un autre en préservant l'intégrité des références en base est une opération
complexe.

Trois points de mise en œuvre :

- **Disque SSD obligatoire.** La documentation DHIS2 est explicite : le SSD est
  indispensable en production. Les volumes sont hébergés sur le disque persistant SSD de
  la VM.
- **Propriété des volumes.** Un volume nommé hérite, à sa création, du propriétaire du
  répertoire correspondant dans l'image. Le `chown -R 1000:1000 /opt/dhis2` du Dockerfile
  (§3.2) est donc ce qui garantit que le conteneur non-root pourra écrire. C'est un piège
  classique : si le `chown` disparaît du Dockerfile, DHIS2 échoue au démarrage sur un
  volume neuf.
- **`dhis.conf` contient des secrets en clair** une fois généré. Le fichier est créé en
  mode `0600` et le volume `dhis2-home` hérite de la protection du disque. Les snapshots
  de ce disque sont à traiter comme des données sensibles.

### 5.3 Journalisation

DHIS2 indique que la journalisation vers `catalina.out` / la sortie standard sera
progressivement abandonnée et **recommande de s'appuyer sur les journaux sous
`DHIS2_HOME`**. La conception en tient compte :

| Flux | Destination | Collecte |
|---|---|---|
| Journaux applicatifs DHIS2 | volume `dhis2-logs` | agent Ops de la VM, en lecture sur le chemin du volume |
| Sortie standard Tomcat | tmpfs (éphémère) | — |
| Journaux Nginx | sortie standard du conteneur | pilote de journalisation Docker → Cloud Logging |

**La rotation doit être configurée explicitement.** Par défaut,
`logging.file.max_archives = 0` : aucune archive n'est conservée et les fichiers sont
plafonnés, mais un paramétrage explicite évite toute surprise sur la taille du volume.
Valeurs retenues :

```properties
logging.file.max_size     = 100MB
logging.file.max_archives = 5
logging.level.org.hisp.dhis      = INFO
logging.level.org.springframework = WARN
```

Le volume `dhis2-logs` est ainsi borné de façon prévisible et ne peut pas saturer le
disque de la VM.

### 5.4 Esquisse de `docker-compose.yml`

> Extrait de principe. La version qui fait foi est
> [`docker/docker-compose.yml`](../docker/docker-compose.yml) — elle ajoute
> notamment le service de base local (profil `local`) et les services de
> sauvegarde/restauration (profils `backup` / `restore`).

```yaml
services:
  dhis2:
    image: europe-west1-docker.pkg.dev/alima-dhis2-prod/dhis2-images/dhis2-core:${IMAGE_TAG}
    env_file: [.env]                 # généré depuis Secret Manager, hors dépôt
    volumes:
      - dhis2-home:/opt/dhis2
      - dhis2-files:/opt/dhis2/files
      - dhis2-logs:/opt/dhis2/logs
      - type: tmpfs
        target: /tmp
      - type: tmpfs
        target: /usr/local/tomcat/temp
      - type: tmpfs
        target: /usr/local/tomcat/logs
      - type: tmpfs
        target: /usr/local/tomcat/work/Catalina/localhost/ROOT
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:8080/api/system/ping"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 300s             # DHIS2 démarre lentement, surtout après migration
    restart: unless-stopped
    read_only: true                  # racine en lecture seule — seuls les volumes sont inscriptibles
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]

  nginx:
    image: europe-west1-docker.pkg.dev/alima-dhis2-prod/dhis2-images/dhis2-nginx:${IMAGE_TAG}
    depends_on: [dhis2]
    # Nginx écoute sur 8080/8443 dans le conteneur : sans capacités, un
    # processus non-root ne peut pas se lier aux ports privilégiés. C'est
    # Docker qui publie 80/443 côté hôte.
    ports: ["80:8080", "443:8443"]
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
    restart: unless-stopped
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    tmpfs: [/tmp, /var/cache/nginx, /var/run]

volumes:
  dhis2-home: {}
  dhis2-files: {}
  dhis2-logs: {}
```

Le durcissement (`read_only`, `cap_drop: ALL`, `no-new-privileges`, `tmpfs` pour les
répertoires temporaires de Tomcat) suit le déploiement Docker de référence publié par
l'équipe DHIS2. Il n'a de coût qu'à la mise au point : la racine du conteneur devient
non inscriptible, ce qui rend visible toute écriture non prévue hors des volumes.

### 5.5 Sauvegarde et restauration du magasin de fichiers

Le magasin de fichiers est **hors base de données** : une sauvegarde PostgreSQL ne le
couvre pas. Une base restaurée sans son magasin de fichiers présente des références
brisées vers des documents absents.

| Élément | Mécanisme | Fréquence | Rétention |
|---|---|---|---|
| Base de données | sauvegardes automatiques Cloud SQL + PITR | continu | selon politique Cloud SQL |
| Base — export logique | `pg_dump` vers Cloud Storage | hebdomadaire | 30 jours |
| **Magasin de fichiers** | **archive du volume `dhis2-files` vers Cloud Storage** | **hebdomadaire** | **30 jours** |
| Volumes (bloc) | snapshot du disque persistant | quotidien | selon politique |

Les opérations de sauvegarde et de restauration du magasin de fichiers sont portées par
des services `docker compose` dédiés, activés par **profils** (`--profile backup`,
`--profile restore`), montant `dhis2-files` en lecture seule. Elles ne tournent donc pas
en permanence et ne peuvent pas interférer avec le service.

Le test de restauration semestriel prévu au contrat de support doit porter sur **les
deux** : base *et* magasin de fichiers.

---

## 6. Gestion des secrets

Aucun secret n'entre dans le dépôt Git, ni dans une couche d'image, ni dans un fichier
de configuration versionné.

| Contexte | Stockage | Injection |
|---|---|---|
| Poste de développement | fichier `.env` **non versionné** | directive `env_file` de docker compose |
| Chaîne CI/CD | Secret Manager | accès par le compte de service Cloud Build |
| VM (test et production) | **Secret Manager** | lecture au démarrage du service, matérialisée en fichier `.env` à permissions restreintes, hors dépôt |

Variables à traiter obligatoirement comme secrets :

| Variable | Contenu |
|---|---|
| `DHIS2_DATABASE_PASSWORD` | mot de passe PostgreSQL du compte applicatif |
| `DHIS2_DATABASE_USER` | nom d'utilisateur PostgreSQL — traité en secret par défense en profondeur |
| `DHIS2_ENCRYPTION_PASSWORD` | clé de chiffrement des données DHIS2 |
| `DHIS2_SSO_OPENID_CLIENT_SECRET` | secret client OAuth, si le SSO est activé |
| `DHIS2_FILESTORE_SECRET` | clé secrète de stockage objet, si utilisé |

Organisation dans Secret Manager :

```
dhis2-db-password            mot de passe BDD production
dhis2-db-user                utilisateur BDD production
dhis2-encryption-password    clé de chiffrement
dhis2-fqdn                   URL publique de l'instance
```

Le dépôt ne contient que des **modèles** : `dhis.conf.template` (référence complète des
propriétés, commentée) et `.env.example` (liste exhaustive des variables, valeurs
factices). Ils servent de documentation vivante ; toute variable ajoutée à `init.sh` doit
y être reportée dans le même commit.

> ⚠️ Le `.gitignore` doit exclure, dès le premier commit : `.env`, `*.env.local`,
> `dhis.conf` (le fichier réel, pas le modèle), `*.sql`, `*.dump`, `*.backup`, `*.pem`,
> `*.key`. Le point sur les dumps n'est pas théorique : il s'agit de données de santé,
> couvertes par l'article 13 du CGA ALIMA.

---

## 7. Chaîne CI/CD

### 7.1 Séparation construction / déploiement

Construire et déployer sont **deux opérations distinctes**, portées par des
configurations distinctes.

| Pipeline | Déclencheur | Rôle |
|---|---|---|
| `cloudbuild.yaml` | push sur `main` (hors `**/*.md`) | construit l'image, la pousse dans Artifact Registry |
| `cloudbuild-deploy.yaml` | **manuel**, paramètre `_IMAGE_TAG` | déploie un tag existant sur l'environnement visé |

Pourquoi les séparer : un déploiement doit pouvoir rejouer **n'importe quel tag déjà
construit** — notamment le précédent, pour un retour arrière — sans dépendre d'une
reconstruction ni de l'état actuel de `main`.

### 7.2 Construction

```
push sur main
   │
   ▼
Cloud Build
   ├── lit ARG DHIS2_VERSION dans docker/Dockerfile
   ├── compose le tag : <version>-<YYYYMMDD>-<build-id>
   ├── docker build (--pull, injection de VCS_REF / BUILD_DATE / VERSION)
   └── push vers Artifact Registry
```

Le `--pull` garantit qu'on repart toujours de l'image de base officielle à jour. Les
arguments de construction inscrivent le commit et l'horodatage dans les libellés de
l'image.

**Nommage des tags** — un format unique :

```text
<version-dhis2>.<YYYYMMDD>.<n° du jour>.<commit-court>

2.41.9.1.20260814.01.556073b
```

Les quatre composantes répondent aux quatre questions qu'on se pose devant une image en
production :

| Composante | Question |
|---|---|
| `2.41.9.1` | quelle version de DHIS2 ? |
| `20260814` | construite quand ? |
| `01` | la combientième ce jour-là — **laquelle est la plus récente ?** |
| `556073b` | à partir de quel code ? |

**Pourquoi un numéro alors que le commit identifie déjà l'image.** Le commit dit *d'où
vient* le code, mais deux SHA ne s'ordonnent pas entre eux : devant `…20260814.a1b2c3d`
et `…20260814.e4f5g6h`, rien n'indique laquelle est la plus récente. Le numéro tranche.
Le cas est fréquent en journée de mise au point, où plusieurs constructions se succèdent
sur la même version.

Le compteur est calculé en interrogeant Artifact Registry : on compte les tags déjà
publiés pour la même version et la même date. **Le registre est donc la seule source de
vérité** — aucun compteur à maintenir ailleurs, et la suppression d'une image ancienne ne
fausse pas le classement des suivantes.

> Limite assumée : deux constructions simultanées liraient le même compte et produiraient
> le même numéro, la seconde écrasant le tag de la première. À l'échelle d'ALIMA — une
> personne, un déploiement à la fois — le cas ne se présente pas. Si la cadence augmentait,
> la parade serait d'activer l'immuabilité des tags sur le dépôt Artifact Registry, qui
> ferait échouer le second envoi au lieu de l'écraser silencieusement.

**Pas de préfixe distinguant intégration et publication.** Un tel préfixe supposait deux
natures d'artefacts, donc deux destinations. Il n'y en a qu'une : la production, après
validation locale (§8). Étiqueter `dev.` une image destinée à la production serait
mensonger, et la mention finirait par être ignorée — ce qui est pire que son absence.

Le commit est **obligatoire** : `gcloud builds submit` n'envoie pas le répertoire `.git`
à Cloud Build, la construction manuelle doit donc fournir `_VCS_REF`. À défaut, le
pipeline échoue avec un message explicite plutôt que de publier une image anonyme.

Aucun tag mobile n'est utilisé : `latest` n'est ni produit ni déployable, sans quoi le
retour arrière et l'audit deviendraient impossibles.

### 7.3 Déploiement

```text
[LOCAL]  docker compose --profile local up
         validation du tag : démarrage, migrations, parcours fonctionnels
   │
   ▼
Déclenchement manuel avec _IMAGE_TAG
   │
   ▼
[APPROBATION MANUELLE]  ← approbateur désigné (§9.4 du provisionnement)
   │
   ▼
[PRODUCTION]  1. validate    tag fourni, images présentes dans le registre
              2. upload      docker-compose.yml et scripts vers la VM
              3. render-env  .env généré depuis Secret Manager, par la VM
              4. init-db     extensions PostgreSQL (postgis, btree_gin, pg_trgm)
              5. deploy      docker compose pull && up -d
              6. verify      attente de l'état healthy, sonde /dhis-web-login/
```

**Toutes les commandes distantes sont des scripts présents sur la VM**, appelés par une
commande d'une seule ligne. Le shell écrit directement dans le YAML traverse trois
niveaux d'interprétation — substitutions Cloud Build, shell local, shell distant — où
chaque `$`, chaque apostrophe et chaque guillemet devient un piège, et où un
`set -euo pipefail` peut rester sans effet, masquant les échecs intermédiaires.

L'étape `init-db` est rejouée à chaque déploiement et non réservée à la première
installation : une base restaurée depuis une sauvegarde retrouve ainsi ses extensions
sans que personne ait à y penser. Sans elles, DHIS2 échoue au démarrage sur une
exception Hibernate qui n'en désigne pas la cause.

L'approbation manuelle est portée par le **trigger Cloud Build** de production, pas par
le contenu du dépôt : personne ne peut la contourner par un commit.

Chaque étape de déploiement est **idempotente** et se termine par une vérification
active — on n'annonce un déploiement réussi qu'après que le conteneur soit passé à l'état
`healthy`.

> **Conséquence de l'absence d'environnement de test hébergé** (§8) : la validation d'un
> tag repose entièrement sur l'exécution locale. Un tag ne doit jamais être déployé sans
> avoir été démarré en local au préalable — c'est la seule barrière avant la production.

### 7.4 Retour arrière

Redéclencher le pipeline de déploiement avec le tag précédent. Aucune reconstruction,
aucune manipulation manuelle sur la VM. Le délai de retour arrière est celui d'un
`docker compose pull && up -d`, soit quelques minutes.

La politique de nettoyage d'Artifact Registry (5 versions conservées, purge au-delà de
30 jours) doit être calibrée pour qu'un tag encore susceptible de servir au retour
arrière ne soit jamais purgé.

---

## 8. Environnements

**Un seul environnement est hébergé : la production.** Il n'y a pas d'instance de test
sur GCP — décision assumée pour contenir le coût. La validation se fait localement.

| | Local | Production |
|---|---|---|
| Hébergement | poste de travail, `docker compose --profile local` | VM `vm-dhis2-app` |
| Déploiement | `up --build` | **approbation manuelle obligatoire** |
| Base de données | conteneur PostgreSQL 16 + PostGIS | Cloud SQL `pg16-dhis2-prod` |
| `DHIS2_FQDN` | `http://localhost:8080` | URL de production ALIMA |
| Configuration | `.env` écrit à la main depuis `.env.example` | `.env` généré depuis Secret Manager |
| TLS | désactivé (`INSECURE=true`) | Nginx + Let's Encrypt |
| Nginx | non démarré | démarré |
| Sauvegardes | aucune | Cloud SQL auto + PITR, magasin de fichiers hebdo, snapshots |

**Ce qui change entre les deux : des variables d'environnement, et l'origine des
secrets.** L'image et le `docker-compose.yml` sont les mêmes fichiers. Si un correctif
nécessite de modifier autre chose qu'une variable, c'est le signe que quelque chose a été
figé au mauvais endroit.

### 8.1 Ce que l'absence d'environnement de test implique

Trois conséquences à assumer :

1. **La validation locale est la seule barrière avant la production.** Aucun tag ne doit
   partir en production sans avoir démarré en local — migrations comprises.
2. **Le local ne reproduit pas tout.** Cloud SQL, l'IP privée, Nginx avec TLS, l'agent
   Ops et l'approbation Cloud Build ne sont exercés qu'en production. Le premier
   déploiement réel reste donc le premier test grandeur nature de ces éléments.
3. **La recette utilisateur (S3) n'a pas de plateforme.** Faire tester l'application par
   les référents ALIMA depuis un poste de développement n'est pas praticable. Piste à
   arbitrer le moment venu : créer une instance temporaire pour la seule semaine de
   recette, puis la supprimer — le coût reste borné à cette période.

---

## 9. Spécificité ALIMA : la migration par paliers

Point de divergence majeur avec une exploitation courante : le passage de 2.35 à 2.41
n'est pas un simple changement de tag. Les migrations de schéma Flyway doivent
s'appliquer **palier par palier** :

```
2.35 ──▶ 2.36 ──▶ 2.38 ──▶ 2.40 ──▶ 2.41
 │
 └── image 2.35.14 (seul tag publié pour cette ligne),
     appliquée directement sur la base 2.35.0
```

Chaque palier suit la même mécanique :

1. `ARG DHIS2_VERSION` positionné sur la version du palier ;
2. construction de l'image correspondante ;
3. démarrage sur la copie de base — les migrations Flyway s'exécutent ;
4. **validation avant de passer au palier suivant** : démarrage sans erreur, journaux
   Flyway propres, connexion applicative, cohérence des métadonnées, génération des
   tables analytiques.

Cette conception sert directement cet objectif : chaque palier est une image traçable,
construite par la même chaîne, et l'on conserve à chaque étape la possibilité de repartir
du palier précédent.

### 9.0 Contrainte découverte : les images disponibles en amont

Vérification faite sur le registre officiel `dhis2/core` :

| Ligne | Tags publiés | Conséquence |
|---|---|---|
| 2.35 | **`2.35.14` uniquement** | La version actuelle d'ALIMA (2.35.0) n'a **aucune image officielle** |
| 2.36 | 2.36.x complet | — |
| 2.38 / 2.40 | complets | — |
| 2.41 | jusqu'à `2.41.9.1` | version cible retenue |

Deux implications directes :

1. **Le palier 2.35 utilise l'image 2.35.14.** Les correctifs d'une même ligne mineure
   n'apportent pas de changement de schéma : l'image 2.35.14 démarre donc directement sur
   la base 2.35.0 d'ALIMA, sans étape intermédiaire. La chaîne de paliers reste inchangée.
2. **La surcouche Tomcat n'est pas portable sur toute la chaîne.** Les images 2.35.14
   sont construites sur **Tomcat 8.5/9 avec JDK 8 ou 11**, alors que `docker/server.xml`
   vise Tomcat 9/10 (Java 17, cible 2.41). Sur les premiers paliers, il faut donc
   **neutraliser le `COPY` de `server.xml`** dans le Dockerfile et ne le réactiver qu'à
   partir de 2.40. Les paliers intermédiaires ne servent qu'à faire migrer le schéma :
   ils n'ont pas besoin du réglage fin du connecteur.

Le premier point ne change rien à la conception ; le second demande une variante de
Dockerfile pour les paliers anciens.

**Règle absolue rappelée** : la base de production 2.35 n'est jamais modifiée. La
migration se déroule intégralement sur une copie, en parallèle, jusqu'à la bascule
finale.

### 9.1 Le magasin de fichiers — rien à migrer

En règle générale, **le dump PostgreSQL ne contient pas les fichiers** : ils vivent dans
`files/` sous `DHIS2_HOME` et doivent être copiés séparément, sans quoi la base migrée
référence des documents introuvables.

**Constaté le 20 août 2026 : ce répertoire est vide sur l'instance 2.35 d'ALIMA.** Aucune
pièce jointe, aucun document chargé. L'étape de copie disparaît donc de la bascule, et avec
elle le dimensionnement de disque qu'elle conditionnait.

> Le mécanisme reste en place et reste nécessaire — `backup-filestore.sh`,
> `restore-filestore.sh`, volume `dhis2-files`, sauvegarde hebdomadaire. Dès la 2.41 en
> service, les utilisateurs pourront déposer des documents : c'est l'étape de *migration*
> qui disparaît, pas la protection. La décision **D17** conserve toute sa portée.

Deux validations conditionnent le Go-Live et sont propres à ALIMA :

- **intégration Power BI** — les connexions et jeux de données doivent être vérifiés sur
  la 2.41 avant la bascule ;
- **restauration** — un test de restauration complet doit être exécuté avant, et une
  fois après la mise en production.

---

## 10. Structure cible du dépôt

```
.
├── README.md                     présentation, démarrage rapide, conventions
├── .gitignore                    secrets, dumps, certificats — exclus par défaut
├── cloudbuild.yaml               construction : images → Artifact Registry
├── cloudbuild-deploy.yaml        déploiement : tag → environnement (approbation en prod)
├── docker/
│   ├── Dockerfile                image dhis2-core ALIMA (FROM dhis2/core)
│   ├── docker-compose.yml        pile applicative + profils local/backup/restore
│   ├── .env.example              liste exhaustive des variables, valeurs factices
│   ├── dhis.conf.template        référence des propriétés générées par init.sh
│   ├── init.sh                   entrypoint : génère dhis.conf, démarre Tomcat
│   ├── setenv.sh                 options JVM (dimensionnement proportionnel)
│   ├── server.xml                Tomcat : RemoteIpValve, relaxedQueryChars
│   ├── wait-for-it.sh            attente de disponibilité de la base
│   └── nginx/
│       ├── Dockerfile            image dhis2-nginx
│       └── nginx.conf            TLS, gzip, en-têtes de sécurité, tampons proxy
├── configuration/                métadonnées DHIS2 à charger (JSON)
├── scripts/
│   ├── 01-setup-gcp.sh           provisionnement — source de vérité
│   ├── 02-setup-triggers.sh      déclencheurs Cloud Build (build + deploy)
│   ├── install-vm.sh             Docker, gcloud, TLS, agent Ops sur la VM
│   ├── dhis2ctl.sh               exploitation courante sur la VM
│   ├── render-env.sh             ┐
│   ├── init-database.sh          │ appelés par le pipeline de déploiement,
│   ├── deploy-stack.sh           │ exécutés sur la VM
│   ├── wait-healthy.sh           ┘
│   ├── backup-filestore.sh       archive le magasin de fichiers vers Cloud Storage
│   ├── restore-filestore.sh      restaure le magasin de fichiers depuis une archive
│   └── 99-cleanup-gcp.sh         suppression de l'infrastructure
└── docs/
    ├── architecture-et-cicd.md   ce document
    ├── aide-memoire.md           commandes du quotidien
    ├── provisionnement-gcp.md    mode opératoire pas à pas de l'infrastructure
    ├── plan-migration.md        déroulé des paliers et bascule
    └── variables-environnement.md  taxonomie des variables DHIS2_* — à rédiger
```

**Toutes les commandes distantes du pipeline sont des scripts déposés sur la VM**, jamais
du shell écrit dans le YAML : celui-ci traverserait trois niveaux d'interprétation —
substitution Cloud Build, shell local, shell distant — où chaque `$` et chaque apostrophe
devient un piège, et où un `set -euo pipefail` peut rester sans effet en masquant les
échecs intermédiaires.

**Pas de `log4j2.xml`.** La journalisation se pilote par les propriétés
`logging.*` de `dhis.conf`, comme le documente DHIS2. Remplacer la configuration
log4j2 de l'image de base risquerait de casser l'écriture des journaux sous
`DHIS2_HOME` — précisément ce sur quoi repose la collecte (§5.3). Le déploiement
Docker de référence DHIS2 laisse d'ailleurs ce montage commenté.

---

## 11. Décisions de conception

| Réf. | Décision | Justification |
|---|---|---|
| **D1** | Utiliser `dhis2/core` comme base non modifiée | On hérite de la chaîne de construction officielle DHIS2 (multi-architecture, Java 17) et de ses correctifs, sans dette de maintenance |
| **D2** | Générer `dhis.conf` au démarrage, pas à la construction | Un seul artefact pour tous les environnements ; aucun secret dans une couche d'image |
| **D3** | Drapeaux booléens pour les blocs optionnels | Chaque fonctionnalité (SSO, supervision, Redis) est activable et testable isolément, sans reconstruction |
| **D4** | Dimensionnement JVM proportionnel (`MaxRAMPercentage`) | S'adapte automatiquement au redimensionnement de la VM ; supprime une classe entière d'incidents mémoire |
| **D5** | Nginx en conteneur distinct | Correctif de sécurité Nginx applicable sans toucher à DHIS2 |
| **D6** | Tags d'image immuables, jamais `latest` en déploiement | Un tag en production désigne toujours exactement la même image — condition du retour arrière et de l'audit |
| **D7** | Construction et déploiement dans deux pipelines séparés | Permet de redéployer n'importe quel tag antérieur sans reconstruction |
| **D8** | Approbation manuelle portée par le trigger, pas par le dépôt | Le contrôle ne peut pas être contourné par un commit |
| **D9** | Cloud SQL managé plutôt que PostgreSQL sur la VM | Sauvegardes automatiques, PITR, correctifs et supervision pris en charge ; supprime le principal point de fragilité de l'instance actuelle |
| **D10** | Base sans IP publique ; VM avec adresse statique mais port 22 fermé sauf IAP | La base n'est joignable que depuis le VPC. La VM doit servir le web, donc exposer 80/443 — c'est le pare-feu, pas l'absence d'adresse, qui protège SSH. Adresse statique et non éphémère : une adresse qui change casserait le DNS et le renouvellement TLS |
| **D11** | Aucun identifiant d'infrastructure en dur dans les pipelines | Les identifiants de sous-réseau, de service et de projet passent par des substitutions ; le dépôt reste transposable et lisible |
| **D12** | Magasin de fichiers sur disque (`filestore.provider = filesystem`) | Cohérent avec le modèle mono-VM ; couvert par les snapshots. Choix à figer dès le départ : la documentation DHIS2 avertit qu'un changement ultérieur de fournisseur est complexe à mener sans casser les références en base |
| **D13** | Trois volumes distincts (`home`, `files`, `logs`) plutôt qu'un seul | Cycles de vie et politiques de sauvegarde différents : les fichiers sont irremplaçables, les journaux sont jetables, `dhis.conf` est reconstruit |
| **D14** | S'appuyer sur les journaux de `DHIS2_HOME`, pas sur `catalina.out` | DHIS2 annonce l'abandon progressif de la journalisation vers la sortie standard ; la sortie Tomcat est donc laissée en tmpfs et l'agent Ops lit le volume `dhis2-logs` |
| **D15** | Rotation des journaux configurée explicitement | La valeur par défaut `logging.file.max_archives = 0` n'offre aucune garantie de dimensionnement ; un paramétrage explicite borne le volume de façon prévisible |
| **D16** | Durcissement des conteneurs (racine en lecture seule, `cap_drop: ALL`, `no-new-privileges`, tmpfs) | Aligné sur le déploiement Docker de référence DHIS2 ; rend visible toute écriture hors des volumes prévus |
| **D17** | Sauvegarde du magasin de fichiers distincte de celle de la base | Un dump PostgreSQL ne contient pas les fichiers : restaurer la base seule produit des références brisées |

---

## 12. Points à trancher avant implémentation

| # | Question | Impact | Proposition |
|---|---|---|---|
| 1 | ~~Volumétrie du répertoire `files/` sur l'instance 2.35 ?~~ | — | **Tranché le 20 août 2026 : le répertoire est vide.** Rien à copier à la bascule ; le dimensionnement du disque dépend désormais des seules tables analytiques (§9.1) |
| 2 | SSO OpenID à activer ? Sur quel annuaire ? | Prévoir le bloc et le secret dès la conception, même désactivé | Prévoir le bloc, `DHIS2_SSO_OPENID_ACTIVATED=false` au départ |
| 3 | ~~Sur quelle plateforme se fera la recette utilisateur ?~~ | — | **Tranché : `dhis2-test.alima.ngo`**, en service depuis le 14 août 2026 et portant la base migrée en 2.41. C'est l'instance que les référents ALIMA testent |
| 4 | Rétention Artifact Registry compatible avec la fenêtre de retour arrière ? | Un tag purgé = retour arrière impossible | Vérifier que les 5 versions conservées couvrent le besoin post-bascule |
| 5 | ~~`CLAUDE.md` versionné ou ignoré ?~~ | — | **Tranché : ignoré.** L'outillage d'assistance relève du poste de travail, pas de la définition du projet ; la documentation de référence est dans `docs/` |
| 6 | Qui déclenche les déploiements, qui les approuve ? | Sans séparation des deux rôles, l'approbation reste une formalité | Deux comptes distincts — voir §9.4 du provisionnement |
| 7 | ~~Point de terminaison de la sonde de disponibilité~~ | — | **Tranché par l'expérience.** Production : `/dhis-web-login/`, seul chemin répondant 200 sans session en 2.41. Paliers : `/api/system/ping`, via leur surcharge — `dhis-web-login` n'existe pas dans les versions anciennes. Et `curl` **n'est pas** présent partout : absent de `dhis2/core:2.35.14`, les images de palier l'installent |
| 8 | Journalisation d'audit système (`SYSTEM_AUDIT_ENABLED`) activée ? | Volumétrie des journaux et de la base, exigences de traçabilité | Désactivée par défaut ; à activer si ALIMA a une exigence d'audit explicite |

---

## 13. Sources de référence

La conception s'appuie sur la documentation officielle DHIS2 et sur le déploiement Docker
de référence publié par l'équipe DHIS2 :

| Source | Ce qui en est repris |
|---|---|
| [Documentation d'administration DHIS2](https://docs.dhis2.org/en/manage/manage.html) | prérequis serveur, SSD obligatoire en production, dimensionnement proportionnel à la RAM et au CPU |
| [Référence `dhis.conf`](https://docs.dhis2.org/en/manage/reference/dhisconf.html) | propriétés de configuration et emplacement de `DHIS2_HOME` |
| [Stockage de fichiers](https://docs.dhis2.org/en/manage/reference/file-storage.html) | fournisseurs disponibles, emplacement `files/` sous `DHIS2_HOME`, avertissement sur le changement de fournisseur, exigence de sauvegarde et de protection d'accès |
| [Journalisation](https://docs.dhis2.org/en/manage/reference/logging.html) | fichiers produits sous `DHIS2_HOME/logs`, propriétés de rotation, abandon annoncé de `catalina.out` |
| [Déploiement Docker de référence DHIS2](https://github.com/dhis2/docker-deployment) | organisation des volumes, tmpfs pour les répertoires temporaires de Tomcat, durcissement des conteneurs, sonde de disponibilité, sauvegarde/restauration par profils compose |

> **Réserve importante** : le dépôt de déploiement Docker de référence est publié en
> version 1.0 comme « prêt pour test public » et **n'est pas recommandé par ses auteurs
> pour un usage en production** à ce stade. Nous en reprenons les *choix techniques*
> — organisation des volumes, durcissement, séparation des sauvegardes — sans l'adopter
> tel quel. La documentation DHIS2 recommande, pour la production, l'installation
> automatisée par Ansible ; le choix du conteneur pour ALIMA est délibéré et se justifie
> par l'exigence de chaîne CI/CD et de reproductibilité entre paliers de migration.

---

## 14. Suites

État au **20 août 2026**.

### Fait

1. **Dépôt** conforme au §10, avec une addition née de la migration : chaque branche
   `migration/*` porte son propre `docker/docker-compose.override.yml`, que Compose charge
   automatiquement et que le pipeline téléverse. La branche déployée suffit à déterminer la
   configuration — aucun paramètre à renseigner, donc aucun à oublier.
2. **Infrastructure GCP** provisionnée le 14 août 2026, en service sur
   <https://dhis2-test.alima.ngo> — voir [`provisionnement-gcp.md`](provisionnement-gcp.md).
3. **Sept images construites et éprouvées**, de 2.35.14 à 2.41.9.1. Les tags se résolvent
   par `./scripts/list-palier-images.sh`, jamais par une table recopiée.
4. **Export de production importé** — 27 min pour 31 Go, 457 tables.
5. **Montée 2.35 → 2.41 aboutie** sur une copie de la base ALIMA, palier par palier, le
   20 août 2026. Déroulé et incidents dans [`plan-migration.md`](plan-migration.md).

### En cours

6. **Génération des tables analytiques** sur la 2.41. Sa durée et la taille de base
   résultante sont les **deux dernières inconnues** du dimensionnement et de la fenêtre de
   bascule.

### Suites immédiates

7. **Recette par les référents ALIMA** sur `dhis2-test.alima.ngo`. Trois points appellent
   une vérification ciblée plutôt qu'un parcours libre :
   - **Power BI** — si la connexion attaque la base directement, les requêtes visant
     `users` ou `usercredentials` sont à reprendre : ces tables ont fusionné dans
     `userinfo` au palier 2.38. Aucun impact si la connexion passe par `/api/analytics`.
   - **Configuration SMTP** — à ressaisir : les paramètres chiffrés du dump l'ont été avec
     la clé de l'ancienne instance.
   - **Tableaux de bord et visualisations** — la 2.36 a fait basculer tout le partage en
     `jsonb` et la 2.35 a fusionné graphiques et tableaux dans `visualization`.
8. **Fenêtre de bascule à convenir** avec ALIMA, une fois la recette validée. La migration
   sera **rejouée à l'identique** sur un export frais — procédure dans
   [`plan-migration.md`](plan-migration.md), section *Rejouer la migration le jour J*.
9. **Basculer `endom.alima.ngo`** — nom de l'instance de production — vers la nouvelle VM.
   L'opération enchaîne trois changements dans un ordre imposé : URL de base déclarée à
   DHIS2, résolution DNS, puis extension du certificat au nouveau nom. Procédure détaillée
   dans [`plan-migration.md`](plan-migration.md), section *Basculer `endom.alima.ngo`*.

### Reporté

10. `docs/variables-environnement.md` — taxonomie des variables `DHIS2_*`. Utile à
    l'exploitation courante, sans effet sur la bascule.
