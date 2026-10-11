# Historique des versions

Format : [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/) · numérotation [SemVer](https://semver.org/lang/fr/)
(MAJEUR.MINEUR.CORRECTIF : correctif = bug corrigé, mineur = nouvelle fonction, majeur = changement incompatible).

## [1.0.1] - 2026-10-11

### Corrigé
- Le code de sortie vaut désormais `1` dès qu'une étape échoue (il valait `0`), pour que les outils RMM signalent l'échec.
  Une erreur prime sur `3010` (redémarrage requis).
- La réactivation d'une application ne compte plus comme une erreur quand le ré-enregistrement local échoue
  mais que l'installation depuis le Store / winget prend le relais.
- Interface : l'import d'un profil ne contenant que `"disable"` ou que `"enable"` n'est plus refusé comme « illisible ».

### Ajouté
- Numéro de version (`$ScriptVersion`) affiché dans le titre de la fenêtre et écrit dans le journal.
- Fin d'exécution : nombre d'erreurs dans le journal, et avertissement dans l'interface si des étapes ont échoué.

## [1.0.0] - 2026-10-11

- Version initiale : interface graphique et ligne de commande, catalogue `addons.json` (liste tiny11 + extras),
  mode simulation, profils JSON, mode hors ligne sur image montée.
