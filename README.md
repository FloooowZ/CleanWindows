# All-In-One Clean Windows (Gaming)

Script PowerShell qui optimise Windows 11 pour le gaming : suppression du bloatware, services et démarrage minimaux,
thème noir, réseau, son, Defender, NVIDIA, OBS (profil Twitch 1080p60), nettoyage final, etc.

## Installation / lancement (PowerShell)

Ouvre **PowerShell** (pas CMD) et colle :

```powershell
$u = "https://raw.githubusercontent.com/FloooowZ/CleanWindows/main/AllInOne-CleanWindows-Standalone.ps1"
$f = "$env:TEMP\AllInOne-CleanWindows-Standalone.ps1"
irm $u -OutFile $f
powershell -NoProfile -ExecutionPolicy Bypass -File $f
```

Le script se relance tout seul en administrateur (accepte la demande UAC).

Version courte (une seule ligne) :

```powershell
irm "https://raw.githubusercontent.com/FloooowZ/CleanWindows/main/AllInOne-CleanWindows-Standalone.ps1" -OutFile "$env:TEMP\a.ps1"; powershell -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\a.ps1"
```

Remplace `<USER>` par ton nom d'utilisateur GitHub et `<REPO>` par le nom du dépôt.

> `irm ... | iex` n'est **pas** pris en charge : le script a besoin d'être un fichier pour se relancer en administrateur.

## Lancement depuis l'invite de commande (CMD)

Colle cette ligne dans CMD :

```bat
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm 'https://raw.githubusercontent.com/FloooowZ/CleanWindows/main/AllInOne-CleanWindows-Standalone.ps1' -OutFile $env:TEMP\a.ps1; & $env:TEMP\a.ps1"
```

Ou double-clique sur `Lancer-Depuis-GitHub.bat` : il télécharge toujours la dernière version du script depuis GitHub.

## Options de lancement

```powershell
# Liste les tâches (numéro + nom) sans rien exécuter
powershell -NoProfile -ExecutionPolicy Bypass -File $f -List

# Ne lance que certaines tâches (mots contenus dans le nom, séparés par des virgules)
powershell -NoProfile -ExecutionPolicy Bypass -File $f -Only "Services,Startup,Network"

# Lance tout sauf certaines tâches
powershell -NoProfile -ExecutionPolicy Bypass -File $f -Skip "Plex,Component Store"
```

## NVIDIA

Si une carte NVIDIA est détectée, le script :

1. installe **NVCleanstall** (TechPowerUp), pour un usage manuel : il n'a pas de mode automatique ;
2. télécharge le **dernier pilote Game Ready** depuis NVIDIA ;
3. l'installe en version **allégée** (pilote d'affichage + audio HDMI/DP + PhysX, sans GeForce Experience, NVIDIA App ni télémétrie), comme le fait NVCleanstall ;
4. installe le **Panneau de configuration NVIDIA** (Microsoft Store).

Aucune question n'est posée. Les tâches NVIDIA sont ignorées s'il n'y a pas de carte NVIDIA.
Une tâche distincte met l'écran en 2560x1440 à la fréquence maximale jusqu'à 180 Hz (sans effet si l'écran n'a pas ce mode ; `-Skip "Display Mode"` pour l'ignorer).

## Rapports générés

| Fichier | Contenu |
|---|---|
| `Bureau\CLEANWINDOWS-RESUME.TXT` | Tâches, durées, vérification de l'état final, mesures avant → maintenant, avertissements/erreurs |
| `Bureau\CLEANWINDOWS-APRES-REBOOT.TXT` | Comparaison avant → après redémarrage (créée automatiquement ~2 min 30 après la prochaine ouverture de session) |
| `Documents\CLEANWINDOWSLOG.TXT` | Journal complet |
| `Documents\CleanWindows-Baseline.json` | Mesure initiale (conservée aux relances) |
| `Documents\CleanWindows-RestoreServices.ps1` | Restauration des services désactivés |
| `Documents\CleanWindows-RemovedGhostDevices.csv` | Périphériques fantômes supprimés |

Sur un **ordinateur portable**, le script laisse les réglages batterie, l'hibernation et l'économie d'énergie des périphériques inchangés.

## Après le passage

- Résumé (tâches, durées, vérification de l'état final, avertissements) : `Bureau\CLEANWINDOWS-RESUME.TXT`
- Journal complet : `Documents\CLEANWINDOWSLOG.TXT`
- Script de restauration des services : `Documents\CleanWindows-RestoreServices.ps1`
- Redémarre le PC à la fin.

## Réglages en haut du script

| Variable | Rôle |
|---|---|
| `$TaskTimeoutSeconds` | Délai maximum par tâche (300 s) |
| `$CleanUserDownloads` | Vide aussi le dossier Téléchargements à la fin |
| `$RunComponentCleanup` | Nettoyage DISM du magasin de composants (long) |
