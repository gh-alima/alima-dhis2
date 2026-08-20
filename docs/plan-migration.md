# Migration 2.35 → 2.41 par paliers

Comment faire monter la base de production d'ALIMA de DHIS2 2.35 à 2.41, palier par
palier, sur une copie — l'instance de production n'étant jamais modifiée.

---

## Principe

Une base DHIS2 ne se met pas à jour d'un bond. Chaque version applique ses propres
migrations de schéma (Flyway) au démarrage : sauter une version, c'est priver la suivante
des transformations qu'elle suppose acquises.

La montée se fait donc par **paliers successifs**, chacun étant :

1. démarré sur la copie de base issue du palier précédent ;
2. laissé appliquer ses migrations ;
3. **vérifié avant de passer au suivant**.

Un palier ne sert qu'à cela. Il ne reçoit aucun trafic, n'a pas de certificat, et sa
surcouche Tomcat est neutralisée — inutile de régler finement un connecteur qui ne servira
personne.

---

## Branches et versions

Une branche par ligne de version, épinglée sur son **dernier correctif publié**. Elles ne
diffèrent de `main` que par deux lignes du `Dockerfile` : la version de l'image de base et
la neutralisation de `server.xml`.

| Branche | Version | Tomcat / Java |
|---|---|---|
| `migration/2.35.14` | 2.35.14 | **Tomcat 8.5.79 / Java 8** — constaté |
| `migration/2.36.13.2` | 2.36.13.2 | à constater au démarrage |
| `migration/2.37.10.0` | 2.37.10.0 | à constater au démarrage |
| `migration/2.38.7.0` | 2.38.7.0 | à constater au démarrage |
| `migration/2.39.10.1` | 2.39.10.1 | à constater au démarrage |
| `migration/2.40.12.0` | 2.40.12.0 | à constater au démarrage |
| **`main`** | **2.41.9.1** | **Tomcat 9.0.111 / Java 17** — cible, `server.xml` actif |

> La colonne est informative : `server.xml` étant neutralisé sur tous les paliers, la
> version de Tomcat embarquée n'impose aucune adaptation. Le premier palier a révélé
> **Java 8**, là où une lecture rapide de la documentation laissait attendre Java 11 —
> raison de plus pour relever ce que chaque image annonce plutôt que de le supposer.

> `2.35.0`, la version en production chez ALIMA, **n'a pas d'image officielle** : la ligne
> 2.35 ne publie qu'à partir de `2.35.9`. Le premier palier démarre donc sur `2.35.14`, ce
> qui applique au passage les correctifs de la ligne. Ces correctifs ne modifient pas le
> schéma : l'image s'applique directement sur une base 2.35.0.

Ajouter un palier si besoin :

```bash
./scripts/create-migration-branch.sh 2.36.13.2
```

### Images publiées

Construites le 20 août 2026, dans
`europe-west1-docker.pkg.dev/alima-dhis2-prod/dhis2-images/dhis2-core` :

| Palier | Tag | Taille |
|---|---|---|
| 2.35.14 | `2.35.14.20260820.01.2a73704` | 740 Mo |
| 2.36.13.2 | `2.36.13.2.20260820.01.b93b81d` | 781 Mo |
| 2.37.10.0 | `2.37.10.0.20260820.01.225422a` | 746 Mo |
| 2.38.7.0 | `2.38.7.0.20260820.01.c947c42` | 713 Mo |
| 2.39.10.1 | `2.39.10.1.20260820.01.fd92b5f` | 712 Mo |
| 2.40.12.0 | `2.40.12.0.20260820.01.56df7c4` | 801 Mo |
| **2.41.9.1** (cible) | `2.41.9.1.20260820.01.0f45d7d` | 781 Mo |

> ⚠ **Ces tags peuvent disparaître avant la fin de la migration.** La politique de
> nettoyage du registre conserve les 10 versions les plus récentes et purge au-delà de
> 30 jours. Si la migration s'étale, un palier ancien peut sortir des deux critères et
> être supprimé.
>
> Ce n'est pas une perte : chaque palier se reconstruit à l'identique depuis sa branche,
> en deux minutes. Mais mieux vaut **vérifier la présence du tag avant chaque palier** que
> de le découvrir au déploiement.
>
> Pour les figer, ajouter une règle de conservation sur les tags de palier :
>
> ```bash
> gcloud artifacts docker tags list \
>   europe-west1-docker.pkg.dev/alima-dhis2-prod/dhis2-images/dhis2-core
> ```

