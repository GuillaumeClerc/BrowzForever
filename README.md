# Browz Forever

Addon de la guilde **Browz Forever** (WoW Forever, Horde).

## Installer l'addon

1. Télécharge le dépôt : bouton vert **Code → Download ZIP**.
2. Copie le dossier `addon/BrowzForever` dans `World of Warcraft\_forever_\Interface\AddOns\`.
3. Relance le jeu, puis tape `/browz` (ou clique sur la pièce d'or près de la minimap).

L'addon ne fait rien en dehors de la guilde Browz Forever.
Pour le donner à un nouveau membre : onglet **Liaison → Lien de l'addon** (ou `/browz lien`), puis Ctrl+C.

### Ce que fait l'addon

- **Banque** : vue de la banque de guilde comme dans le jeu (onglets) ou en liste, consultable partout.
- **Liaison** : tes métiers, tes personnages, ton pseudo Discord (Browzer te demandera de confirmer en message privé).
- **Talents** et **équipement** : visibles sur le Discord de la guilde (`/browz inspect`).
- **Demandes** et **Craft** : à venir.

## Pour les officiers : le pont

Un addon WoW ne peut pas accéder à internet. Un « pont » (PC d'un officier) fait le lien avec Discord.
Les membres n'en ont pas besoin.

1. Installe Python 3 (python.org, coche « Add to PATH »).
2. Copie le dossier `client`, renomme `config.exemple.json` en `config.json` et remplis-le
   avec l'adresse et la clé que Bellock t'envoie en privé.
3. En jeu : `/browz pont on`, puis lance `Lancer.bat`.

> Ne publie jamais ton `config.json` (déjà exclu par `.gitignore`).
