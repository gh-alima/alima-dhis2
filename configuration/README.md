# Métadonnées DHIS2 ALIMA

Ce répertoire est copié dans l'image à la construction, vers
`/opt/dhis2/configuration_dhis2`.

Il accueille les fichiers de métadonnées JSON à charger dans l'instance :
groupes d'utilisateurs, éléments de données, programmes, jeux d'organisation.

## Convention de nommage

Les fichiers sont préfixés par un numéro d'ordre et suffixés par la stratégie
d'import, car l'ordre et le mode de fusion sont significatifs :

```
1_metadata_usergroups_merge.json      importé en premier, stratégie MERGE
2_metadata_base_replace.json          importé ensuite, stratégie REPLACE
```

## Règle de confidentialité

**Métadonnées uniquement.** Aucune donnée agrégée, aucun événement, aucune
donnée nominative ne doit être placé ici : ces fichiers sont versionnés dans
Git et intégrés à l'image (données de santé ALIMA, CGA art. 13).

En cas de doute sur le contenu d'un export, ne pas le committer.
