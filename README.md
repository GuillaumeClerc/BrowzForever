# Browz Forever

Addon de la guilde **Browz Forever** (WoW Forever, Horde).

## Installer l'addon

1. Télécharge le dépôt : bouton vert **Code → Download ZIP**.
2. Copie le dossier `addon/BrowzForever` dans `World of Warcraft\_forever_\Interface\AddOns\`.
3. Installe aussi **LibProfessionDB** (CurseForge, addon « ProfessionDB » de Pimptasty) : c'est la base de recettes
   de l'onglet Craft. Sans elle, tout le reste marche, seul l'onglet Craft reste vide.
4. Relance le jeu, puis tape `/browz` (ou clique sur la pièce d'or près de la minimap, ou sur la macro « Browz BDG »).

L'addon ne fait rien en dehors de la guilde Browz Forever.
Pour le donner à un nouveau membre : onglet **Liaison → Lien de l'addon** (ou `/browz lien`), puis Ctrl+C.

### Ce que fait l'addon

- **Banque** : vue de la banque de guilde comme dans le jeu (onglets) ou en liste, consultable partout.
- **Liaison** : tes métiers, tes personnages, ton pseudo Discord (Browzer te demandera de confirmer en message privé).
- **Talents** et **équipement** : visibles sur le Discord de la guilde (`/browz inspect`).
- **Demandes** : demande des objets de la banque avec une explication ; les officiers acceptent, l'addon retire les objets et prépare le courrier.
- **Banque (coffre)** : bouton **Ranger** à côté de la recherche du coffre (types d'onglet, fusion des piles, tri par familles).
- **Craft** : qui sait fabriquer quoi dans la guilde (composants déjà en banque), et les **commandes de craft** (aussi sur Discord : `/browz commande`).

## Pour tous ceux qui veulent aider : le pont

Un addon WoW ne peut pas accéder à internet. Un « pont » (le PC d'un membre qui fait tourner le client) fait le lien
avec Discord : sans pont connecté, le Discord ne se met plus à jour (en jeu, l'addon continue de marcher entre
membres connectés). **Plus il y a de ponts, mieux ça vit** : n'importe quel membre peut en être un, officier ou pas.

1. Sur le Discord de la guilde, tape `/browz cle` : Browzer te donne ta **clé personnelle** (garde-la pour toi).
2. Télécharge **BrowzClient.exe** et **Installer.bat** (page *Releases* du dépôt), mets-les dans le même dossier et
   lance **Installer.bat** : le client s'installe et se lancera tout seul à chaque démarrage du PC, sans fenêtre.
3. Au premier lancement, une petite fenêtre demande l'adresse du bot (demande-la à Bellock) et ta clé.
4. En jeu : `/browz pont on` (une seule fois).

Les officiers voient les clés et leur dernière utilisation (`/browz cles`) et peuvent en retirer une (`/browz revoquer`).

Le client **se met à jour tout seul** (il vérifie les *Releases* du dépôt au démarrage puis toutes les 6 h).
Pour le redémarrer (et vérifier tout de suite s'il y a une mise à jour), relance simplement `BrowzClient.exe`.
`Desinstaller.bat` l'arrête et le retire du démarrage ; `Voir le journal.bat` ouvre son journal.
Windows peut afficher un avertissement (« Windows a protégé votre ordinateur ») : c'est normal pour un petit
programme non signé, clique sur *Informations complémentaires → Exécuter quand même*.

> Ne publie jamais ton `config.json` (déjà exclu par `.gitignore`).

## Licence

© 2026 Guillaume Clerc (Bellock). Tous droits réservés : usage personnel autorisé, redistribution et réutilisation du code interdites sans accord. Détails dans [LICENSE](LICENSE).
