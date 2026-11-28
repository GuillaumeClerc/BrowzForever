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
- **Demandes** : demande des objets de la banque avec une explication ; les officiers acceptent, l'addon retire les objets et prépare le courrier.
- **Craft** : à venir.

## Pour les officiers : le pont

Un addon WoW ne peut pas accéder à internet. Un « pont » (PC d'un officier) fait le lien avec Discord.
Les membres n'en ont pas besoin.

1. Télécharge **BrowzClient.exe** et **Installer.bat** (Bellock te les envoie, ou page *Releases* du dépôt).
2. Mets-les dans le même dossier et lance **Installer.bat** : le client s'installe et se lancera tout seul à chaque
   démarrage du PC, sans fenêtre.
3. Au premier lancement, une petite fenêtre demande l'adresse du bot et la clé (Bellock te les envoie en privé).
4. En jeu : `/browz pont on` (une seule fois).

Le client **se met à jour tout seul** (il vérifie les *Releases* du dépôt au démarrage puis toutes les 6 h).
Pour le redémarrer (et vérifier tout de suite s'il y a une mise à jour), relance simplement `BrowzClient.exe`.
`Desinstaller.bat` l'arrête et le retire du démarrage ; `Voir le journal.bat` ouvre son journal.
Windows peut afficher un avertissement (« Windows a protégé votre ordinateur ») : c'est normal pour un petit
programme non signé, clique sur *Informations complémentaires → Exécuter quand même*.

> Ne publie jamais ton `config.json` (déjà exclu par `.gitignore`).

## Licence

© 2026 Guillaume Clerc (Bellock). Tous droits réservés : usage personnel autorisé, redistribution et réutilisation du code interdites sans accord. Détails dans [LICENSE](LICENSE).