---

## Quel chemin suivre

Deux options, à trancher au premier essai plutôt qu'à l'avance.

**Chemin court — à tenter en premier**

```text
2.35.14 → 2.38.7.0 → 2.40.12.0 → 2.41.9.1
```

Quatre paliers au lieu de sept. Un [retour d'expérience de la communauté
DHIS2](https://community.dhis2.org/t/upgrade-to-2-41/71659) décrit ce chemin comme
fonctionnel. La documentation officielle n'interdit pas de sauter des versions ; elle
indique seulement que les trois dernières versions majeures sont supportées.

**Chemin complet — en repli**

```text
2.35.14 → 2.36.13.2 → 2.37.10.0 → 2.38.7.0 → 2.39.10.1 → 2.40.12.0 → 2.41.9.1
```

À adopter **si un palier du chemin court échoue** : Flyway s'arrête, ou la vérification
révèle une anomalie. Reprendre alors depuis la sauvegarde du palier précédent en insérant
la version intermédiaire.

Chaque palier coûte un cycle complet — restauration, démarrage, vérification. En ajouter
par précaution allonge la migration sans rien garantir.

---

## Préparer

### 1. Récupérer la production

Deux éléments, et pas un seul :

- **l'export de la base** (`pg_dump`) ;
- **le répertoire `files/`** de DHIS2 — il n'est pas dans l'export. Sans lui, la base
  migrée référencera des documents introuvables.

> Données de santé : l'export ne transite ni par messagerie ni par support amovible
> (CGA art. 13). Convenir d'un canal à accès restreint.

### 2. Ce que contient l'export reçu

Relevé sur `dhis.sql.gz` (20 août 2026), en n'inspectant que l'en-tête et les
instructions de structure :

| | |
|---|---|
| Taille compressée | **25 Go** |
| Version d'origine | PostgreSQL 10.22 (Ubuntu 18.04) |
| Format | SQL texte (blocs `COPY`), non compressé en format `custom` |
| Extensions déclarées | `plpgsql`, `postgis` — en `CREATE EXTENSION IF NOT EXISTS` |
| Propriétaires | aucun `OWNER TO` — export réalisé sans attribution de propriétaire |

Deux conséquences favorables : les extensions se créent d'elles-mêmes à l'import, et
l'absence de propriétaires évite d'avoir à recréer des rôles inexistants sur Cloud SQL.

### Mesures relevées à l'import — 20 août 2026

| Mesure | Valeur |
|---|---|
| Durée de l'import | **26 min 53 s** |
| Taille de la base restaurée | **31 Go** |
| Tables | 457 |
| Extensions présentes après import | `plpgsql`, `postgis` |

Ces chiffres remplacent l'estimation initiale, qui les surévaluait nettement. Trois
conséquences, toutes favorables :

- **Le stockage suffit.** 31 Go sur les 100 Go provisionnés. Pas de redimensionnement à
  prévoir avant de connaître la taille des tables analytiques, qui s'ajouteront.
- **La durée est maîtrisable.** Vingt-sept minutes, et non les heures redoutées pour un
  export au format SQL texte. Demander un export au format `custom` n'est plus utile.
- **La fenêtre de bascule** peut s'appuyer sur une mesure réelle : l'import n'en
  représentera qu'une demi-heure.

> ⚠ **Le point de vigilance se déplace vers les tables analytiques.** Sur une instance
> DHIS2, elles atteignent couramment la taille des données sources, parfois davantage.
> Relever la taille de la base après le premier `analyticsTableUpdate` : c'est cette
> valeur, et non les 31 Go, qui déterminera le dimensionnement définitif du disque.

### 3. Téléverser l'export vers Cloud Storage

La base n'a qu'une adresse privée : l'import passe par Cloud Storage, seul chemin
qu'atteignent à la fois le poste et Cloud SQL. Aucun transit par la VM, dont le disque ne
suffirait pas.

```bash
gcloud storage cp "C:/Users/lenovo/Downloads/dhis.sql.gz" \
  gs://alima-dhis2-prod-dhis2-backups/import/dhis-2.35.sql.gz \
  --project=alima-dhis2-prod
```

Compter plusieurs heures selon le débit montant. La commande reprend un transfert
interrompu.

Autoriser ensuite Cloud SQL à lire l'objet — son compte de service est distinct de celui
de la VM :

```bash
SA=$(gcloud sql instances describe pg16-dhis2-prod \
       --format="value(serviceAccountEmailAddress)" --project=alima-dhis2-prod)
echo "${SA}"    # doit être non vide

gcloud storage buckets add-iam-policy-binding \
  gs://alima-dhis2-prod-dhis2-backups \
  --member="serviceAccount:${SA}" --role="roles/storage.objectViewer" \
  --project=alima-dhis2-prod
```

> L'autorisation se donne sur le **bucket**, pas sur l'objet. Le bucket est créé avec
> l'accès uniforme au niveau du bucket (`--uniform-bucket-level-access`), qui désactive
> les autorisations par objet — une tentative sur l'objet échoue sur
> `Object policies are disabled for bucket`.
>
> Cette portée est de toute façon celle qu'il faut : Cloud SQL devra aussi lire ce bucket
> pour les restaurations ultérieures.

### 4. Vider la base cible

La base `dhis2` contient l'installation 2.41 créée au premier démarrage : un schéma
complet, des métadonnées par défaut, aucune donnée ALIMA. Elle doit disparaître — importer
par-dessus produirait des conflits de clés et un mélange des deux schémas.

**Arrêter DHIS2 d'abord**, sans quoi la suppression échouera : l'application maintient des
connexions ouvertes.

```bash
# Sur la VM
sudo /opt/alima/dhis2/scripts/dhis2ctl.sh stop
```

```bash
# Depuis le poste
gcloud sql databases delete dhis2 --instance=pg16-dhis2-prod --quiet
gcloud sql databases create dhis2 --instance=pg16-dhis2-prod
```

> Une base **unique** est réutilisée plutôt qu'une base de travail séparée : à ce
> volume, en maintenir deux doublerait le stockage facturé. Le point de reprise entre
> paliers est assuré par les exports de l'étape suivante, pas par une seconde base.

### 5. Importer

> **L'import natif de Cloud SQL ne convient pas ici.** Il rejoue le fichier tel quel et
> s'arrête sur :
>
> ```text
> ERROR:  must be owner of extension plpgsql
> ```
>
> `pg_dump` écrit un `COMMENT ON EXTENSION` après chaque `CREATE EXTENSION`. Commenter une
> extension exige d'en être propriétaire — or `plpgsql` appartient au superutilisateur
> interne, que Cloud SQL n'accorde à personne. Deux lignes en cause dans tout l'export, ne
> portant qu'un libellé, sans aucun effet fonctionnel.
>
> Les retirer du fichier supposerait de le décompresser, le filtrer, le recompresser et le
> renvoyer : plusieurs heures pour deux lignes.

L'import se fait donc depuis la VM, en filtrant le flux à la volée — le fichier n'est
jamais écrit sur disque, celui de la VM n'y suffirait pas.

```bash
# Sur la VM. L'import dure des heures : nohup le protège d'une déconnexion SSH.
sudo nohup /opt/alima/dhis2/scripts/import-dump.sh \
  gs://alima-dhis2-prod-dhis2-backups/import/dhis-2.35.sql.gz \
  > /var/log/dhis2-import.log 2>&1 &

tail -f /var/log/dhis2-import.log
```

Le script refuse de démarrer si la base contient déjà des tables : importer par-dessus
produirait des conflits de clés, révélés des dizaines de milliers de lignes plus loin. En
cas d'import interrompu, revenir à l'étape 4 avant de relancer.

Il affiche en fin de parcours la **durée**, le nombre de tables, la taille de la base et
les extensions installées. **Noter la durée** : c'est la principale composante de la
fenêtre de bascule.

### 6. Compléter les extensions

L'export crée `plpgsql` et `postgis`. Il manque `btree_gin` et `pg_trgm`, requises depuis
DHIS2 2.38 :

```bash
# Sur la VM — seul point atteignant la base en adresse privée
sudo bash /opt/alima/dhis2/scripts/init-database.sh
```

Le script est idempotent et affiche la liste des extensions installées.

### 7. Mesurer avant de commencer

```bash
gcloud sql instances describe pg16-dhis2-prod \
  --format="value(currentDiskSize,settings.dataDiskSizeGb)" --project=alima-dhis2-prod
```

Noter la taille obtenue : elle conditionne le dimensionnement définitif de l'instance et
sert de référence pour mesurer la croissance à chaque palier.

La base est alors prête pour le premier palier.

### 8. Vérifier la présence des images

Les sept images sont publiées (voir *Images publiées* ci-dessus). Confirmer que le tag du
palier visé existe toujours avant de lancer l'étape — la politique de nettoyage peut
l'avoir purgé si la migration s'étale :

```bash
gcloud artifacts docker images list \
  europe-west1-docker.pkg.dev/alima-dhis2-prod/dhis2-images/dhis2-core \
  --include-tags --project=alima-dhis2-prod | grep '^.*2\.3'
```

Le cas échéant, reconstruire depuis la branche — deux minutes :

```bash
git checkout migration/2.35.14
gcloud builds submit --config=cloudbuild.yaml \
  --substitutions=_VCS_REF=$(git rev-parse --short HEAD) \
  --project=alima-dhis2-prod
```

> Le déclencheur automatique ne réagit qu'aux poussées sur `main` : les branches de palier
> se construisent à la demande, ce qui évite de saturer le registre.

---

## Exécuter un palier

Pour chaque version, dans l'ordre :

**1. Sauvegarder l'état d'entrée** — c'est le point de reprise si le palier échoue.

```bash
gcloud sql backups create --instance=pg16-dhis2-prod \
  --description="avant palier <version>" --project=alima-dhis2-prod
```

Une **sauvegarde Cloud SQL**, et non un export logique. À ce volume, un
`gcloud sql export sql` prendrait des heures à chaque palier et rendrait la chaîne
impraticable. La sauvegarde repose sur un instantané du disque : quelques minutes, et une
restauration tout aussi rapide.

```bash
# En cas d'échec du palier — revenir à l'état d'entrée
gcloud sql backups list --instance=pg16-dhis2-prod --limit=5
gcloud sql backups restore <ID> --restore-instance=pg16-dhis2-prod
```

**2. Démarrer le palier** — par le pipeline, en le lançant **sur la branche du palier**
et non sur `main` :

```bash
gcloud builds triggers run dhis2-deploy-prod --region=europe-west1   --branch=migration/2.36.13.2   --substitutions=_IMAGE_TAG=2.36.13.2.20260820.01.b93b81d
```

Puis approuver dans la console, comme pour un déploiement ordinaire.

**La branche détermine tout.** Elle porte l'image *et* sa configuration d'exécution :

| Sur la branche | Effet |
|---|---|
| `docker/Dockerfile` | corrige `unpackWARs` dans le `server.xml` de l'image |
| `docker/docker-compose.override.yml` | lève `read_only`, remplace la sonde |

Le pipeline téléverse la surcharge si elle existe dans les sources, et **efface celle de
la VM sinon**. Rien à renseigner, donc rien à oublier : déployer `main` restaure de
lui-même la configuration de production.

> Compose charge `docker-compose.override.yml` **automatiquement** dès qu'il jouxte le
> fichier principal. C'est la raison de ce nom : `dhis2ctl` et `wait-healthy` voient donc
> la même configuration que celle déployée, sans connaître son existence.

### Pourquoi ces deux correctifs

Le premier palier a échoué deux fois avant que la cause soit établie :

```
java.io.FileNotFoundException: URL cannot be resolved to absolute file path
... war:file:/usr/local/tomcat/webapps/ROOT.war*/WEB-INF/lib/...
```

Le préfixe `war:file:` signale que Tomcat sert l'application **depuis l'archive**. Les
images officielles déclarent `unpackWARs="false"` — vérifié sur `dhis2/core:2.35.14`,
`server.xml` ligne 153. Nous étions seuls à porter `unpackWARs="true"`, dans
`docker/server.xml`, que les branches de palier neutralisent précisément. La cible 2.41
n'a jamais rencontré le problème parce qu'elle conserve ce fichier.

> La lecture seule n'y était pour rien : sans `unpackWARs`, l'image n'aurait jamais
> décompressé, quelles que soient les permissions. Elle le devient une fois la
> décompression rétablie — Tomcat écrit alors dans `webapps/`. D'où les deux correctifs,
> et dans cet ordre.


**3. Suivre les migrations.**

```bash
sudo /opt/alima/dhis2/scripts/dhis2ctl.sh applog dhis.log
```

Chercher les lignes Flyway. Le palier est terminé quand DHIS2 atteint l'état `healthy`.

**4. Vérifier avant d'aller plus loin.**

| Contrôle | Comment |
|---|---|
| Migrations appliquées sans erreur | journal Flyway dans `dhis.log` |
| Démarrage complet | conteneur `healthy` |
| Connexion applicative | accès à l'interface, authentification |
| Métadonnées cohérentes | éléments de données, programmes, unités d'organisation |
| **Tables analytiques** | lancer `analyticsTableUpdate` et vérifier la sortie |

Le dernier point est le plus révélateur : une migration Flyway réussie ne prouve pas que
les analyses fonctionnent. C'est aussi le plus long — le prévoir dans le calendrier.

**5. Passer au palier suivant**, ou revenir à l'étape 1 avec une version intermédiaire si
quelque chose cloche.

---

## Journal des paliers

### Palier 1 — 2.35.14, 20 aout 2026

| Mesure | Valeur |
|---|---|
| Version du schema a l'arrivee du dump | **2.35.22** |
| Migrations appliquees | 22, jusqu'a `2.35.46` |
| Duree Flyway | **0,795 s** |
| Demarrage complet | 89 s |
| Version rapportee | `DHIS 2 Version: 2.35.14` |

> Le dump de production etait en **2.35.22**, non en 2.35.0 comme l'audit initial
> l'indiquait. Sans consequence : la ligne 2.35 se rattrape d'elle-meme.

**Flyway est rapide, meme sur 31 Go.** Moins d'une seconde pour 22 migrations. Le poste de
depense de la fenetre de bascule n'est donc pas la migration de schema, mais l'import du
dump (27 min, mesure) et le premier `analyticsTableUpdate`.

#### Deux avertissements releves au demarrage

```
ERROR Invalid cron expression - 0 0 * * *  ... Defaulting to Daily
```

Defaut connu de la configuration Log4j de DHIS2 2.35 pour le journal d'audit. Sans effet :
la rotation retombe sur un rythme quotidien. Disparait avec les versions recentes.

```
WARN Could not decrypt system setting 'keyEmailPassword'
```

**A traiter.** Les parametres chiffres du dump l'ont ete avec la cle de l'ancienne
instance ; la nouvelle utilise `dhis2-encryption-password` du Secret Manager. Le mot de
passe SMTP stocke est donc illisible.

Consequence limitee : seuls les **parametres chiffres** sont concernes, jamais les donnees
de sante. Il faudra ressaisir la configuration SMTP apres la bascule, dans
*Administration -> Parametres -> Courriel*. A verifier au passage : toute configuration
OAuth ou passerelle SMS eventuellement chiffree.

> Ne pas tenter d'aligner la cle sur celle de l'ancienne instance : changer
> `dhis2-encryption-password` apres coup rendrait illisible tout ce que la nouvelle
> instance aura chiffre depuis.

---

### Palier 2 — 2.36.13.2, 20 aout 2026

Migrations les plus lourdes de cette version :

- `V2_36_11__Migrate_sharings_to_jsonb` — bascule de tout le partage (attributs, roles,
  groupes, elements de donnees, programmes, tableaux de bord...) vers une colonne `jsonb`
- migrations `name => shortname`, qui renseignent les noms courts manquants

Les `WARN ... already exists, skipping` sont attendus : Flyway retrouve des objets deja
presents et poursuit.

#### A verifier sur la cible 2.41 — taille du pool de connexions

```
2.35.14  Hibernate configuration loaded: ... connection pool max size: 40
2.36.13  Hibernate configuration loaded: ... connection pool max size: null
```

`init.sh` ecrit pourtant `connection.pool.max_size = 40` et `db.pool.type = hikari`. La
2.35 utilisait c3p0 et lisait cette valeur ; a partir de la 2.36 DHIS2 passe sur Hikari, et
cette ligne de journal interroge une clef propre a l'ancien pool.

Sans consequence sur un palier, qui ne recoit aucun trafic. **Mais a controler au
demarrage de la 2.41** : si la taille du pool n'est pas appliquee, DHIS2 retombe sur sa
valeur par defaut, ce qui se paie en charge reelle. Verification :

```bash
sudo /opt/alima/dhis2/scripts/dhis2ctl.sh applog dhis.log | grep -i "pool"
```

Si la valeur reste `null` en 2.41, chercher la clef attendue par Hikari dans la
documentation de la version et adapter `docker/init.sh`.

---

### Palier 3 — 2.37.10.0, 20 aout 2026

Premier palier sur **Tomcat 9.0.82** (les precedents tournaient en 8.5). Toujours Java 8.

Les migrations Flyway passent, puis l'initialisation Spring echoue :

```
ClassCastException: com.zaxxer.hikari.HikariDataSource cannot be cast to
                    com.mchange.v2.c3p0.ComboPooledDataSource
  at DataSourcePoolMetricsConfig.lambda$dataSourceMetadataProvider$0(:109)
```

DHIS2 2.37 branche les metriques du pool de connexions en supposant c3p0, alors que la
configuration demande Hikari (`db.pool.type = hikari`). Le contexte meurt ; Tomcat demarre
mais ne sert rien.

C'est le meme sujet que le `connection pool max size: null` du palier 2 : la transition de
c3p0 vers Hikari est mal finie dans ces versions.

**Correctif** — `monitoring.dbpool.enabled = off`, porte par la surcharge de palier :

```yaml
services:
  dhis2:
    environment:
      DHIS2_MONITORING_DBPOOL: "off"
```

`environment` prime sur `env_file` : le `.env` genere depuis Secret Manager garde `on`, seul
le palier bascule. Un palier n'a rien a superviser.

> **La cible 2.41 n'est pas concernee** : elle tourne en production avec cette metrique
> active. Ne pas propager ce reglage a `main`.

Les migrations 2.37 ayant abouti avant l'echec, le redemarrage reprend sans rejouer quoi
que ce soit — Flyway trouvera le schema a jour.

---

## Ce qu'il faut mesurer en chemin

Ces chiffres déterminent la fenêtre de bascule. Les relever palier par palier :

| Mesure | Pourquoi |
|---|---|
| Durée des migrations Flyway | c'est l'essentiel du temps d'indisponibilité |
| Durée de `analyticsTableUpdate` | souvent plus long que la migration elle-même |
| Volume de la base après chaque palier | dimensionnement de Cloud SQL |
| Taille du répertoire `files/` | durée de la copie à la bascule |

Une estimation de fenêtre donnée avant ces mesures n'est qu'une supposition.

---

## Bascule

Une fois `2.41.9.1` validé sur la copie :

1. **Gel des saisies** sur la production 2.35, à l'heure convenue.
2. **Export final** de la base de production.
3. **Rejeu de la chaîne complète** des paliers sur cet export — la durée est connue,
   puisque mesurée.
4. **Copie différentielle** du répertoire `files/` — seul ce qui a changé depuis la copie
   initiale est retransféré.
5. **Bascule du nom d'hôte** : `dhis2.alima.ngo` vers la nouvelle instance
   ([provisionnement, §État](provisionnement-gcp.md)).
6. **Vérifications fonctionnelles** avec les référents, puis réouverture des saisies.

> Avant la bascule, supprimer l'enregistrement DNS résiduel de `dhis2.alima.ngo` vers
> `34.79.172.183` — un hôte tiers sans lien avec ALIMA. Sans cela, la moitié du trafic de
> production partirait vers un serveur non maîtrisé.

**La production 2.35 reste intacte** jusqu'à la réouverture des saisies. En cas de
difficulté, le retour arrière consiste à ne pas basculer le DNS.

---

## Points de vigilance

**PostgreSQL 16.** Le Flyway embarqué dans DHIS2 2.41 signale au démarrage n'avoir pas été
testé au-delà de PostgreSQL 15. Les migrations passent, mais si un palier échoue de façon
inexpliquée, cette piste est à examiner : migrer d'abord sur PostgreSQL 15, puis monter la
base ensuite.

**Extensions PostgreSQL.** `postgis`, `btree_gin` et `pg_trgm` sont créées automatiquement
à chaque déploiement par l'étape `init-db`. Sur une base de travail créée à la main, les
créer avant le premier palier.

**Le magasin de fichiers ne migre pas tout seul.** Il n'est dans aucun export de base. Une
migration réussie côté données peut laisser toutes les pièces jointes introuvables.
