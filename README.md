# WinAddonToggle

Active ou désactive **à la carte** les composants « add-on » de Windows 10 / 11, dans l'esprit de [tiny11builder](https://github.com/ntdevlabs/tiny11builder) mais :

- **réversible** : chaque composant retiré peut être réactivé (ré-enregistrement local, Microsoft Store ou winget) ;
- **sélectif** : interface à cases à cocher, ou ligne de commande / profil JSON pour le déploiement (RMM, Intune, GPO de démarrage…) ;
- **en ligne ou hors ligne** : sur le poste en cours, ou sur une image WIM montée (désactivation seulement, comme tiny11builder).

## Fichiers

| Fichier | Rôle |
|---|---|
| `WinAddonToggle.ps1` | Le script (GUI WinForms + CLI). Windows PowerShell 5.1, droits admin. |
| `addons.json` | Catalogue des composants. Ajoutez-y vos propres entrées. |
| `CHANGELOG.md` | Historique des versions. |

## Utilisation

```powershell
# Interface graphique (relance automatiquement en admin)
.\WinAddonToggle.ps1

# État de chaque composant
.\WinAddonToggle.ps1 -List

# Simulation puis désactivation
.\WinAddonToggle.ps1 -Disable Clipchamp,News,Weather,Solitaire -DryRun
.\WinAddonToggle.ps1 -Disable Clipchamp,News,Weather,Solitaire

# Programmes lancés au démarrage (système + chaque utilisateur)
.\WinAddonToggle.ps1 -ListStartup

# Toute la liste de base, en gardant les paquets provisionnés
.\WinAddonToggle.ps1 -Disable base -KeepProvisioned

# Réactiver
.\WinAddonToggle.ps1 -Enable Weather,ToDo

# Appliquer un profil exporté depuis la GUI (état souhaité)
.\WinAddonToggle.ps1 -ConfigFile .\profil-client.json

# Image Windows montée (Mount-WindowsImage / DISM)
.\WinAddonToggle.ps1 -ImagePath D:\mount -Disable base
```

Mots-clés acceptés par `-Disable` / `-Enable` : `base` (liste tiny11), `extra` (Copilot, Outlook new, Teams, WMP hérité), `all`.

Code de sortie : `0` OK, `1` au moins une étape a échoué (prioritaire), `3010` redémarrage requis. Journal dans `%ProgramData%\WinAddonToggle\logs` (la version du script y est indiquée).

Historique des versions : voir [CHANGELOG.md](CHANGELOG.md).

### Profil JSON

```json
{ "disable": ["Clipchamp", "News", "Xbox"], "enable": ["ToDo", "OneDrive"] }
```

## Comment chaque type est traité

| Type | Désactiver | Réactiver |
|---|---|---|
| Appx (la plupart) | `Remove-AppxPackage -AllUsers` + `Remove-AppxProvisionedPackage` (sauf `-KeepProvisioned`) | Ré-enregistrement du manifeste s'il reste sur disque, sinon `winget --source msstore` |
| Capacité (IE, Math, Quick Assist Win10, WMP) | `Remove-WindowsCapability` | `Add-WindowsCapability` (Windows Update / source FoD requis) |
| Fonctionnalité optionnelle (IE) | `Disable-WindowsOptionalFeature` | `Enable-WindowsOptionalFeature` |
| Edge | `setup.exe --uninstall --system-level --force-uninstall` + blocage EdgeUpdate | `winget install Microsoft.Edge` |
| OneDrive | Désinstalleur (utilisateur + machine), stratégie `DisableFileSyncNGSC`, retrait du profil par défaut | Suppression de la stratégie + `winget install Microsoft.OneDrive` |

## Onglet « Programmes au démarrage »

Équivalent plus complet de l'onglet Démarrage du Gestionnaire des tâches, avec la **portée** de chaque entrée :
**Système** (tous les utilisateurs) ou **Utilisateur : nom**. Un filtre permet d'afficher une portée précise.

| Source | Portée | Activer / désactiver |
|---|---|---|
| Registre `Run` (64 et 32 bits) | Système (HKLM) ou utilisateur (HKCU) | Clé `StartupApproved` (comme le Gestionnaire des tâches) |
| Dossier Démarrage | Commun (ProgramData) ou du profil | Clé `StartupApproved\StartupFolder` |
| Applications du Store (Spotify, WhatsApp, Teams…) | Utilisateur | Valeur `State` de la tâche de démarrage du paquet |
| Tâches planifiées (ouverture de session / démarrage du PC) | Système ou utilisateur selon le déclencheur | `Enable-` / `Disable-ScheduledTask` |
| Stratégie `Policies\Explorer\Run` | Système ou utilisateur | Lecture seule (à modifier dans la GPO) |

- **Rien n'est supprimé** : une entrée désactivée se réactive d'un clic, ici ou dans le Gestionnaire des tâches.
- **Tous les profils** du poste sont listés, y compris ceux dont la session n'est pas ouverte (leur ruche `NTUSER.DAT` est montée le temps de la lecture ou de la modification). Pour ces profils, les applications du Store ne sont pas listées.
- Colonne **En cours** : le programme tourne actuellement. **⚠** : survolez le nom (ex. fichier introuvable = entrée orpheline d'un logiciel désinstallé).
- Les tâches planifiées Microsoft sont masquées par défaut (case à cocher pour les inclure).
- Effet à la prochaine ouverture de session.

## Limites à connaître

- **Edge** : Microsoft n'autorise la désinstallation que dans l'EEE (la Belgique en fait partie). WebView2 et EdgeUpdate sont volontairement conservés. Une mise à jour de Windows peut le réinstaller.
- **OneDrive** est installé par utilisateur : seul l'utilisateur qui lance le script est désinstallé ; les autres profils sont neutralisés par la stratégie.
- **Réinstallation Store** : winget installe pour l'utilisateur courant. En contexte SYSTEM (RMM), la source msstore ne fonctionne généralement pas — prévoir l'activation en contexte utilisateur.
- **Applications retirées par Microsoft** (Courrier et Calendrier, Cartes, Contacts) : désactivables, mais non réinstallables.
- **Mises à jour de fonctionnalités** de Windows : elles peuvent re-provisionner certaines applis. Relancer le profil après une mise à jour majeure (tâche planifiée).
- Les identifiants Microsoft Store du catalogue sont à vérifier avant un déploiement à grande échelle (`winget show --id <ID> --source msstore`).

## Ajouter un composant

```json
{
  "id": "MonApp", "name": "Nom affiché", "category": "Catégorie", "set": "extra",
  "appx": [ { "name": "Editeur.NomDuPaquet", "storeId": "9XXXXXXXXXXX" } ],
  "capabilities": [ "Nom.Capacite*" ],
  "features": [ "Nom-Fonctionnalite" ],
  "warning": "Affiché avant la désactivation",
  "notes": "Affiché dans la colonne Détail"
}
```

Le nom d'un paquet s'obtient avec `Get-AppxPackage -AllUsers | Select Name` et celui d'une capacité avec `Get-WindowsCapability -Online | Select Name, State`.
