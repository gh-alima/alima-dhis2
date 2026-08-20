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

| Branche | Version | Java |
|---|---|---|
| `migration/2.35.14` | 2.35.14 | 11 |
| `migration/2.36.13.2` | 2.36.13.2 | 11 |
| `migration/2.37.10.0` | 2.37.10.0 | 11 |
| `migration/2.38.7.0` | 2.38.7.0 | 11 |
| `migration/2.39.10.1` | 2.39.10.1 | 11 / 17 |
| `migration/2.40.12.0` | 2.40.12.0 | 17 |
| **`main`** | **2.41.9.1** | **17** — cible, `server.xml` actif |

> `2.35.0`, la version en production chez ALIMA, **n'a pas d'image officielle** : la ligne
> 2.35 ne publie qu'à partir de `2.35.9`. Le premier palier démarre donc sur `2.35.14`, ce
> qui applique au passage les correctifs de la ligne. Ces correctifs ne modifient pas le
> schéma : l'image s'applique directement sur une base 2.35.0.

Ajouter un palier si besoin :

```bash
./scripts/create-migration-branch.sh 2.36.13.2
```

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

### 2. Restaurer sur une base de travail

Travailler sur une base **distincte** de celle de l'instance en service, pour pouvoir
recommencer un palier sans tout reprendre :

```bash
gcloud sql databases create dhis2-migration --instance=pg16-dhis2-prod
```

### 3. Construire les images des paliers

```bash
git checkout migration/2.35.14
gcloud builds submit --config=cloudbuild.yaml \
  --substitutions=_VCS_REF=$(git rev-parse --short HEAD) \
  --project=alima-dhis2-prod
```

Le tag produit porte la version du palier : `2.35.14.<date>.<n°>.<commit>`.

> Le déclencheur automatique ne réagit qu'aux poussées sur `main` : les branches de palier
> se construisent à la demande, ce qui évite de saturer le registre.

---

## Exécuter un palier

Pour chaque version, dans l'ordre :

**1. Sauvegarder l'état d'entrée** — c'est le point de reprise si le palier échoue.

```bash
gcloud sql export sql pg16-dhis2-prod \
  gs://alima-dhis2-prod-dhis2-backups/migration/avant-<version>.sql \
  --database=dhis2-migration
```

**2. Démarrer le palier** sur la base de travail, en pointant `DHIS2_DATABASE_NAME` vers
`dhis2-migration`. Seul le service `dhis2` est nécessaire — ni Nginx ni certificat.

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
