# Vider le cache du navigateur — DHIS2

À transmettre aux utilisateurs après un changement de version de DHIS2.

---

## Pourquoi

DHIS2 installe dans votre navigateur un petit programme qui garde les pages en mémoire pour
accélérer l'affichage. Après une mise à jour, ce programme continue de servir **l'ancienne
version**, qui ne correspond plus au serveur.

Ce qu'on observe alors :

- les tableaux de bord restent vides ou tournent sans fin ;
- des visualisations affichent une erreur de chargement ;
- l'application semble figée sur un écran d'accueil.

**Le serveur fonctionne normalement.** Seul votre navigateur est en retard.

> **Recharger la page ne suffit pas**, même avec `Ctrl`+`Maj`+`R`. Il faut supprimer les
> données du site.

---

## Chrome et Edge

Les deux navigateurs partagent la même mécanique ; les libellés peuvent différer d'un mot.

### Méthode 1 — par la barre d'adresse

1. Ouvrir DHIS2.
2. Cliquer sur l'**icône à gauche de l'adresse** du site (cadenas, curseurs ou globe selon
   la version).
3. Choisir **Cookies et données de site**, puis **Gérer les données sur l'appareil**.
4. Cliquer sur l'icône de **corbeille** en face du site, puis confirmer par **Supprimer**.
5. **Fermer tous les onglets** ouverts sur DHIS2 — l'ancien programme reste actif tant qu'un
   onglet subsiste.
6. Rouvrir DHIS2 et se reconnecter.

### Méthode 2 — par les paramètres

Si l'icône de la barre d'adresse ne propose pas ces options :

1. Saisir cette adresse dans un nouvel onglet :

   ```
   chrome://settings/content/all
   ```

   Sur Edge : `edge://settings/content/all`

2. Rechercher `dhis2` dans le champ de recherche de la page.
3. Supprimer l'entrée correspondant à votre instance DHIS2.
4. Fermer tous les onglets DHIS2, puis rouvrir.

### Méthode 3 — pour les profils techniques

1. `F12` pour ouvrir les outils de développement.
2. Onglet **Application**.
3. **Service Workers** dans le menu de gauche → **Unregister**.
4. **Storage** → **Clear site data**.
5. Recharger.

Cette méthode est la plus sûre : elle montre ce qui est supprimé.

---

## Firefox

1. Cliquer sur le **cadenas** à gauche de l'adresse → **Effacer les cookies et les données
   de site**.
2. Confirmer.
3. Fermer tous les onglets DHIS2, puis rouvrir.

Pour les profils techniques : `about:debugging#/runtime/this-firefox`, section **Service
Workers**, bouton **Unregister**.

---

## Vérifier que c'est réglé

Rouvrir un tableau de bord. S'il s'affiche, c'est terminé.

Sinon, la navigation privée permet de trancher : elle n'utilise ni cache ni programme
enregistré.

- **Ça fonctionne en navigation privée** → le nettoyage n'a pas abouti, recommencer en
  fermant bien **tous** les onglets DHIS2 avant de rouvrir.
- **Ça ne fonctionne pas non plus** → le problème n'est pas le cache. Signaler au support en
  précisant ce qui s'affiche.

---

## Ce que ce nettoyage ne supprime pas

- **Aucune donnée DHIS2.** Rien de ce qui est saisi n'est stocké dans le navigateur ; tout
  vit sur le serveur.
- Vos identifiants restent valides — vous devrez simplement vous reconnecter.
- Les autres sites ne sont pas touchés : la suppression ne vise que DHIS2.
