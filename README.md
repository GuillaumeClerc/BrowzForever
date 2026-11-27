# Browz Forever

Outils de la guilde **Browz Forever** (WoW Forever, Horde) : un addon en jeu, un bot Discord et un petit client qui fait le lien.

## Pour les membres : installer l'addon

1. Télécharge le dépôt : bouton vert **Code → Download ZIP**.
2. Copie le dossier `addon/BrowzForever` dans `World of Warcraft\_forever_\Interface\AddOns\`.
3. Relance le jeu, puis tape `/browz` (ou clique sur la pièce d'or près de la minimap).

L'addon ne fait rien en dehors de la guilde Browz Forever.

### Ce que fait l'addon

- **Banque** : vue de la banque de guilde comme dans le jeu (onglets) ou en liste, consultable partout.
- **Liaison** : tes métiers, tes personnages, ton pseudo Discord (Browzer te demandera de confirmer en message privé).
- **Demandes** et **Craft** : à venir.

## Pour les officiers : le pont

Un addon WoW ne peut pas accéder à internet. Un « pont » (PC d'un officier) fait le lien avec Discord :

1. Installe Python 3 (python.org, coche « Add to PATH »).
2. Copie le dossier `client`, renomme `config.exemple.json` en `config.json` et remplis-le (adresse du bot et clé : demande-les à Bellock).
3. En jeu : `/browz pont on`, puis lance `Lancer.bat`.

## Le bot Discord (Browzer)

Dossier `bot` : `config_bot.exemple.json` → `config_bot.json` (jeton du bot, clé de guilde). Commandes : `/browz bdg`, `or`, `objet`, `journal`, `inspect`, `metier`.

> Ne publie jamais `config_bot.json`, `config.json` ni `donnees.json` : ils contiennent le jeton du bot, la clé de guilde et les données de la guilde (déjà exclus par `.gitignore`).
