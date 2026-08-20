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

Les tags vivent dans Artifact Registry, pas dans ce document : une table recopiée ici se
périme dès la première reconstruction — c'est arrivé une fois.

```bash
./scripts/list-palier-images.sh
```

Le script déduit les versions des branches `migration/*` et la cible du `Dockerfile` de
`main`, puis interroge le registre. Il signale toute image manquante et rappelle comment la
reconstruire. Ajouter un palier suffit à le faire apparaître.

> ⚠ **Les images peuvent disparaître du registre.** La politique de nettoyage conserve les
> 10 versions les plus récentes et purge au-delà de 30 jours. Lancer le script **avant**
> chaque campagne de migration plutôt que de le découvrir au déploiement : reconstruire un
> palier depuis sa branche prend deux minutes.

---

## Le chemin retenu

```text
2.35.14 -> 2.36.13.2 -> 2.37.10.0 -> 2.38.7.0 -> 2.39.10.1 -> 2.40.12.0 -> 2.41.9.1
```

**Chemin complet, sept versions, parcouru le 20 aout 2026.** Aucun palier n'a echoue pour
une raison tenant a la migration de schema elle-meme : les trois incidents rencontres
venaient de la forme des images et de la configuration d'execution, jamais de Flyway.

Un [chemin court](https://community.dhis2.org/t/upgrade-to-2-41/71659) etait envisage
— `2.35.14 -> 2.38.7.0 -> 2.40.12.0 -> 2.41.9.1`, quatre paliers au lieu de sept. Il n'a
pas ete tente, et il n'y a plus de raison de le faire : **Flyway s'est revele si rapide que
les trois paliers economises n'auraient rien fait gagner** — moins d'une seconde de
migration sur la plupart des versions, quelques minutes de demarrage. Le cout d'un palier
est celui d'un demarrage de Tomcat, pas d'une transformation de donnees.

Sauter des versions echangerait donc quelques minutes contre un risque non mesure. Le
chemin complet reste celui a rejouer le jour J.

## Préparer

### 1. Récupérer la production

**Un seul élément : l'export de la base** (`pg_dump`).

En règle générale il en faudrait deux — le dump ne contient pas le magasin de fichiers, et
une base restaurée sans lui référence des documents introuvables. **Vérifié le 20 août 2026
sur l'instance 2.35 : le répertoire `files/` est vide.** Aucune pièce jointe, aucun document
chargé. Rien à transférer.

> Le mécanisme de sauvegarde du magasin de fichiers reste en place et reste nécessaire :
> dès que la 2.41 sera en service, les utilisateurs pourront y déposer des documents.
> C'est l'étape de *migration* qui disparaît, pas la sauvegarde.

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

Confirmer que **toutes** les images existent encore avant d'ouvrir la fenêtre — pas au
moment de déployer chaque palier :

```bash
./scripts/list-palier-images.sh
```

Le script sort en erreur si une image manque et rappelle la commande de reconstruction.
Compter deux minutes par palier.

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

### Palier 4 — 2.38.7.0, 20 aout 2026

Premier palier a aboutir entierement depuis le 2.36 : `All startup routines done`,
`DHIS 2 Version: 2.38.7`, demarrage en 103 s. Le correctif dbpool tient
(`monitoring.dbpool.enabled is disabled`).

| | |
|---|---|
| Tomcat | 9.0.90 |
| **Java** | **11.0.23** — bascule depuis Java 8 |
| Duree de demarrage | 103 s |

La JVM recoit desormais des `--add-opens` (`java.base/java.lang`, `java.io`, `java.util`,
`java.util.concurrent`, `java.rmi/sun.rmi.transport`) : l'image les pose elle-meme, rien a
regler de notre cote.

#### Une migration structurante — `V2_38_35__Migrate_user_to_userinfo`

```sql
UPDATE userinfo SET username = uc.username, password = uc.password, ... FROM users AS uc
```

Les identifiants quittent `usercredentials` pour rejoindre `userinfo`. Consequence a
verifier en recette : **toute requete SQL directe visant `users` ou `usercredentials`**
cesse de fonctionner — export, tableau de bord, script d'exploitation.

> A verifier cote **Power BI** : si la connexion passe par l'API DHIS2 (`/api/analytics`),
> aucun impact. Si elle attaque la base directement, les requetes touchant les tables
> d'utilisateurs sont a reprendre. C'est le genre d'ecart qui ne se voit qu'a l'usage —
> a inscrire au plan de recette.

Egalement dans ce palier : `V2_38_37` deplace les criteres de
`trackedentityinstancefilter` vers une colonne `entityquerycriteria` en jsonb.

#### Le planificateur redemarre les taches en retard

```
Scheduler started with one or more unexecuted jobs:
Job [bIbXlsXoz2p, Analytics every day at noon] ... supposed to be: Fri Aug 14 12:00:00 UTC
```

Les taches heritees du dump ont manque leurs echeances pendant l'arret de l'ancienne
instance. DHIS2 les signale et les reprogramme — c'est le comportement attendu.

**Point de vigilance** : `ANALYTICS_TABLE` est planifiee du lundi au vendredi a midi UTC. Si
un palier tourne a cette heure-la, une generation complete des tables analytiques peut se
declencher — longue, inutile a ce stade, et gourmande en ressources.

Ne pas laisser un palier tourner plus longtemps que necessaire : une fois
`All startup routines done` atteint et la version confirmee, passer au suivant.

---

### Palier 5 — 2.39.10.1, 20 aout 2026

Passe sans incident, sans correctif supplementaire.

---

### Palier 6 — 2.40.12.0, 20 aout 2026

Passe sans incident. Dernier palier avant la cible.

---

### Deployer la cible — 2.41.9.1

Ce deploiement ne ressemble a aucun des precedents : il part de **`main`**, qui ne porte
aucune surcharge. La configuration de production reprend ses droits d'un seul coup.

| | Paliers | Cible |
|---|---|---|
| `read_only` | leve | **`true`** |
| Sonde | `/api/system/ping` | **`/dhis-web-login/`** |
| Metrique dbpool | coupee | **active** |
| Nginx | jamais demarre | **demarre**, TLS compris |

Quatre changements simultanes, dont trois ineprouves depuis le debut de la migration.
**Prendre un point de reprise avant celui-ci plus qu'avant tout autre.**

#### Deroulement

```bash
git checkout main && git pull

# Reconstruire : l'image 2.41 existante date d'avant les corrections de main.
# Elle serait fonctionnellement identique, mais son tag ne designerait pas le
# commit reellement deploye — traçabilite perdue au moment ou elle compte le plus.
gcloud builds submit --config=cloudbuild.yaml   --substitutions=_VCS_REF=$(git rev-parse --short HEAD)   --project=alima-dhis2-prod

gcloud sql backups create --instance=pg16-dhis2-prod   --description="apres palier 2.40.12.0, avant la cible 2.41.9.1"   --project=alima-dhis2-prod

gcloud builds triggers run dhis2-deploy-prod --region=europe-west1   --branch=main --substitutions=_IMAGE_TAG=<tag>
```

Le journal de deploiement ne doit **pas** afficher `>>> PALIER DE MIGRATION`. Son absence
confirme que la surcharge n'a pas ete televersee et que celle restee sur la VM a bien ete
effacee.

#### A verifier au demarrage

```bash
sudo /opt/alima/dhis2/scripts/dhis2ctl.sh status
sudo /opt/alima/dhis2/scripts/dhis2ctl.sh applog dhis.log | grep -iE "pool|Version|startup routines"
```

| Controle | Attendu | Si l'attendu manque |
|---|---|---|
| `DHIS 2 Version` | `2.41.9.1` | mauvais tag deploye |
| `All startup routines done` | present | lire l'erreur au-dessus |
| `connection pool max size` | **`40`**, pas `null` | clef Hikari a corriger dans `init.sh` |
| Metrique dbpool | pas de `ClassCastException` | c'est elle qui tuait le 2.37 |
| `dhis2ctl status` | `dhis2` **et** `dhis2-nginx` sains | Nginx demarre pour la premiere fois du cycle |
| <https://dhis2-test.alima.ngo> | page de connexion | voir `dhis2ctl cert` |

#### Une fois la cible en service

1. **Ressaisir la configuration SMTP** — `keyEmailPassword` ne se dechiffre pas (cf. palier 1).
2. **Lancer `analyticsTableUpdate`** depuis *Administration -> Planificateur*, puis **relever
   la taille de la base**. C'est cette valeur, et non les 31 Go, qui determine le
   dimensionnement definitif du disque.
3. **Valider Power BI** — en particulier si la connexion attaque la base directement :
   `usercredentials` a fusionne dans `userinfo` au palier 2.38 (cf. palier 4).
4. **Retirer l'enregistrement DNS residuel** `34.79.172.183` avant la bascule de production.

---

### Cible — 2.41.9.1, 20 aout 2026

**La montee 2.35 -> 2.41 est aboutie.** Les six paliers puis la cible sont passes le meme
jour, sur une copie de la base de production. Generation des tables analytiques lancee dans
la foulee.

---

## Rejouer la migration le jour J

Ce qui precede etait une repetition. La bascule reelle rejoue exactement la meme sequence,
sur un export **frais** de la production.

Pourquoi un nouvel export : entre la repetition et la bascule, ALIMA continue de saisir. La
base migree aujourd'hui est une photographie perimee — elle a servi a eprouver le chemin,
pas a devenir la production.

### La sequence

**1. Verifier que les images sont toujours la**

```bash
./scripts/list-palier-images.sh
```

Le registre purge au-dela de 30 jours. Si un palier manque, le reconstruire depuis sa
branche avant d'ouvrir la fenetre — pas pendant.

**2. Gel des saisies, puis export de la production 2.35**

**3. Vider la base cible et importer** (cf. « Preparer », etapes 3 a 6)

```bash
FORCE=1 ./scripts/import-dump.sh gs://alima-dhis2-prod-dhis2-backups/import/dhis-2.35.sql.gz
```

`FORCE=1` est necessaire : la base contient la migration de repetition. Compter **~27 min**
pour 31 Go, mesure relevee.

**4. Rejouer les paliers, dans l'ordre**

Pour chaque version, du plus ancien au plus recent :

```bash
gcloud sql backups create --instance=pg16-dhis2-prod   --description="avant palier <version>" --project=alima-dhis2-prod

gcloud builds triggers run dhis2-deploy-prod --region=europe-west1   --branch=migration/<version> --substitutions=_IMAGE_TAG=<tag releve a l'etape 1>
```

Attendre `All startup routines done` avant de passer au suivant. Ne pas laisser un palier
tourner au-dela : `ANALYTICS_TABLE` est planifiee a midi UTC et se declencherait pour rien.

**5. Deployer la cible depuis `main`** (cf. « Cible — 2.41.9.1 » plus haut)

**6. Apres la mise en service**

- ressaisir la configuration SMTP ;
- lancer `analyticsTableUpdate` et relever la taille de la base ;
- valider Power BI ;
- basculer le DNS de production, apres avoir retire l'enregistrement residuel
  `34.79.172.183`.

### Duree a prevoir

| Etape | Mesure |
|---|---|
| Import du dump | **~27 min** |
| Six paliers | quelques minutes chacun ; Flyway a mis moins d'une seconde sur la plupart |
| Demarrage de la cible | ~2 min |
| `analyticsTableUpdate` | **inconnu** — a relever lors de la generation en cours |

La generation des tables analytiques est le poste le plus lourd et le seul encore non
mesure. **C'est elle qui dimensionnera la fenetre de bascule**, pas la migration de schema.

> La montee peut se faire **avant** l'ouverture de la fenetre si la copie tourne en
> parallele de la production 2.35 : seul l'export final et la bascule DNS exigent un gel
> des saisies. A arbitrer avec ALIMA selon la tolerance a l'interruption.

---

## Les mesures relevees

| Etape | Mesure | Source |
|---|---|---|
| Televersement du dump vers Cloud Storage | **< 5 min** | 25 Go compresses sur fibre 1 Gb/s |
| Import du dump (31 Go) | **27 min** | releve le 20 aout 2026 |
| Migrations Flyway | **< 1 s** sur la plupart des paliers | journaux des sept paliers |
| Demarrage d'un palier | **1 a 2 min** | journaux |
| Sept paliers, bout en bout | **~20 min** | somme des demarrages |
| Demarrage de la cible 2.41 | **~2 min** | journal |
| **`analyticsTableUpdate`** | **58 min 29 s** | releve le 20 aout 2026 a 13h16 |
| Taille du magasin de fichiers | **vide** | instance 2.35 |
| Taille de la base apres analytique | **a relever** | voir ci-dessous |

```bash
gcloud sql instances describe pg16-dhis2-prod   --format="value(currentDiskSize)" --project=alima-dhis2-prod
```

Cette derniere valeur arrete le dimensionnement definitif du disque — 100 Go sont
provisionnes, la base pesait 31 Go avant l'analytique.

### Ou passe l'espace — releve du 20 aout 2026

Apres migration et generation des tables analytiques :

| Table | Taille | Part |
|---|---|---|
| `audit` | 29 Go | 69 % |
| `analytics_2025` | 5,8 Go | 14 % |
| `analytics_2026` | 4,8 Go | 11 % |
| `datavalue` | 2,0 Go | 5 % |
| `analytics_completeness_2025` | 196 Mo | — |
| `datavalueaudit` | 194 Mo | — |
| tout le reste | < 150 Mo chacune | — |
| **Base totale** | **42 Go** | sur **100 Go** provisionnes |

Les tables analytiques representent **11 Go**, ce qui recoupe exactement l'ecart mesure
avant et apres leur generation (31 → 42 Go).

**Le dimensionnement est regle** : 42 Go sur 100 provisionnes, avec redimensionnement
automatique actif en filet. La base est conservee dans son integralite, historique d'audit
compris.

Relever ces valeurs a nouveau apres quelques mois d'exploitation : c'est la trajectoire de
croissance, et non la taille du jour, qui dictera un eventuel redimensionnement.

```sql
SELECT c.relname, pg_size_pretty(pg_total_relation_size(c.oid)) AS taille
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC
LIMIT 10;
```

### La generation analytique domine tout le reste

Presque une heure, contre une vingtaine de minutes pour les sept paliers reunis. **C'est
elle qui decide de la duree de l'indisponibilite, et elle n'a pas a s'y trouver.**

DHIS2 fonctionne sans tables analytiques a jour : la saisie, le suivi et l'API de donnees
brutes sont intacts. Seuls les tableaux de bord, rapports et visualisations refletent l'etat
de la derniere generation.

| Scenario | Indisponibilite | Contrepartie |
|---|---|---|
| Analytique **dans** la fenetre | **~1 h 50** hors export et transfert | tableaux de bord justes des la reouverture |
| Analytique **apres** reouverture | **~50 min** hors export et transfert | tableaux de bord en retard pendant ~1 h |

Le second scenario divise l'indisponibilite par deux. **A arbitrer avec ALIMA** : la
question n'est pas technique mais metier — une heure de tableaux de bord decales est-elle
acceptable en echange d'une heure de saisie regagnee ?

### Duree totale, a partir de la reception du dump

| Etape | Duree |
|---|---|
| Televersement vers Cloud Storage | 5 min |
| Import dans Cloud SQL | 27 min |
| Les sept paliers | 20 min |
| Demarrage de la cible 2.41 | 2 min |
| **Sous-total — DHIS2 2.41 operationnel** | **~55 min** |
| Generation des tables analytiques | 58 min |
| **Total — tableaux de bord a jour** | **~1 h 55** |

Toutes ces valeurs sont mesurees, aucune n'est estimee.

**L'analytique represente a elle seule plus de la moitie du total.** Elle peut se lancer
apres la reouverture des saisies : DHIS2 fonctionne sans tables analytiques a jour, seuls
les tableaux de bord et rapports refletent l'etat de la derniere generation. C'est le
levier a arbitrer avec ALIMA — **une heure d'indisponibilite en moins contre une heure de
tableaux de bord decales**.

> Le compte demarre a la reception de l'export. Sa production sur le serveur 2.35 se situe
> en amont de la fenetre et releve d'ALIMA — c'est une operation qu'ils ont deja menee pour
> fournir l'export du 20 aout, de sorte que l'ordre de grandeur leur est connu.

> **Le jour J ne fait que rejouer cette sequence sur un export plus recent.** Rien d'autre
> ne change : memes images, memes paliers, meme procedure. Le nouvel export ne sert qu'a
> integrer les saisies effectuees depuis celui de la repetition.

---

## Bascule

1. **Gel des saisies** sur la production 2.35, a l'heure convenue.
2. **Export final** de la base de production.
3. **Rejeu de la chaine complete** — procedure detaillee ci-dessus,
   *Rejouer la migration le jour J*. Duree connue, puisque mesuree.
4. **Bascule du nom d'hote** vers `endom.alima.ngo` — voir ci-dessous.
5. **Verifications fonctionnelles** avec les referents, puis reouverture des saisies.
6. **Generation des tables analytiques**, si le choix est fait de la reporter apres
   reouverture.

### Basculer `endom.alima.ngo`

`endom.alima.ngo` est le nom de l'instance **de production** 2.35. C'est lui qui doit
pointer vers la nouvelle VM — pas `dhis2-test.alima.ngo`, qui reste l'acces de recette.

Trois choses changent en meme temps : la resolution DNS, le certificat TLS et l'URL de base
declaree a DHIS2. **Dans cet ordre**, sans quoi on obtient une instance joignable qui
s'annonce sous un autre nom, ou un HTTPS en erreur.

**Avant le jour J**

- Faire **abaisser le TTL** de `endom.alima.ngo` par ALIMA — 24 h a l'avance au minimum.
  Un TTL de 3600 s fige la bascule pour une heure, et le retour arriere avec elle.
- Verifier que le nom ne resout que vers **une seule** adresse :

  ```bash
  dig +short endom.alima.ngo
  ```

  Plusieurs reponses signifient que le trafic se repartirait entre elles. C'est le cas de
  `dhis2.alima.ngo`, qui porte un enregistrement residuel vers `34.79.172.183` — un hote
  tiers servant un certificat expire, sans lien avec ALIMA.

**Pendant la fenetre, une fois la migration terminee**

```bash
# 1. Declarer la nouvelle URL de base — avant la bascule DNS : DHIS2 n'a pas
#    besoin que le nom resolve pour l'inscrire dans sa configuration.
printf '%s' 'https://endom.alima.ngo' \
  | gcloud secrets versions add dhis2-fqdn --data-file=- --project=alima-dhis2-prod

# 2. Redeployer pour que render-env.sh regenere le .env avec cette valeur.
gcloud builds triggers run dhis2-deploy-prod --region=europe-west1 \
  --branch=main --substitutions=_IMAGE_TAG=<tag de la cible>
```

**3. ALIMA fait pointer `endom.alima.ngo` vers `34.38.89.219`.** Attendre la propagation :

```bash
dig +short endom.alima.ngo    # doit renvoyer 34.38.89.219, et rien d'autre
```

**4. Etendre le certificat au nouveau nom**, une fois la resolution effective — le defi
HTTP-01 exige que Let's Encrypt atteigne la VM sous ce nom :

```bash
# Sur la VM. certbot --standalone se lie au port 80 : Nginx doit liberer la place.
cd /opt/alima/dhis2
sudo docker compose stop nginx

sudo certbot certonly --standalone --cert-name dhis2 \
  -d dhis2-test.alima.ngo -d endom.alima.ngo

sudo docker compose start nginx
```

Les **deux** noms figurent dans la commande : `--cert-name dhis2` remplace le certificat
existant, et omettre `dhis2-test.alima.ngo` le priverait de TLS. Le renouvellement
automatique reprendra les deux noms.

**5. Verifier**

```bash
curl -sI https://endom.alima.ngo/dhis-web-login/ | head -3
echo | openssl s_client -connect endom.alima.ngo:443 2>/dev/null \
  | openssl x509 -noout -subject -dates
```

> Entre l'etape 3 et la fin de l'etape 4, HTTPS repond en erreur de certificat sous le
> nouveau nom — quelques minutes, a l'interieur de la fenetre, avant reouverture des
> saisies. Cet ecart est inevitable avec un defi HTTP-01 : le certificat ne peut pas etre
> emis avant que le nom pointe vers la VM.

**La production 2.35 reste intacte** jusqu'a la reouverture des saisies. En cas de
difficulte, le retour arriere consiste a ne pas basculer le DNS — rien a defaire.

---

## Le cache navigateur, angle mort de la bascule

Constate le 20 aout 2026 sur la 2.41 migree : les tableaux de bord refusaient de
s'afficher.

```
Refused to apply style from '.../dhis-web-data-visualizer/assets/index-Dmx4sX17.css'
because its MIME type ('text/html') is not a supported stylesheet MIME type
```

**Le serveur n'y etait pour rien** : le fichier existe bien dans l'image, et `index.html`
comme `plugin.html` le referencent correctement. L'onglet reseau a designe la vraie cause
— les requetes en 404 etaient emises par `service-worker.js`, et les scripts servis
venaient de son cache, non du serveur.

Les applications DHIS2 enregistrent un **service worker** qui met en cache leurs assets. Un
service worker survit au changement de version : il continue de servir l'application
precedente et de reclamer des fichiers qui n'existent plus.

### Remede

**L'application `dhis-web-cache-cleaner` embarquee par DHIS2 ne suffit pas** — essaye le
20 aout 2026, sans effet. Elle vide le cache applicatif de DHIS2, pas le service worker
enregistre par le navigateur, qui est precisement ce qui pose probleme.

Le nettoyage se fait **par le navigateur** : supprimer les donnees du site, puis fermer tous
les onglets DHIS2 avant de rouvrir — un service worker reste actif tant qu'un onglet
subsiste.

Instructions detaillees, redigees pour des utilisateurs non techniques et destinees a etre
transmises telles quelles : [`vider-le-cache.md`](vider-le-cache.md).

**Un rechargement force ne suffit pas**, meme avec `Ctrl`+`Maj`+`R`.

### Consequence pour le Go-Live

Le jour ou `endom.alima.ngo` passera de la 2.35 a la 2.41, **chaque navigateur ayant utilise
l'ancienne instance portera un service worker enregistre par la 2.35**. Les utilisateurs
verront des tableaux de bord vides ou des erreurs de chargement, sur un serveur pourtant
sain — et signaleront un incident de migration qui n'en est pas un.

A prevoir dans le plan de bascule :

1. **Prevenir avant** — un message aux utilisateurs, avec le lien du vide-cache et la
   marche a suivre — [`vider-le-cache.md`](vider-le-cache.md) est ecrit pour cela. Le faire
   avant la bascule, pas apres les premiers appels.
2. **Armer le support** — que la premiere reponse a « ca ne marche pas » soit l'envoi de
   [`vider-le-cache.md`](vider-le-cache.md), avant tout diagnostic serveur.
3. **Le verifier soi-meme** — tester la bascule dans un navigateur ayant reellement utilise
   la 2.35, pas seulement en navigation privee, qui masque precisement ce probleme.

> C'est le genre d'incident qui se paie cher le jour J : il touche tous les utilisateurs a
> la fois, ressemble a une panne serveur, et se corrige en dix secondes une fois la cause
> connue.

---

## Points de vigilance

Ce que la repetition du 20 aout 2026 a reellement appris.

**Les images officielles ne sont pas homogenes.** Chaque version peut differer sur la forme
livree et l'outillage present — releve :

| | 2.35.14 | 2.37.10.0 |
|---|---|---|
| Application | `ROOT.war` + un repertoire `ROOT` **vide** | `ROOT` deja depliee |
| `unpackWARs` | `"false"` | `"false"` |
| `unzip` | present | **absent** |
| `curl` | **absent** | present |

D'ou des tests plutot que des hypotheses dans le `Dockerfile` des paliers. Une image livree
sous une troisieme forme fera echouer la construction — c'est voulu — plutot que de
produire une image qui demarre sur du vide.

**La transition c3p0 vers Hikari est mal finie entre 2.36 et 2.39.** En 2.37, activer la
metrique `monitoring.dbpool` tue l'initialisation Spring
(`HikariDataSource cannot be cast to ComboPooledDataSource`). La surcharge de palier la
coupe. **La cible 2.41 n'est pas concernee** — ne pas propager ce reglage a `main`.

**Une sonde de disponibilite ne se devine pas.** `dhis-web-login` n'existe pas dans les
versions anciennes ; `/api/system/ping` y repond 302, ce que `curl -f` accepte. Le 302 est
ici un bon signal : une application vide renverrait 404. En production, seul
`/dhis-web-login/` repond 200 sans session.

**Le planificateur reprend les taches en retard.** `ANALYTICS_TABLE` est planifiee du lundi
au vendredi a midi UTC : un palier laisse en fonctionnement a cette heure declencherait une
generation complete, longue et inutile. Passer au palier suivant des
`All startup routines done`.

**PostgreSQL 16.** Le Flyway embarque signale n'avoir pas ete teste au-dela de PostgreSQL 15.
Les migrations sont passees sur les sept versions. Si un palier echouait de facon
inexpliquee lors du rejeu, cette piste resterait a examiner.

**Extensions PostgreSQL.** `postgis`, `btree_gin` et `pg_trgm` sont creees automatiquement a
chaque deploiement par l'etape `init-db`. Sur une base de travail creee a la main, les creer
avant le premier palier.

**Les parametres chiffres ne survivent pas au changement de cle.** `keyEmailPassword` est
illisible : la configuration SMTP sera a ressaisir apres la bascule. Ne **jamais** tenter
d'aligner `dhis2-encryption-password` sur l'ancienne instance — tout ce que la nouvelle aura
chiffre depuis deviendrait illisible a son tour.

**Des tables ont fusionne en chemin.** `usercredentials` dans `userinfo` (2.38), graphiques
et tableaux dans `visualization` (2.35), le partage en `jsonb` (2.36). Toute requete SQL
directe sur ces objets est a reprendre — a verifier cote Power BI selon qu'il attaque la
base ou l'API.

**Une table de tags recopiee se perime.** Utiliser `./scripts/list-palier-images.sh`, qui
interroge le registre, et le lancer **avant** d'ouvrir la fenetre : la politique de nettoyage
purge au-dela de 30 jours.
